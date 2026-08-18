#include "api/array_view.h"
#include "api/crypto/frame_crypto_transformer.h"

#include "api/crypto/default_encryption_manager.h"
#include "api/crypto/frame_crypto_trailer.h"
#include "api/crypto/frame_encryption_manager.h"
#include "api/make_ref_counted.h"
#include "api/test/mock_transformable_audio_frame.h"
#include "api/test/mock_transformable_video_frame.h"
#include "api/video/video_codec_type.h"
#include "api/video/video_frame_metadata.h"

#include <array>
#include <memory>
#include <string>
#include <string_view>
#include <vector>

#include "rtc_base/event.h"
#include "rtc_base/logging.h"
#include "rtc_base/synchronization/mutex.h"
#include "rtc_base/thread.h"
#include "test/gmock.h"
#include "test/gtest.h"

using ::testing::NiceMock;
using ::testing::Return;

namespace webrtc {

TEST(FrameCryptor, KeyProvider) {
  auto key_options = KeyProviderOptions();
  RTC_LOG(LS_INFO) << "DataPacketCrypt shared_key default: "
                   << key_options.shared_key;
  EXPECT_EQ(key_options.shared_key, false);
  EXPECT_EQ(key_options.key_ring_size, static_cast<int>(DEFAULT_KEYRING_SIZE));

  key_options.ratchet_salt =
      std::vector<uint8_t>({0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07});

  EXPECT_EQ(key_options.ratchet_salt.size(), 8u);

  auto key_provider =
      webrtc::make_ref_counted<DefaultKeyProviderImpl>(key_options);
  EXPECT_NE(key_provider, nullptr);

  std::string participant_id = "participant_1";
  key_provider->SetKey(participant_id, 0,
                       std::vector<uint8_t>{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
                                            11, 12, 13, 14, 15});
  auto key_handler = key_provider->GetKey(participant_id);
  EXPECT_NE(key_handler, nullptr);

  auto keyset = key_handler->GetKeySet(0);
  EXPECT_NE(keyset, nullptr);

  EXPECT_EQ(keyset->material,
            std::vector<uint8_t>(
                {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15}));
  EXPECT_EQ(keyset->encryption_key.size(), 16u);

  EXPECT_EQ(keyset->encryption_key,
            std::vector<uint8_t>({166, 88, 205, 82, 239, 186, 202, 223, 236,
                                  223, 224, 160, 220, 87, 78, 195}));

  key_handler->RatchetKey(0);
  auto new_keyset = key_handler->GetKeySet(0);
  EXPECT_NE(new_keyset, nullptr);
  EXPECT_NE(new_keyset->material, keyset->material);
  EXPECT_NE(new_keyset->encryption_key, keyset->encryption_key);
}

TEST(DataPacketCryptor, BasicTest) {
  auto key_options = KeyProviderOptions();
  key_options.ratchet_salt =
      std::vector<uint8_t>({0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07});
  auto key_provider =
      webrtc::make_ref_counted<DefaultKeyProviderImpl>(key_options);
  EXPECT_NE(key_provider, nullptr);

  std::string participant_id = "participant_1";
  key_provider->SetKey(participant_id, 0,
                       std::vector<uint8_t>{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
                                            11, 12, 13, 14, 15});
  auto data_packet_cryptor = webrtc::make_ref_counted<DataPacketCryptor>(
      FrameCryptorTransformer::Algorithm::kAesGcm, key_provider);
  EXPECT_NE(data_packet_cryptor, nullptr);
  RTC_LOG(LS_INFO) << "DataPacketCrypt test";

  auto encrypted_data = data_packet_cryptor->Encrypt(
      participant_id, 0,
      std::vector<uint8_t>(
          {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15}));
  EXPECT_TRUE(encrypted_data.ok());
  EXPECT_EQ(encrypted_data.value()->data.size(), 16 + 16u);  // data + tag
  EXPECT_NE(encrypted_data.value()->data,
            std::vector<uint8_t>(
                {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15}));
  RTC_LOG(LS_INFO) << "DataPacketCrypt encrypted_data size: "
                   << encrypted_data.value()->data.size();
  RTC_LOG(LS_INFO) << "DataPacketCrypt encrypted_data iv size: "
                   << encrypted_data.value()->iv.size();
  RTC_LOG(LS_INFO) << "DataPacketCrypt encrypted_data key_index: "
                   << static_cast<int>(encrypted_data.value()->key_index);
  EXPECT_EQ(encrypted_data.value()->key_index, 0);

  EXPECT_EQ(encrypted_data.value()->iv.size(), 12u);

  auto decrypted_data =
      data_packet_cryptor->Decrypt(participant_id, encrypted_data.value());

  EXPECT_TRUE(decrypted_data.ok());

  EXPECT_EQ(decrypted_data.value(),
            std::vector<uint8_t>(
                {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15}));

  auto key_handler = key_provider->GetKey(participant_id);
  EXPECT_NE(key_handler, nullptr);

  key_handler->RatchetKey(0);
  // decrypt with ratcheted key should fail
  auto decrypted_data2 =
      data_packet_cryptor->Decrypt(participant_id, encrypted_data.value());
  EXPECT_FALSE(decrypted_data2.ok());

  // set back to previous key
  key_provider->SetKey(participant_id, 0,
                       std::vector<uint8_t>{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
                                            11, 12, 13, 14, 15});
  auto decrypted_data3 =
      data_packet_cryptor->Decrypt(participant_id, encrypted_data.value());
  EXPECT_TRUE(decrypted_data3.ok());
  EXPECT_EQ(decrypted_data3.value(),
            std::vector<uint8_t>(
                {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15}));
}

TEST(DataPacketCryptor, DifferentKeyProvider) {
  auto key_options = KeyProviderOptions();
  RTC_LOG(LS_INFO) << "DataPacketCrypt shared_key default: "
                   << key_options.shared_key;
  EXPECT_EQ(key_options.shared_key, false);
  EXPECT_EQ(key_options.key_ring_size, static_cast<int>(DEFAULT_KEYRING_SIZE));
  // support ratcheting
  key_options.ratchet_window_size = 4;
  key_options.ratchet_salt =
      std::vector<uint8_t>({0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07});

  EXPECT_EQ(key_options.ratchet_salt.size(), 8u);

  auto key_provider1 =
      webrtc::make_ref_counted<DefaultKeyProviderImpl>(key_options);
  EXPECT_NE(key_provider1, nullptr);

  auto key_provider2 =
      webrtc::make_ref_counted<DefaultKeyProviderImpl>(key_options);
  EXPECT_NE(key_provider2, nullptr);

  std::string participant_id = "participant_1";
  key_provider1->SetKey(participant_id, 0,
                        std::vector<uint8_t>{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
                                             11, 12, 13, 14, 15});
  key_provider2->SetKey(participant_id, 0,
                        std::vector<uint8_t>{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
                                             11, 12, 13, 14, 15});

  auto data_packet_cryptor1 = webrtc::make_ref_counted<DataPacketCryptor>(
      FrameCryptorTransformer::Algorithm::kAesGcm, key_provider1);
  EXPECT_NE(data_packet_cryptor1, nullptr);

  auto data_packet_cryptor2 = webrtc::make_ref_counted<DataPacketCryptor>(
      FrameCryptorTransformer::Algorithm::kAesGcm, key_provider2);
  EXPECT_NE(data_packet_cryptor2, nullptr);

  auto encrypted_data = data_packet_cryptor1->Encrypt(
      participant_id, 0,
      std::vector<uint8_t>(
          {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15}));

  EXPECT_TRUE(encrypted_data.ok());
  EXPECT_EQ(encrypted_data.value()->data.size(), 16 + 16u);  // data + tag

  auto decrypted_data =
      data_packet_cryptor2->Decrypt(participant_id, encrypted_data.value());
  EXPECT_TRUE(decrypted_data.ok());

  key_provider1->RatchetKey(participant_id, 0);
  auto encrypted_data2 = data_packet_cryptor1->Encrypt(
      participant_id, 0,
      std::vector<uint8_t>(
          {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15}));
  EXPECT_TRUE(encrypted_data2.ok());

  // decrypt with auto-ratcheted key should be successful
  auto decrypted_data2 =
      data_packet_cryptor2->Decrypt(participant_id, encrypted_data2.value());
  EXPECT_TRUE(decrypted_data2.ok());
}

TEST(DataPacketCryptor, IVGeneration) {
  auto key_options = KeyProviderOptions();
  key_options.ratchet_salt =
      std::vector<uint8_t>({0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07});
  auto key_provider =
      webrtc::make_ref_counted<DefaultKeyProviderImpl>(key_options);

  std::string participant_id = "participant_1";
  key_provider->SetKey(participant_id, 0,
                       std::vector<uint8_t>{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
                                            11, 12, 13, 14, 15});
  auto data_packet_cryptor = webrtc::make_ref_counted<DataPacketCryptor>(
      FrameCryptorTransformer::Algorithm::kAesGcm, key_provider);
  EXPECT_NE(data_packet_cryptor, nullptr);
  Thread::SleepMs(200);
  auto encrypted_data = data_packet_cryptor->Encrypt(
      participant_id, 0,
      std::vector<uint8_t>(
          {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15}));
  EXPECT_TRUE(encrypted_data.ok());
  Thread::SleepMs(200);  // ensure different timestamp for IV generation
  auto encrypted_data2 = data_packet_cryptor->Encrypt(
      participant_id, 0,
      std::vector<uint8_t>(
          {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15}));
  EXPECT_TRUE(encrypted_data2.ok());

  EXPECT_NE(encrypted_data.value()->iv, encrypted_data2.value()->iv);
}

namespace {

std::vector<uint8_t> ParseHex(std::string_view hex) {
  std::vector<uint8_t> out;
  int acc = -1;
  for (char c : hex) {
    if (c == ' ' || c == '\n' || c == '\r') {
      continue;
    }
    int nibble = 0;
    if (c >= '0' && c <= '9') {
      nibble = c - '0';
    } else if (c >= 'a' && c <= 'f') {
      nibble = c - 'a' + 10;
    } else if (c >= 'A' && c <= 'F') {
      nibble = c - 'A' + 10;
    } else {
      continue;
    }
    if (acc < 0) {
      acc = nibble;
    } else {
      out.push_back(static_cast<uint8_t>((acc << 4) | nibble));
      acc = -1;
    }
  }
  return out;
}

const std::vector<uint8_t> kJsKey = ParseHex("000102030405060708090a0b0c0d0e0f");
const std::array<uint8_t, 8> kJsPrefix{0x11, 0x11, 0x11, 0x11,
                                       0x11, 0x11, 0x11, 0x11};

class RecordingSink : public TransformedFrameCallback {
 public:
  void OnTransformedFrame(
      std::unique_ptr<TransformableFrameInterface> frame) override {
    MutexLock lock(&mutex_);
    ++count_;
    if (frame) {
      auto data = frame->GetData();
      last_.assign(data.begin(), data.end());
    }
    done_.Set();
  }

  int count() const {
    MutexLock lock(&mutex_);
    return count_;
  }
  std::vector<uint8_t> last() const {
    MutexLock lock(&mutex_);
    return last_;
  }
  bool Wait(TimeDelta timeout = TimeDelta::Seconds(2)) {
    return done_.Wait(timeout);
  }
  void ResetEvent() { done_.Reset(); }

 private:
  mutable Mutex mutex_;
  int count_ = 0;
  std::vector<uint8_t> last_;
  Event done_;
};

class FakeAudioFrame : public NiceMock<MockTransformableAudioFrame> {
 public:
  std::vector<uint8_t> payload;
  std::vector<uint32_t> csrcs;
  Direction direction = Direction::kSender;
  uint32_t ssrc = 1;

  FakeAudioFrame() {
    ON_CALL(*this, GetData).WillByDefault([this] {
      return ArrayView<const uint8_t>(payload);
    });
    ON_CALL(*this, SetData)
        .WillByDefault([this](ArrayView<const uint8_t> data) {
          payload.assign(data.begin(), data.end());
        });
    ON_CALL(*this, GetDirection).WillByDefault([this] { return direction; });
    ON_CALL(*this, GetSsrc).WillByDefault([this] { return ssrc; });
    ON_CALL(*this, GetTimestamp).WillByDefault(Return(1000u));
    ON_CALL(*this, GetPayloadType).WillByDefault(Return(111));
    ON_CALL(*this, GetMimeType).WillByDefault(Return(std::string("audio/opus")));
    ON_CALL(*this, GetContributingSources).WillByDefault([this] {
      return ArrayView<const uint32_t>(csrcs);
    });
    ON_CALL(*this, SequenceNumber)
        .WillByDefault(Return(std::optional<uint16_t>()));
    ON_CALL(*this, AbsoluteCaptureTimestamp)
        .WillByDefault(Return(std::optional<uint64_t>()));
    ON_CALL(*this, AudioLevel).WillByDefault(Return(std::optional<uint8_t>()));
    ON_CALL(*this, ReceiveTime).WillByDefault(Return(std::optional<Timestamp>()));
    ON_CALL(*this, CaptureTime).WillByDefault(Return(std::optional<Timestamp>()));
    ON_CALL(*this, SenderCaptureTimeOffset)
        .WillByDefault(Return(std::optional<TimeDelta>()));
  }
};

class FakeVideoFrame : public NiceMock<MockTransformableVideoFrame> {
 public:
  std::vector<uint8_t> payload;
  Direction direction = Direction::kSender;
  uint32_t ssrc = 2;
  bool keyframe = true;
  VideoCodecType codec = kVideoCodecVP8;
  VideoFrameMetadata metadata;

  FakeVideoFrame() {
    metadata.SetCodec(codec);
    ON_CALL(*this, GetData).WillByDefault([this] {
      return ArrayView<const uint8_t>(payload);
    });
    ON_CALL(*this, SetData)
        .WillByDefault([this](ArrayView<const uint8_t> data) {
          payload.assign(data.begin(), data.end());
        });
    ON_CALL(*this, GetDirection).WillByDefault([this] { return direction; });
    ON_CALL(*this, GetSsrc).WillByDefault([this] { return ssrc; });
    ON_CALL(*this, GetTimestamp).WillByDefault(Return(2000u));
    ON_CALL(*this, GetPayloadType).WillByDefault(Return(96));
    ON_CALL(*this, IsKeyFrame).WillByDefault([this] { return keyframe; });
    ON_CALL(*this, Metadata).WillByDefault([this] {
      metadata.SetCodec(codec);
      return metadata;
    });
    ON_CALL(*this, GetMimeType).WillByDefault(Return(std::string("video/VP8")));
    ON_CALL(*this, ReceiveTime).WillByDefault(Return(std::optional<Timestamp>()));
    ON_CALL(*this, CaptureTime).WillByDefault(Return(std::optional<Timestamp>()));
    ON_CALL(*this, SenderCaptureTimeOffset)
        .WillByDefault(Return(std::optional<TimeDelta>()));
  }
};

class FakeEncryptionManager : public EncryptionManager {
 public:
  bool Encrypt(const FrameCryptoInput& in,
               Buffer& out,
               FrameCryptionState* state) override {
    out.Clear();
    out.AppendData(in.data);
    const uint8_t marker[] = {'F', 'A', 'K', 'E'};
    out.AppendData(marker, 4);
    *state = kOk;
    return true;
  }
  bool Decrypt(const FrameCryptoInput& in,
               Buffer& out,
               FrameCryptionState* state) override {
    if (in.data.size() < 4) {
      *state = kDecryptionFailed;
      return false;
    }
    out.Clear();
    out.AppendData(in.data.subview(0, in.data.size() - 4));
    *state = kOk;
    return true;
  }
  bool SetKey(std::string_view,
              int,
              ArrayView<const uint8_t>) override {
    return true;
  }
  bool SetSharedKey(int, ArrayView<const uint8_t>) override { return true; }
};

scoped_refptr<FrameCryptorTransformer> NewCryptor(
    const std::string& participant_id,
    FrameCryptorTransformer::TrackType track_type,
    scoped_refptr<EncryptionManager> manager) {
  return scoped_refptr<FrameCryptorTransformer>(new FrameCryptorTransformer(
      Thread::Current(), participant_id, track_type, std::move(manager)));
}

void PushFrame(const scoped_refptr<FrameCryptorTransformer>& cryptor,
               std::unique_ptr<TransformableFrameInterface> frame) {
  static_cast<FrameTransformerInterface*>(cryptor.get())
      ->Transform(std::move(frame));
}

struct FrameCryptoFixture {
  AutoThread main;
  scoped_refptr<DefaultEncryptionManager> manager;
  scoped_refptr<FrameCryptorTransformer> sender;
  scoped_refptr<FrameCryptorTransformer> receiver;
  scoped_refptr<RecordingSink> sink;

  FrameCryptoFixture() {
    manager = make_ref_counted<DefaultEncryptionManager>();
    manager->SetKeyWithIvPrefix("local", 0, kJsKey, kJsPrefix);
    sender = scoped_refptr<FrameCryptorTransformer>(new FrameCryptorTransformer(
        Thread::Current(), "local",
        FrameCryptorTransformer::TrackType::kAudio, manager));
    receiver = scoped_refptr<FrameCryptorTransformer>(
        new FrameCryptorTransformer(
            Thread::Current(), "local",
            FrameCryptorTransformer::TrackType::kAudio, manager));
    sender->SetEnabled(true);
    receiver->SetEnabled(true);
    sink = make_ref_counted<RecordingSink>();
    static_cast<FrameTransformerInterface*>(sender.get())
        ->RegisterTransformedFrameCallback(sink);
    static_cast<FrameTransformerInterface*>(receiver.get())
        ->RegisterTransformedFrameCallback(sink);
  }

  void WaitIdle() { manager->WaitUntilIdleForTest(); }
};

}  // namespace

TEST(KeyProviderOptions, CopyCtorCopiesDiscardAndFrameTrailer) {
  KeyProviderOptions src;
  src.discard_frame_when_cryptor_not_ready = true;
  src.use_frame_trailer = true;
  KeyProviderOptions copy(src);
  EXPECT_TRUE(copy.discard_frame_when_cryptor_not_ready);
  EXPECT_TRUE(copy.use_frame_trailer);
}

TEST(DefaultEncryptionManager, RawKeyAcceptRejectRemove) {
  auto manager = make_ref_counted<DefaultEncryptionManager>();
  std::vector<uint8_t> k16(16, 1);
  std::vector<uint8_t> k32(32, 2);
  std::vector<uint8_t> k15(15, 3);
  std::vector<uint8_t> k33(33, 4);
  EXPECT_TRUE(manager->SetKey("p", 0, k16));
  EXPECT_TRUE(manager->SetKey("p", 255, k16));
  EXPECT_FALSE(manager->SetKey("p", 15, k32));
  EXPECT_FALSE(manager->SetKey("p", 15, k15));
  EXPECT_FALSE(manager->SetKey("p", 15, k33));
  EXPECT_FALSE(manager->SetKey("p", -1, k16));
  EXPECT_FALSE(manager->SetKey("p", 256, k16));
  manager->RemoveKey("p", 0);
  manager->RemoveKey("p", 0);
  manager->RemoveAllKeys("p");
}

TEST(DefaultEncryptionManager, TwoSendersShareCounter) {
  AutoThread main;
  auto manager = make_ref_counted<DefaultEncryptionManager>();
  manager->SetKeyWithIvPrefix("local", 0, kJsKey, kJsPrefix);
  auto a = NewCryptor("local", FrameCryptorTransformer::TrackType::kAudio,
                      manager);
  auto b = NewCryptor("local", FrameCryptorTransformer::TrackType::kAudio,
                      manager);
  a->SetEnabled(true);
  b->SetEnabled(true);
  auto sink_a = make_ref_counted<RecordingSink>();
  auto sink_b = make_ref_counted<RecordingSink>();
  static_cast<FrameTransformerInterface*>(a.get())
      ->RegisterTransformedFrameCallback(sink_a);
  static_cast<FrameTransformerInterface*>(b.get())
      ->RegisterTransformedFrameCallback(sink_b);

  auto fa = std::make_unique<FakeAudioFrame>();
  fa->payload = ParseHex("78aabbccdd");
  fa->direction = TransformableFrameInterface::Direction::kSender;
  PushFrame(a, std::move(fa));
  manager->WaitUntilIdleForTest();
  EXPECT_EQ(sink_a->count(), 1);
  auto fb = std::make_unique<FakeAudioFrame>();
  fb->payload = ParseHex("78aabbccdd");
  fb->direction = TransformableFrameInterface::Direction::kSender;
  PushFrame(b, std::move(fb));
  manager->WaitUntilIdleForTest();
  EXPECT_EQ(sink_b->count(), 1);
  EXPECT_NE(sink_a->last(), sink_b->last());
}

TEST(DefaultEncryptionManager, ReimportGetsNewPrefix) {
  auto manager = make_ref_counted<DefaultEncryptionManager>();
  EXPECT_TRUE(manager->SetKey("p", 0, kJsKey));
  FrameCryptoInput in;
  auto pt = ParseHex("78aabbccdd");
  in.data = pt;
  in.media_type = FrameCryptorTransformer::MediaType::kAudioFrame;
  in.key_index = 0;
  in.participant_id = "p";
  Buffer first;
  FrameCryptionState state = kNew;
  EXPECT_TRUE(manager->Encrypt(in, first, &state));
  EXPECT_TRUE(manager->SetKey("p", 0, kJsKey));
  Buffer second;
  EXPECT_TRUE(manager->Encrypt(in, second, &state));
  ASSERT_GE(first.size(), 20u);
  ASSERT_GE(second.size(), 20u);
  EXPECT_NE(std::vector<uint8_t>(first.begin() + first.size() - 16,
                                 first.begin() + first.size() - 8),
            std::vector<uint8_t>(second.begin() + second.size() - 16,
                                 second.begin() + second.size() - 8));
}

TEST(FrameCryptorTransformer, InjectedManagerIsUsed) {
  AutoThread main;
  auto manager = make_ref_counted<FakeEncryptionManager>();
  auto cryptor =
      NewCryptor("p", FrameCryptorTransformer::TrackType::kAudio, manager);
  cryptor->SetEnabled(true);
  auto sink = make_ref_counted<RecordingSink>();
  static_cast<FrameTransformerInterface*>(cryptor.get())
      ->RegisterTransformedFrameCallback(sink);
  auto frame = std::make_unique<FakeAudioFrame>();
  frame->payload = {1, 2, 3};
  frame->direction = TransformableFrameInterface::Direction::kSender;
  PushFrame(cryptor, std::move(frame));
  EXPECT_TRUE(sink->Wait());
  EXPECT_EQ(sink->count(), 1);
  auto got = sink->last();
  ASSERT_EQ(got.size(), 7u);
  EXPECT_EQ(got[3], 'F');
  EXPECT_EQ(got[4], 'A');
  EXPECT_EQ(got[5], 'K');
  EXPECT_EQ(got[6], 'E');
}

TEST(FrameCryptorTransformer, FrameTrailerPinnedOpus) {
  FrameCryptoFixture fx;
  auto frame = std::make_unique<FakeAudioFrame>();
  frame->payload = ParseHex("78aabbccdd");
  frame->direction = TransformableFrameInterface::Direction::kSender;
  PushFrame(fx.sender, std::move(frame));
  fx.WaitIdle();
  EXPECT_EQ(fx.sink->count(), 1);
  EXPECT_EQ(fx.sink->last(),
            ParseHex("78 d02bf795e85c0bed034f7b282ca617cf76d57eb0 "
                     "00000001 1111111111111111 00 0001 01 e2eefeed"));

  fx.sink->ResetEvent();
  auto enc = std::make_unique<FakeAudioFrame>();
  enc->payload = fx.sink->last();
  enc->direction = TransformableFrameInterface::Direction::kReceiver;
  PushFrame(fx.receiver, std::move(enc));
  fx.WaitIdle();
  EXPECT_EQ(fx.sink->count(), 2);
  EXPECT_EQ(fx.sink->last(), ParseHex("78aabbccdd"));
}

TEST(FrameCryptorTransformer, FrameTrailerPinnedVp8) {
  AutoThread main;
  auto keys = make_ref_counted<DefaultKeyProviderImpl>(KeyProviderOptions());
  auto manager = make_ref_counted<DefaultEncryptionManager>(
      FrameCryptorTransformer::Algorithm::kAesGcmTrailer, keys);
  manager->SetKeyWithIvPrefix("local", 0, kJsKey, kJsPrefix);
  auto sender =
      NewCryptor("local", FrameCryptorTransformer::TrackType::kVideo,
                 manager);
  auto receiver =
      NewCryptor("local", FrameCryptorTransformer::TrackType::kVideo,
                 manager);
  sender->SetEnabled(true);
  receiver->SetEnabled(true);
  auto sink = make_ref_counted<RecordingSink>();
  static_cast<FrameTransformerInterface*>(sender.get())
      ->RegisterTransformedFrameSinkCallback(sink, 2);
  static_cast<FrameTransformerInterface*>(receiver.get())
      ->RegisterTransformedFrameSinkCallback(sink, 2);
  auto frame = std::make_unique<FakeVideoFrame>();
  frame->payload = ParseHex("10111213141516171819aabb");
  frame->keyframe = true;
  frame->codec = kVideoCodecVP8;
  frame->direction = TransformableFrameInterface::Direction::kSender;
  PushFrame(sender, std::move(frame));
  manager->WaitUntilIdleForTest();
  EXPECT_EQ(sink->count(), 1);
  EXPECT_EQ(sink->last(),
            ParseHex("10111213141516171819 d02b0484ce4aa2b21a4a83cbfe2ed6511c68 "
                     "00000001 1111111111111111 00 000a 01 e2eefeed"));

  sink->ResetEvent();
  auto enc = std::make_unique<FakeVideoFrame>();
  enc->payload = sink->last();
  enc->keyframe = true;
  enc->codec = kVideoCodecVP8;
  enc->direction = TransformableFrameInterface::Direction::kReceiver;
  PushFrame(receiver, std::move(enc));
  manager->WaitUntilIdleForTest();
  EXPECT_EQ(sink->count(), 2);
  EXPECT_EQ(sink->last(), ParseHex("10111213141516171819aabb"));
}

TEST(FrameCryptorTransformer, FrameTrailerPinnedH264) {
  AutoThread main;
  auto keys = make_ref_counted<DefaultKeyProviderImpl>(KeyProviderOptions());
  auto manager = make_ref_counted<DefaultEncryptionManager>(
      FrameCryptorTransformer::Algorithm::kAesGcmTrailer, keys);
  manager->SetKeyWithIvPrefix("local", 0, kJsKey, kJsPrefix);
  auto sender =
      NewCryptor("local", FrameCryptorTransformer::TrackType::kVideo,
                 manager);
  auto receiver =
      NewCryptor("local", FrameCryptorTransformer::TrackType::kVideo,
                 manager);
  sender->SetEnabled(true);
  receiver->SetEnabled(true);
  auto sink = make_ref_counted<RecordingSink>();
  static_cast<FrameTransformerInterface*>(sender.get())
      ->RegisterTransformedFrameSinkCallback(sink, 2);
  static_cast<FrameTransformerInterface*>(receiver.get())
      ->RegisterTransformedFrameSinkCallback(sink, 2);
  auto frame = std::make_unique<FakeVideoFrame>();
  frame->payload = ParseHex("00000001 65 8884deadbe");
  frame->keyframe = true;
  frame->codec = kVideoCodecH264;
  frame->direction = TransformableFrameInterface::Direction::kSender;
  PushFrame(sender, std::move(frame));
  manager->WaitUntilIdleForTest();
  EXPECT_EQ(sink->count(), 1);
  EXPECT_EQ(sink->last(),
            ParseHex("000000016588 fe4e96f631df11f57a43ed2003eaad0c5d6db632 "
                     "0000030001 1111111111111111 00 8006 01 e2eefeed"));

  sink->ResetEvent();
  auto enc = std::make_unique<FakeVideoFrame>();
  enc->payload = sink->last();
  enc->keyframe = true;
  enc->codec = kVideoCodecH264;
  enc->direction = TransformableFrameInterface::Direction::kReceiver;
  PushFrame(receiver, std::move(enc));
  manager->WaitUntilIdleForTest();
  EXPECT_EQ(sink->count(), 2);
  EXPECT_EQ(sink->last(), ParseHex("00000001 65 8884deadbe"));
}

TEST(FrameCryptorTransformer, FrameTrailerUnframedForwards) {
  FrameCryptoFixture fx;
  auto frame = std::make_unique<FakeAudioFrame>();
  frame->payload = ParseHex("78aabbccdd");
  frame->direction = TransformableFrameInterface::Direction::kReceiver;
  PushFrame(fx.receiver, std::move(frame));
  fx.WaitIdle();
  EXPECT_EQ(fx.sink->count(), 1);
  EXPECT_EQ(fx.sink->last(), ParseHex("78aabbccdd"));
}

TEST(FrameCryptorTransformer, FrameTrailerDisabledForwardsClear) {
  FrameCryptoFixture fx;
  fx.sender->SetEnabled(false);
  auto frame = std::make_unique<FakeAudioFrame>();
  frame->payload = ParseHex("78aabbccdd");
  frame->direction = TransformableFrameInterface::Direction::kSender;
  PushFrame(fx.sender, std::move(frame));
  fx.WaitIdle();
  EXPECT_EQ(fx.sink->count(), 1);
  EXPECT_EQ(fx.sink->last(), ParseHex("78aabbccdd"));
}

TEST(FrameCryptorTransformer, FrameTrailerMissingKeyDropsThenRecovers) {
  FrameCryptoFixture fx;
  fx.manager->RemoveAllKeys("local");
  auto bad = std::make_unique<FakeAudioFrame>();
  bad->payload = ParseHex("78aabbccdd");
  bad->direction = TransformableFrameInterface::Direction::kSender;
  PushFrame(fx.sender, std::move(bad));
  fx.WaitIdle();
  EXPECT_EQ(fx.sink->count(), 0);
  fx.manager->SetKeyWithIvPrefix("local", 0, kJsKey, kJsPrefix);
  auto good = std::make_unique<FakeAudioFrame>();
  good->payload = ParseHex("78aabbccdd");
  good->direction = TransformableFrameInterface::Direction::kSender;
  PushFrame(fx.sender, std::move(good));
  fx.WaitIdle();
  EXPECT_EQ(fx.sink->count(), 1);
}

TEST(FrameCryptorTransformer, FrameTrailerReplayAndNextValid) {
  FrameCryptoFixture fx;
  auto send = std::make_unique<FakeAudioFrame>();
  send->payload = ParseHex("78aabbccdd");
  send->direction = TransformableFrameInterface::Direction::kSender;
  PushFrame(fx.sender, std::move(send));
  fx.WaitIdle();
  auto encrypted = fx.sink->last();
  EXPECT_EQ(fx.sink->count(), 1);

  auto recv1 = std::make_unique<FakeAudioFrame>();
  recv1->payload = encrypted;
  recv1->direction = TransformableFrameInterface::Direction::kReceiver;
  PushFrame(fx.receiver, std::move(recv1));
  fx.WaitIdle();
  EXPECT_EQ(fx.sink->count(), 2);

  auto replay = std::make_unique<FakeAudioFrame>();
  replay->payload = encrypted;
  replay->direction = TransformableFrameInterface::Direction::kReceiver;
  PushFrame(fx.receiver, std::move(replay));
  fx.WaitIdle();
  EXPECT_EQ(fx.sink->count(), 2);

  auto send2 = std::make_unique<FakeAudioFrame>();
  send2->payload = ParseHex("78aabbccdd");
  send2->direction = TransformableFrameInterface::Direction::kSender;
  PushFrame(fx.sender, std::move(send2));
  fx.WaitIdle();
  auto recv2 = std::make_unique<FakeAudioFrame>();
  recv2->payload = fx.sink->last();
  recv2->direction = TransformableFrameInterface::Direction::kReceiver;
  PushFrame(fx.receiver, std::move(recv2));
  fx.WaitIdle();
  EXPECT_EQ(fx.sink->count(), 4);
}

TEST(FrameCryptorTransformer, FrameTrailerReceiverReplaceKeepsReplay) {
  FrameCryptoFixture fx;
  auto send = std::make_unique<FakeAudioFrame>();
  send->payload = ParseHex("78aabbccdd");
  send->direction = TransformableFrameInterface::Direction::kSender;
  PushFrame(fx.sender, std::move(send));
  fx.WaitIdle();
  auto encrypted = fx.sink->last();
  auto recv1 = std::make_unique<FakeAudioFrame>();
  recv1->payload = encrypted;
  recv1->direction = TransformableFrameInterface::Direction::kReceiver;
  PushFrame(fx.receiver, std::move(recv1));
  fx.WaitIdle();
  EXPECT_EQ(fx.sink->count(), 2);

  auto replacement = NewCryptor(
      "local", FrameCryptorTransformer::TrackType::kAudio, fx.manager);
  replacement->SetEnabled(true);
  auto sink2 = make_ref_counted<RecordingSink>();
  static_cast<FrameTransformerInterface*>(replacement.get())
      ->RegisterTransformedFrameCallback(sink2);
  auto replay = std::make_unique<FakeAudioFrame>();
  replay->payload = encrypted;
  replay->direction = TransformableFrameInterface::Direction::kReceiver;
  PushFrame(replacement, std::move(replay));
  fx.WaitIdle();
  EXPECT_EQ(sink2->count(), 0);
}

TEST(FrameCryptorTransformer, FrameTrailerMalformedTrailerDropsThenRecovers) {
  FrameCryptoFixture fx;
  auto send = std::make_unique<FakeAudioFrame>();
  send->payload = ParseHex("78aabbccdd");
  send->direction = TransformableFrameInterface::Direction::kSender;
  PushFrame(fx.sender, std::move(send));
  fx.WaitIdle();
  auto encrypted = fx.sink->last();
  // Keep magic, corrupt version → JS drops as unsupported_version.
  ASSERT_GE(encrypted.size(), 5u);
  encrypted[encrypted.size() - 5] ^= 0xff;
  auto bad = std::make_unique<FakeAudioFrame>();
  bad->payload = encrypted;
  bad->direction = TransformableFrameInterface::Direction::kReceiver;
  PushFrame(fx.receiver, std::move(bad));
  fx.WaitIdle();
  EXPECT_EQ(fx.sink->count(), 1);

  auto send2 = std::make_unique<FakeAudioFrame>();
  send2->payload = ParseHex("78aabbccdd");
  send2->direction = TransformableFrameInterface::Direction::kSender;
  PushFrame(fx.sender, std::move(send2));
  fx.WaitIdle();
  auto good = std::make_unique<FakeAudioFrame>();
  good->payload = fx.sink->last();
  good->direction = TransformableFrameInterface::Direction::kReceiver;
  PushFrame(fx.receiver, std::move(good));
  fx.WaitIdle();
  EXPECT_EQ(fx.sink->count(), 3);
}

TEST(FrameCryptorTransformer, FrameTrailerNoDedicatedThread) {
  FrameCryptoFixture fx;
  EXPECT_FALSE(fx.sender->has_dedicated_thread_for_test());
  EXPECT_FALSE(fx.receiver->has_dedicated_thread_for_test());
}

TEST(FrameCryptorTransformer, FrameTrailerAes256RoundTrip) {
  auto manager = make_ref_counted<DefaultEncryptionManager>(
      DefaultEncryptionManager::Cipher::kAes256Gcm);
  std::vector<uint8_t> k32(32, 0x42);
  EXPECT_TRUE(manager->SetKeyWithIvPrefix("p", 255, k32, kJsPrefix));
  EXPECT_FALSE(manager->SetKey("p", 0, kJsKey));
  FrameCryptoInput in;
  auto pt = ParseHex("78aabbccdd");
  in.data = pt;
  in.media_type = FrameCryptorTransformer::MediaType::kAudioFrame;
  in.key_index = 255;
  in.participant_id = "p";
  Buffer enc;
  FrameCryptionState state = kNew;
  EXPECT_TRUE(manager->Encrypt(in, enc, &state));
  FrameCryptoInput dec_in = in;
  dec_in.data = enc;
  Buffer dec;
  EXPECT_TRUE(manager->Decrypt(dec_in, dec, &state));
  EXPECT_EQ(std::vector<uint8_t>(dec.begin(), dec.end()), pt);
}

TEST(FrameCryptorTransformer, FrameTrailerCounterExhaustion) {
  auto manager = make_ref_counted<DefaultEncryptionManager>();
  manager->SetKeyWithIvPrefix("p", 0, kJsKey, kJsPrefix);
  manager->SetSendCounterForTest(0xffffffffu);
  FrameCryptoInput in;
  auto pt = ParseHex("78aabbccdd");
  in.data = pt;
  in.media_type = FrameCryptorTransformer::MediaType::kAudioFrame;
  in.participant_id = "p";
  Buffer out;
  FrameCryptionState state = kNew;
  EXPECT_FALSE(manager->Encrypt(in, out, &state));
  EXPECT_EQ(state, kCounterExhausted);
}

uint8_t TrailerKeyIndex(const Buffer& frame) {
  return frame[frame.size() - 8];
}

uint16_t TrailerClearAndFlags(const Buffer& frame) {
  return static_cast<uint16_t>((uint16_t{frame[frame.size() - 7]} << 8) |
                               uint16_t{frame[frame.size() - 6]});
}

std::vector<uint8_t> DummyFramedPayload(size_t body,
                                        uint16_t clear_bytes,
                                        uint8_t version = kFrameTrailerVersion,
                                        bool is_rbsp = false) {
  std::vector<uint8_t> frame(body + kFrameTrailerLen, 0x99);
  WriteFrameTrailer(frame.data() + body, 1, kJsPrefix, 0, clear_bytes, is_rbsp);
  frame[frame.size() - 5] = version;
  return frame;
}

FrameCryptoInput MakeAudioInput(
    std::string_view participant_id,
    ArrayView<const uint8_t> data,
    uint32_t ssrc = 1,
    FrameCryptorTransformer::TrackType track_type =
        FrameCryptorTransformer::TrackType::kAudio) {
  FrameCryptoInput in;
  in.data = data;
  in.media_type = FrameCryptorTransformer::MediaType::kAudioFrame;
  in.track_type = track_type;
  in.ssrc = ssrc;
  in.participant_id = participant_id;
  return in;
}

FrameCryptoInput MakeVideoInput(
    std::string_view participant_id,
    ArrayView<const uint8_t> data,
    VideoCodecType codec,
    bool keyframe,
    uint32_t ssrc = 2,
    FrameCryptorTransformer::TrackType track_type =
        FrameCryptorTransformer::TrackType::kVideo) {
  FrameCryptoInput in;
  in.data = data;
  in.media_type = FrameCryptorTransformer::MediaType::kVideoFrame;
  in.track_type = track_type;
  in.video_codec = codec;
  in.is_keyframe = keyframe;
  in.ssrc = ssrc;
  in.participant_id = participant_id;
  return in;
}

bool RoundTrip(DefaultEncryptionManager* manager,
               FrameCryptoInput in,
               const std::vector<uint8_t>& plaintext) {
  Buffer enc;
  FrameCryptionState state = kNew;
  if (!manager->Encrypt(in, enc, &state)) {
    return false;
  }
  in.data = enc;
  Buffer dec;
  if (!manager->Decrypt(in, dec, &state)) {
    return false;
  }
  return std::vector<uint8_t>(dec.begin(), dec.end()) == plaintext;
}

TEST(DefaultEncryptionManager, EncodeUsesLatestKeyIndexNotInputIndex) {
  auto manager = make_ref_counted<DefaultEncryptionManager>();
  const std::array<uint8_t, 8> p0{0x11, 0x11, 0x11, 0x11,
                                  0x11, 0x11, 0x11, 0x11};
  const std::array<uint8_t, 8> p1{0x22, 0x22, 0x22, 0x22,
                                  0x22, 0x22, 0x22, 0x22};
  EXPECT_TRUE(manager->SetKeyWithIvPrefix("p", 0, kJsKey, p0));
  EXPECT_TRUE(manager->SetKeyWithIvPrefix("p", 1, kJsKey, p1));
  auto pt = ParseHex("78aabbccdd");
  auto in = MakeAudioInput("p", pt);
  in.key_index = 0;
  Buffer out;
  FrameCryptionState state = kNew;
  EXPECT_TRUE(manager->Encrypt(in, out, &state));
  EXPECT_EQ(TrailerKeyIndex(out), 1);
}

TEST(DefaultEncryptionManager, RemoveLatestDoesNotPromoteOlderUserKey) {
  auto manager = make_ref_counted<DefaultEncryptionManager>();
  EXPECT_TRUE(manager->SetKeyWithIvPrefix("p", 0, kJsKey, kJsPrefix));
  const std::array<uint8_t, 8> p1{0x22, 0x22, 0x22, 0x22,
                                  0x22, 0x22, 0x22, 0x22};
  EXPECT_TRUE(manager->SetKeyWithIvPrefix("p", 1, kJsKey, p1));
  manager->RemoveKey("p", 1);
  auto pt = ParseHex("78aabbccdd");
  auto in = MakeAudioInput("p", pt);
  Buffer out;
  FrameCryptionState state = kNew;
  EXPECT_FALSE(manager->Encrypt(in, out, &state));
  EXPECT_EQ(state, kMissingKey);
}

TEST(DefaultEncryptionManager, RemoveLatestFallsBackToActiveShared) {
  auto manager = make_ref_counted<DefaultEncryptionManager>();
  EXPECT_TRUE(manager->SetKeyWithIvPrefix("p", 0, kJsKey, kJsPrefix));
  const std::array<uint8_t, 8> p1{0x22, 0x22, 0x22, 0x22,
                                  0x22, 0x22, 0x22, 0x22};
  const std::array<uint8_t, 8> p2{0x33, 0x33, 0x33, 0x33,
                                  0x33, 0x33, 0x33, 0x33};
  EXPECT_TRUE(manager->SetKeyWithIvPrefix("p", 1, kJsKey, p1));
  EXPECT_TRUE(manager->SetSharedKeyWithIvPrefix(2, kJsKey, p2));
  manager->RemoveKey("p", 1);
  auto pt = ParseHex("78aabbccdd");
  auto in = MakeAudioInput("p", pt);
  Buffer out;
  FrameCryptionState state = kNew;
  EXPECT_TRUE(manager->Encrypt(in, out, &state));
  EXPECT_EQ(TrailerKeyIndex(out), 2);
}

TEST(DefaultEncryptionManager, RemoveActiveSharedDisablesEncodeFallback) {
  auto manager = make_ref_counted<DefaultEncryptionManager>();
  EXPECT_TRUE(manager->SetSharedKeyWithIvPrefix(0, kJsKey, kJsPrefix));
  EXPECT_TRUE(manager->SetSharedKeyWithIvPrefix(1, kJsKey, kJsPrefix));
  manager->RemoveSharedKey(1);
  auto pt = ParseHex("78aabbccdd");
  auto in = MakeAudioInput("p", pt);
  Buffer out;
  FrameCryptionState state = kNew;
  EXPECT_FALSE(manager->Encrypt(in, out, &state));
  EXPECT_EQ(state, kMissingKey);
}

TEST(DefaultEncryptionManager, ParticipantNamedSharedIsNotSharedStore) {
  auto manager = make_ref_counted<DefaultEncryptionManager>();
  const std::array<uint8_t, 8> user_prefix{0x11, 0x11, 0x11, 0x11,
                                           0x11, 0x11, 0x11, 0x11};
  const std::array<uint8_t, 8> shared_prefix{0x44, 0x44, 0x44, 0x44,
                                             0x44, 0x44, 0x44, 0x44};
  EXPECT_TRUE(manager->SetKeyWithIvPrefix("shared", 0, kJsKey, user_prefix));
  EXPECT_TRUE(manager->SetSharedKeyWithIvPrefix(1, kJsKey, shared_prefix));
  auto pt = ParseHex("78aabbccdd");
  auto in = MakeAudioInput("shared", pt);
  Buffer out;
  FrameCryptionState state = kNew;
  EXPECT_TRUE(manager->Encrypt(in, out, &state));
  EXPECT_EQ(TrailerKeyIndex(out), 0);
}

TEST(DefaultEncryptionManager, DecryptUsesPerUserThenShared) {
  auto manager = make_ref_counted<DefaultEncryptionManager>();
  std::vector<uint8_t> bob_key(16, 0x09);
  EXPECT_TRUE(manager->SetKeyWithIvPrefix("alice", 0, kJsKey, kJsPrefix));
  EXPECT_TRUE(manager->SetKey("bob", 0, bob_key));
  auto pt = ParseHex("78aabbccdd");
  auto enc_in = MakeAudioInput("alice", pt);
  Buffer enc;
  FrameCryptionState state = kNew;
  EXPECT_TRUE(manager->Encrypt(enc_in, enc, &state));

  auto dec_alice = MakeAudioInput("alice", enc);
  Buffer dec;
  EXPECT_TRUE(manager->Decrypt(dec_alice, dec, &state));
  EXPECT_EQ(std::vector<uint8_t>(dec.begin(), dec.end()), pt);

  auto dec_bob = MakeAudioInput("bob", enc);
  Buffer bob_out;
  EXPECT_FALSE(manager->Decrypt(dec_bob, bob_out, &state));
  EXPECT_EQ(state, kDecryptionFailed);

  manager->RemoveKey("alice", 0);
  EXPECT_TRUE(manager->SetSharedKeyWithIvPrefix(0, kJsKey, kJsPrefix));
  Buffer enc2;
  auto enc_in2 = MakeAudioInput("alice", pt);
  EXPECT_TRUE(manager->Encrypt(enc_in2, enc2, &state));
  auto dec_shared = MakeAudioInput("alice", enc2);
  Buffer via_shared;
  EXPECT_TRUE(manager->Decrypt(dec_shared, via_shared, &state));
  EXPECT_EQ(std::vector<uint8_t>(via_shared.begin(), via_shared.end()), pt);
}

TEST(DefaultEncryptionManager, FingerprintIsSha256PrefixNotRawKey) {
  auto manager = make_ref_counted<DefaultEncryptionManager>();
  EXPECT_TRUE(manager->SetKey("p", 0, kJsKey));
  auto keys = manager->KeyState();
  ASSERT_EQ(keys.size(), 1u);
  EXPECT_EQ(keys[0].participant_id, "p");
  EXPECT_EQ(keys[0].key_index, 0);
  EXPECT_FALSE(keys[0].shared);
  EXPECT_NE(std::vector<uint8_t>(keys[0].fingerprint.begin(),
                                 keys[0].fingerprint.end()),
            std::vector<uint8_t>(kJsKey.begin(), kJsKey.begin() + 8));
}

TEST(DefaultEncryptionManager, CodecClearBytesAndFailClosed) {
  auto manager = make_ref_counted<DefaultEncryptionManager>();
  EXPECT_TRUE(manager->SetKeyWithIvPrefix("p", 0, kJsKey, kJsPrefix));

  auto vp8_delta = ParseHex("101112aabbcc");
  auto vp8_short = ParseHex("1011121314");
  auto vp9_key = ParseHex("10111213141516171819aabb");
  auto h264_type1 = ParseHex("00000001 41 8884deadbe");
  auto h264_3byte = ParseHex("000001 65 8884deadbe");
  auto h264_sps = ParseHex("00000001 67 aabbccdd");
  auto av1 = ParseHex("0a0b0c0d0e0f");
  auto opus = ParseHex("78aabbccdd");

  EXPECT_TRUE(RoundTrip(manager.get(),
                        MakeVideoInput("p", vp8_delta, kVideoCodecVP8, false),
                        vp8_delta));
  EXPECT_TRUE(RoundTrip(manager.get(),
                        MakeVideoInput("p", vp8_short, kVideoCodecVP8, true),
                        vp8_short));
  EXPECT_TRUE(RoundTrip(manager.get(),
                        MakeVideoInput("p", vp9_key, kVideoCodecVP9, true),
                        vp9_key));
  EXPECT_TRUE(RoundTrip(manager.get(),
                        MakeVideoInput("p", h264_type1, kVideoCodecH264, false),
                        h264_type1));
  EXPECT_TRUE(RoundTrip(manager.get(),
                        MakeVideoInput("p", h264_3byte, kVideoCodecH264, true),
                        h264_3byte));
  EXPECT_TRUE(RoundTrip(manager.get(),
                        MakeVideoInput("p", h264_sps, kVideoCodecH264, true),
                        h264_sps));

  Buffer enc;
  FrameCryptionState state = kNew;
  auto vp8_delta_in = MakeVideoInput("p", vp8_delta, kVideoCodecVP8, false);
  EXPECT_TRUE(manager->Encrypt(vp8_delta_in, enc, &state));
  EXPECT_EQ(TrailerClearAndFlags(enc) & 0x7fff, 3);

  auto vp8_short_in = MakeVideoInput("p", vp8_short, kVideoCodecVP8, true);
  EXPECT_TRUE(manager->Encrypt(vp8_short_in, enc, &state));
  EXPECT_EQ(TrailerClearAndFlags(enc) & 0x7fff, 5);

  auto vp9_in = MakeVideoInput("p", vp9_key, kVideoCodecVP9, true);
  EXPECT_TRUE(manager->Encrypt(vp9_in, enc, &state));
  EXPECT_EQ(TrailerClearAndFlags(enc) & 0x7fff, 10);

  auto sps_in = MakeVideoInput("p", h264_sps, kVideoCodecH264, true);
  EXPECT_TRUE(manager->Encrypt(sps_in, enc, &state));
  EXPECT_EQ(TrailerClearAndFlags(enc) & 0x8000, 0);

  auto av1_in = MakeVideoInput("p", av1, kVideoCodecAV1, true);
  EXPECT_FALSE(manager->Encrypt(av1_in, enc, &state));
  EXPECT_EQ(state, kEncryptionFailed);

  auto h265_in = MakeVideoInput("p", av1, kVideoCodecH265, true, 9);
  EXPECT_FALSE(manager->Encrypt(h265_in, enc, &state));
  EXPECT_EQ(state, kNew);

  auto audio_as_video = MakeAudioInput("p", opus);
  audio_as_video.is_keyframe = true;
  EXPECT_FALSE(manager->Encrypt(audio_as_video, enc, &state));
  EXPECT_EQ(state, kEncryptionFailed);
}

TEST(DefaultEncryptionManager, ReplayIsPerParticipantAndTrackType) {
  auto manager = make_ref_counted<DefaultEncryptionManager>();
  EXPECT_TRUE(manager->SetKeyWithIvPrefix("p", 0, kJsKey, kJsPrefix));
  auto pt = ParseHex("10111213141516171819aabb");
  auto a = MakeVideoInput("p", pt, kVideoCodecVP8, true, 2);
  auto b = MakeVideoInput("p", pt, kVideoCodecVP8, true, 3);
  Buffer enc_a;
  Buffer enc_b;
  FrameCryptionState state = kNew;
  EXPECT_TRUE(manager->Encrypt(a, enc_a, &state));
  EXPECT_TRUE(manager->Encrypt(b, enc_b, &state));

  a.data = enc_a;
  b.data = enc_b;
  Buffer dec;
  EXPECT_TRUE(manager->Decrypt(a, dec, &state));
  EXPECT_TRUE(manager->Decrypt(b, dec, &state));
  EXPECT_FALSE(manager->Decrypt(a, dec, &state));

  auto same_type_other_ssrc =
      MakeVideoInput("p", enc_a, kVideoCodecVP8, true, 3);
  EXPECT_FALSE(manager->Decrypt(same_type_other_ssrc, dec, &state));

  auto screenshare =
      MakeVideoInput("p", enc_a, kVideoCodecVP8, true, 2,
                     FrameCryptorTransformer::TrackType::kScreenshare);
  EXPECT_TRUE(manager->Decrypt(screenshare, dec, &state));

  auto opus = ParseHex("78aabbccdd");
  auto audio = MakeAudioInput("p", opus);
  Buffer enc_audio;
  EXPECT_TRUE(manager->Encrypt(audio, enc_audio, &state));
  audio.data = enc_audio;
  EXPECT_TRUE(manager->Decrypt(audio, dec, &state));
  auto screenshare_audio = MakeAudioInput(
      "p", enc_audio, 1, FrameCryptorTransformer::TrackType::kScreenshareAudio);
  EXPECT_TRUE(manager->Decrypt(screenshare_audio, dec, &state));
}

TEST(DefaultEncryptionManager, EmptyUnsupportedVideoForwardsEmptyPinnedAv1Drops) {
  auto manager = make_ref_counted<DefaultEncryptionManager>();
  std::vector<uint8_t> empty;
  FrameCryptionState state = kNew;
  Buffer out;
  auto opus = MakeAudioInput("p", empty);
  EXPECT_TRUE(manager->Encrypt(opus, out, &state));
  EXPECT_EQ(state, kOk);

  auto av1 = MakeVideoInput("p", empty, kVideoCodecAV1, true);
  EXPECT_TRUE(manager->Encrypt(av1, out, &state));
  EXPECT_EQ(state, kOk);

  av1.codec_name = "av1";
  EXPECT_FALSE(manager->Encrypt(av1, out, &state));
  EXPECT_EQ(state, kEncryptionFailed);
}

TEST(FrameCryptorTransformer, FrameTrailerIgnoresSetKeyIndex) {
  AutoThread main;
  auto manager = make_ref_counted<DefaultEncryptionManager>();
  const std::array<uint8_t, 8> p0{0x11, 0x11, 0x11, 0x11,
                                  0x11, 0x11, 0x11, 0x11};
  const std::array<uint8_t, 8> p1{0x22, 0x22, 0x22, 0x22,
                                  0x22, 0x22, 0x22, 0x22};
  manager->SetKeyWithIvPrefix("local", 0, kJsKey, p0);
  manager->SetKeyWithIvPrefix("local", 1, kJsKey, p1);
  auto sender = NewCryptor("local",
                           FrameCryptorTransformer::TrackType::kAudio,
                           manager);
  sender->SetEnabled(true);
  sender->SetKeyIndex(0);
  auto sink = make_ref_counted<RecordingSink>();
  static_cast<FrameTransformerInterface*>(sender.get())
      ->RegisterTransformedFrameCallback(sink);
  auto frame = std::make_unique<FakeAudioFrame>();
  frame->payload = ParseHex("78aabbccdd");
  frame->direction = TransformableFrameInterface::Direction::kSender;
  PushFrame(sender, std::move(frame));
  manager->WaitUntilIdleForTest();
  ASSERT_EQ(sink->count(), 1);
  auto got = sink->last();
  ASSERT_GE(got.size(), 8u);
  EXPECT_EQ(got[got.size() - 8], 1);
}

TEST(FrameCryptorTransformer, TrackTypeIsSetAtConstruction) {
  AutoThread main;
  auto manager = make_ref_counted<DefaultEncryptionManager>();
  auto audio =
      NewCryptor("p", FrameCryptorTransformer::TrackType::kAudio, manager);
  auto video =
      NewCryptor("p", FrameCryptorTransformer::TrackType::kVideo, manager);
  auto screenshare = NewCryptor(
      "p", FrameCryptorTransformer::TrackType::kScreenshare, manager);
  auto screenshare_audio = NewCryptor(
      "p", FrameCryptorTransformer::TrackType::kScreenshareAudio, manager);
  EXPECT_EQ(audio->track_type(), FrameCryptorTransformer::TrackType::kAudio);
  EXPECT_EQ(video->track_type(), FrameCryptorTransformer::TrackType::kVideo);
  EXPECT_EQ(screenshare->track_type(),
            FrameCryptorTransformer::TrackType::kScreenshare);
  EXPECT_EQ(screenshare_audio->track_type(),
            FrameCryptorTransformer::TrackType::kScreenshareAudio);
}

class RecordingManagerObserver : public DefaultEncryptionManager::Observer {
 public:
  void OnE2eeEvent(const DefaultEncryptionManager::E2eeEvent& event) override {
    MutexLock lock(&mutex_);
    events.push_back(event);
  }
  std::vector<DefaultEncryptionManager::E2eeEvent> Take() {
    MutexLock lock(&mutex_);
    std::vector<DefaultEncryptionManager::E2eeEvent> out;
    out.swap(events);
    return out;
  }

 private:
  Mutex mutex_;
  std::vector<DefaultEncryptionManager::E2eeEvent> events;
};

bool HasEvent(const std::vector<DefaultEncryptionManager::E2eeEvent>& events,
              DefaultEncryptionManager::E2eeEventType type) {
  for (const auto& ev : events) {
    if (ev.type == type) {
      return true;
    }
  }
  return false;
}

TEST(DefaultEncryptionManager, CipherLockRejectsWrongKeySize) {
  auto aes128 = make_ref_counted<DefaultEncryptionManager>(
      DefaultEncryptionManager::Cipher::kAes128Gcm);
  auto aes256 = make_ref_counted<DefaultEncryptionManager>(
      DefaultEncryptionManager::Cipher::kAes256Gcm);
  std::vector<uint8_t> k32(32, 0x42);
  EXPECT_TRUE(aes128->SetKey("p", 0, kJsKey));
  EXPECT_FALSE(aes128->SetKey("p", 1, k32));
  EXPECT_FALSE(aes256->SetKey("p", 0, kJsKey));
  EXPECT_TRUE(aes256->SetKey("p", 0, k32));
}

TEST(DefaultEncryptionManager, E2eeEventNameAndFingerprintHex) {
  using T = DefaultEncryptionManager::E2eeEventType;
  const struct {
    T type;
    const char* name;
  } kNames[] = {
      {T::kDecryptionFailed, "e2ee.decryption_failed"},
      {T::kDecryptionResumed, "e2ee.decryption_resumed"},
      {T::kDecryptionStalled, "e2ee.decryption_stalled"},
      {T::kEncryptionFailed, "e2ee.encryption_failed"},
      {T::kMissingKey, "e2ee.missing_key"},
      {T::kUnencryptedFrame, "e2ee.unencrypted_frame"},
      {T::kUnsupportedVersion, "e2ee.unsupported_version"},
      {T::kKeyState, "e2ee.key_state"},
      {T::kPerfReport, "e2ee.perf_report"},
  };
  for (const auto& row : kNames) {
    DefaultEncryptionManager::E2eeEvent ev;
    ev.type = row.type;
    EXPECT_STREQ(ev.Name(), row.name);
  }
  DefaultEncryptionManager::KeyFingerprint fp;
  fp.fingerprint = {0x00, 0x0f, 0xa0, 0xff, 0x10, 0x2b, 0x3c, 0x4d};
  EXPECT_EQ(fp.Hex(), "000fa0ff102b3c4d");
}

TEST(DefaultEncryptionManager, PerfReportAfterEncrypt) {
  auto manager = make_ref_counted<DefaultEncryptionManager>("local");
  auto observer = make_ref_counted<RecordingManagerObserver>();
  manager->SetObserver(observer);
  EXPECT_TRUE(manager->SetKeyWithIvPrefix("local", 0, kJsKey, kJsPrefix));
  EXPECT_TRUE(manager->EnablePerformanceReporting(true));
  auto pt = ParseHex("78aabbccdd");
  auto in = MakeAudioInput("local", pt);
  Buffer out;
  FrameCryptionState state = kNew;
  EXPECT_TRUE(manager->Encrypt(in, out, &state));
  manager->FlushPerfReportsForTest();
  auto events = observer->Take();
  const DefaultEncryptionManager::E2eeEvent* report = nullptr;
  for (const auto& ev : events) {
    if (ev.type == DefaultEncryptionManager::E2eeEventType::kPerfReport) {
      report = &ev;
    }
  }
  ASSERT_TRUE(report);
  EXPECT_STREQ(report->Name(), "e2ee.perf_report");
  ASSERT_EQ(report->encode_perf.size(), 1u);
  EXPECT_EQ(report->encode_perf[0].participant_id, "local");
  EXPECT_EQ(report->encode_perf[0].codec, "opus");
  EXPECT_GT(report->encode_perf[0].fps, 0.0);
  EXPECT_TRUE(manager->EnablePerformanceReporting(false));
}

TEST(DefaultEncryptionManager, HostEventsAndDispose) {
  auto manager = make_ref_counted<DefaultEncryptionManager>("local");
  auto observer = make_ref_counted<RecordingManagerObserver>();
  manager->SetObserver(observer);
  auto pt = ParseHex("78aabbccdd");
  auto in = MakeAudioInput("local", pt);
  Buffer out;
  FrameCryptionState state = kNew;
  EXPECT_FALSE(manager->Encrypt(in, out, &state));
  EXPECT_EQ(state, kMissingKey);
  auto missing = observer->Take();
  ASSERT_EQ(missing.size(), 1u);
  EXPECT_EQ(missing[0].type, DefaultEncryptionManager::E2eeEventType::kMissingKey);
  EXPECT_STREQ(missing[0].Name(), "e2ee.missing_key");
  EXPECT_EQ(missing[0].participant_id, "local");
  EXPECT_FALSE(missing[0].key_index);
  EXPECT_FALSE(missing[0].track_type);

  EXPECT_TRUE(manager->SetKeyWithIvPrefix("local", 0, kJsKey, kJsPrefix));
  manager->RequestKeyState();
  auto key_state = observer->Take();
  ASSERT_EQ(key_state.size(), 1u);
  EXPECT_EQ(key_state[0].type, DefaultEncryptionManager::E2eeEventType::kKeyState);
  EXPECT_STREQ(key_state[0].Name(), "e2ee.key_state");
  ASSERT_EQ(key_state[0].key_state.size(), 1u);
  EXPECT_EQ(key_state[0].key_state[0].participant_id, "local");
  EXPECT_EQ(key_state[0].key_state[0].Hex().size(), 16u);

  EXPECT_TRUE(manager->Encrypt(in, out, &state));
  std::vector<uint8_t> enc(out.begin(), out.end());
  auto bad = enc;
  ASSERT_GE(bad.size(), 5u);
  bad[bad.size() - 5] ^= 0xff;
  auto dec_in = MakeAudioInput("local", bad);
  Buffer dec;
  EXPECT_FALSE(manager->Decrypt(dec_in, dec, &state));
  EXPECT_EQ(state, kUnsupportedVersion);
  auto version = observer->Take();
  ASSERT_EQ(version.size(), 1u);
  EXPECT_EQ(version[0].type,
            DefaultEncryptionManager::E2eeEventType::kUnsupportedVersion);
  EXPECT_STREQ(version[0].Name(), "e2ee.unsupported_version");
  EXPECT_TRUE(version[0].version);
  EXPECT_NE(*version[0].version, 1);

  manager->Dispose();
  EXPECT_TRUE(manager->disposed());
  EXPECT_FALSE(manager->SetKey("local", 0, kJsKey));
  EXPECT_FALSE(manager->Encrypt(in, out, &state));
  EXPECT_EQ(state, kInternalError);
  EXPECT_EQ(manager->CreateEncryptor(Thread::Current(),
                                     FrameCryptorTransformer::TrackType::kAudio),
            nullptr);
}

TEST(DefaultEncryptionManager, CreateEncryptorIsEnabled) {
  AutoThread main;
  auto manager = make_ref_counted<DefaultEncryptionManager>("local");
  manager->SetKeyWithIvPrefix("local", 0, kJsKey, kJsPrefix);
  auto sender = manager->CreateEncryptor(
      Thread::Current(), FrameCryptorTransformer::TrackType::kAudio);
  ASSERT_TRUE(sender);
  EXPECT_TRUE(sender->enabled());
  EXPECT_EQ(sender->participant_id(), "local");
  auto receiver = manager->CreateDecryptor(
      Thread::Current(), "local", FrameCryptorTransformer::TrackType::kAudio);
  ASSERT_TRUE(receiver);
  EXPECT_TRUE(receiver->enabled());
  auto sink = make_ref_counted<RecordingSink>();
  static_cast<FrameTransformerInterface*>(sender.get())
      ->RegisterTransformedFrameCallback(sink);
  auto frame = std::make_unique<FakeAudioFrame>();
  frame->payload = ParseHex("78aabbccdd");
  frame->direction = TransformableFrameInterface::Direction::kSender;
  PushFrame(sender, std::move(frame));
  manager->WaitUntilIdleForTest();
  EXPECT_EQ(sink->count(), 1);
}

TEST(DefaultEncryptionManager, DecodeMissingKeyAndStallCarryKeyIndex) {
  auto manager = make_ref_counted<DefaultEncryptionManager>();
  auto observer = make_ref_counted<RecordingManagerObserver>();
  manager->SetObserver(observer);
  EXPECT_TRUE(manager->SetKeyWithIvPrefix("p", 0, kJsKey, kJsPrefix));
  auto pt = ParseHex("78aabbccdd");
  auto in = MakeAudioInput("p", pt);
  Buffer enc;
  FrameCryptionState state = kNew;
  EXPECT_TRUE(manager->Encrypt(in, enc, &state));
  manager->RemoveKey("p", 0);
  auto dec_in = MakeAudioInput("p", enc);
  Buffer dec;
  EXPECT_FALSE(manager->Decrypt(dec_in, dec, &state));
  EXPECT_EQ(state, kMissingKey);
  auto missing = observer->Take();
  ASSERT_EQ(missing.size(), 1u);
  EXPECT_EQ(missing[0].type, DefaultEncryptionManager::E2eeEventType::kMissingKey);
  ASSERT_TRUE(missing[0].key_index);
  EXPECT_EQ(*missing[0].key_index, 0);
  ASSERT_TRUE(missing[0].track_type);
  EXPECT_EQ(*missing[0].track_type, FrameCryptorTransformer::TrackType::kAudio);

  std::vector<uint8_t> other(16, 0x09);
  EXPECT_TRUE(manager->SetKey("p", 0, other));
  for (int i = 0; i < 11; ++i) {
    manager->Decrypt(dec_in, dec, &state);
  }
  auto fails = observer->Take();
  bool saw_failed = false;
  bool saw_stalled = false;
  for (const auto& ev : fails) {
    if (ev.type == DefaultEncryptionManager::E2eeEventType::kDecryptionFailed) {
      saw_failed = true;
    }
    if (ev.type == DefaultEncryptionManager::E2eeEventType::kDecryptionStalled) {
      saw_stalled = true;
      ASSERT_TRUE(ev.key_index);
      EXPECT_EQ(*ev.key_index, 0);
    }
  }
  EXPECT_TRUE(saw_failed);
  EXPECT_TRUE(saw_stalled);
}

TEST(DefaultEncryptionManager, DecodeOversizeClearBytesForwardsAsUnencrypted) {
  // JS: readTrailer null + readFramingVersion === 1 → unencrypted(), enqueue.
  // A v1 magic tail with an impossible clearBytes is "not a framed frame",
  // not "corrupt ciphertext we should drop".
  auto manager = make_ref_counted<DefaultEncryptionManager>();
  auto observer = make_ref_counted<RecordingManagerObserver>();
  manager->SetObserver(observer);
  EXPECT_TRUE(manager->SetKeyWithIvPrefix("p", 0, kJsKey, kJsPrefix));
  auto payload = DummyFramedPayload(5, 6);
  auto in = MakeAudioInput("p", payload);
  Buffer out;
  FrameCryptionState state = kNew;
  EXPECT_TRUE(manager->Decrypt(in, out, &state));
  EXPECT_EQ(state, kUnencrypted);
  EXPECT_EQ(std::vector<uint8_t>(out.begin(), out.end()), payload);
  auto events = observer->Take();
  EXPECT_TRUE(
      HasEvent(events, DefaultEncryptionManager::E2eeEventType::kUnencryptedFrame));
  EXPECT_FALSE(HasEvent(
      events, DefaultEncryptionManager::E2eeEventType::kUnsupportedVersion));
}

TEST(DefaultEncryptionManager, DecodeFutureVersionDropsNotAsUnencrypted) {
  // JS: version !== 1 → unsupportedVersion, do not enqueue. Forwarding would
  // hand ciphertext to the decoder and look like a downgrade.
  auto manager = make_ref_counted<DefaultEncryptionManager>();
  auto observer = make_ref_counted<RecordingManagerObserver>();
  manager->SetObserver(observer);
  EXPECT_TRUE(manager->SetKeyWithIvPrefix("p", 0, kJsKey, kJsPrefix));
  auto payload = DummyFramedPayload(5, 0, 2);
  auto in = MakeAudioInput("p", payload);
  Buffer out;
  FrameCryptionState state = kNew;
  EXPECT_FALSE(manager->Decrypt(in, out, &state));
  EXPECT_EQ(state, kUnsupportedVersion);
  auto events = observer->Take();
  ASSERT_EQ(events.size(), 1u);
  EXPECT_EQ(events[0].type,
            DefaultEncryptionManager::E2eeEventType::kUnsupportedVersion);
  ASSERT_TRUE(events[0].version);
  EXPECT_EQ(*events[0].version, 2);
  EXPECT_FALSE(HasEvent(
      events, DefaultEncryptionManager::E2eeEventType::kUnencryptedFrame));
}

TEST(DefaultEncryptionManager,
     DecodeFutureVersionWithOversizeClearBytesStillDrops) {
  // Identification suffix is independent of clearBytes. A newer layout that
  // also overruns still reports unsupported-version, not unencrypted.
  auto manager = make_ref_counted<DefaultEncryptionManager>();
  auto observer = make_ref_counted<RecordingManagerObserver>();
  manager->SetObserver(observer);
  auto payload = DummyFramedPayload(5, 6, 2);
  auto in = MakeAudioInput("p", payload);
  Buffer out;
  FrameCryptionState state = kNew;
  EXPECT_FALSE(manager->Decrypt(in, out, &state));
  EXPECT_EQ(state, kUnsupportedVersion);
  auto events = observer->Take();
  EXPECT_TRUE(HasEvent(
      events, DefaultEncryptionManager::E2eeEventType::kUnsupportedVersion));
  EXPECT_FALSE(HasEvent(
      events, DefaultEncryptionManager::E2eeEventType::kUnencryptedFrame));
}

TEST(DefaultEncryptionManager, DecodeBadMagicForwardsAsUnencrypted) {
  auto manager = make_ref_counted<DefaultEncryptionManager>();
  auto observer = make_ref_counted<RecordingManagerObserver>();
  manager->SetObserver(observer);
  auto payload = DummyFramedPayload(5, 0);
  payload.back() ^= 0x01;
  auto in = MakeAudioInput("p", payload);
  Buffer out;
  FrameCryptionState state = kNew;
  EXPECT_TRUE(manager->Decrypt(in, out, &state));
  EXPECT_EQ(state, kUnencrypted);
  EXPECT_EQ(std::vector<uint8_t>(out.begin(), out.end()), payload);
  auto events = observer->Take();
  EXPECT_TRUE(
      HasEvent(events, DefaultEncryptionManager::E2eeEventType::kUnencryptedFrame));
  EXPECT_FALSE(HasEvent(
      events, DefaultEncryptionManager::E2eeEventType::kUnsupportedVersion));
}

TEST(DefaultEncryptionManager, DecodeTooShortForwardsAsUnencrypted) {
  auto manager = make_ref_counted<DefaultEncryptionManager>();
  auto observer = make_ref_counted<RecordingManagerObserver>();
  manager->SetObserver(observer);
  std::vector<uint8_t> payload(kFrameTrailerLen - 1, 0x42);
  auto in = MakeAudioInput("p", payload);
  Buffer out;
  FrameCryptionState state = kNew;
  EXPECT_TRUE(manager->Decrypt(in, out, &state));
  EXPECT_EQ(state, kUnencrypted);
  EXPECT_EQ(std::vector<uint8_t>(out.begin(), out.end()), payload);
  EXPECT_TRUE(HasEvent(
      observer->Take(),
      DefaultEncryptionManager::E2eeEventType::kUnencryptedFrame));
}

TEST(DefaultEncryptionManager, DecodeRbspUnescapeShorterThanTrailerThenRecovers) {
  // JS transform-pipeline: a forged RBSP frame whose unescape is shorter
  // than the trailer must not throw / stall the track. A genuine H.264
  // frame after it still decrypts.
  auto manager = make_ref_counted<DefaultEncryptionManager>();
  auto observer = make_ref_counted<RecordingManagerObserver>();
  manager->SetObserver(observer);
  EXPECT_TRUE(manager->SetKeyWithIvPrefix("p", 0, kJsKey, kJsPrefix));

  std::vector<uint8_t> forged(40, 0);
  const uint16_t clear_bytes = 20;
  for (int i = 0; i < 3; ++i) {
    const size_t o = static_cast<size_t>(clear_bytes) + static_cast<size_t>(i) * 4;
    forged[o] = 0x00;
    forged[o + 1] = 0x00;
    forged[o + 2] = 0x03;
    forged[o + 3] = 0x00;
  }
  const uint16_t raw = kFrameTrailerRbspFlag | clear_bytes;
  forged[forged.size() - 7] = static_cast<uint8_t>(raw >> 8);
  forged[forged.size() - 6] = static_cast<uint8_t>(raw);
  forged[forged.size() - 5] = kFrameTrailerVersion;
  forged[forged.size() - 4] = 0xe2;
  forged[forged.size() - 3] = 0xee;
  forged[forged.size() - 2] = 0xfe;
  forged[forged.size() - 1] = 0xed;

  auto h264 = ParseHex("00000001 65 8884deadbe");
  auto genuine_in = MakeVideoInput("p", h264, kVideoCodecH264, true);
  Buffer enc;
  FrameCryptionState state = kNew;
  EXPECT_TRUE(manager->Encrypt(genuine_in, enc, &state));

  Buffer out;
  auto forged_in = MakeVideoInput("p", forged, kVideoCodecH264, true);
  EXPECT_FALSE(manager->Decrypt(forged_in, out, &state));
  EXPECT_EQ(state, kNew);
  EXPECT_FALSE(HasEvent(
      observer->Take(), DefaultEncryptionManager::E2eeEventType::kUnencryptedFrame));

  genuine_in.data = enc;
  EXPECT_TRUE(manager->Decrypt(genuine_in, out, &state));
  EXPECT_EQ(std::vector<uint8_t>(out.begin(), out.end()), h264);
}

TEST(DefaultEncryptionManager, DecodeFailedMaxCounterDoesNotPoisonReplay) {
  // JS: peek-then-commit. A forged UINT32_MAX counter that fails GCM must
  // not advance the replay window and drop later genuine frames.
  auto manager = make_ref_counted<DefaultEncryptionManager>();
  EXPECT_TRUE(manager->SetKeyWithIvPrefix("p", 0, kJsKey, kJsPrefix));
  auto pt1 = ParseHex("78aabbccdd");
  auto pt2 = ParseHex("78eeff0011");
  auto in = MakeAudioInput("p", pt1);
  Buffer g1;
  Buffer g2;
  FrameCryptionState state = kNew;
  EXPECT_TRUE(manager->Encrypt(in, g1, &state));
  in.data = pt2;
  EXPECT_TRUE(manager->Encrypt(in, g2, &state));

  std::vector<uint8_t> forged(g1.begin(), g1.end());
  ASSERT_GE(forged.size(), kFrameTrailerLen + 2);
  forged[forged.size() - kFrameTrailerLen] = 0xff;
  forged[forged.size() - kFrameTrailerLen + 1] = 0xff;
  forged[forged.size() - kFrameTrailerLen + 2] = 0xff;
  forged[forged.size() - kFrameTrailerLen + 3] = 0xff;
  forged[1] ^= 0xff;

  Buffer out;
  auto forged_in = MakeAudioInput("p", forged);
  EXPECT_FALSE(manager->Decrypt(forged_in, out, &state));

  in.data = g1;
  EXPECT_TRUE(manager->Decrypt(in, out, &state));
  EXPECT_EQ(std::vector<uint8_t>(out.begin(), out.end()), pt1);
  in.data = g2;
  EXPECT_TRUE(manager->Decrypt(in, out, &state));
  EXPECT_EQ(std::vector<uint8_t>(out.begin(), out.end()), pt2);
}

}  // namespace webrtc

