/*
 * Copyright 2022 LiveKit
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include "api/crypto/frame_crypto_transformer.h"
#include "api/crypto/default_encryption_manager.h"
#include "api/crypto/frame_encryption_manager.h"

#include <openssl/aes.h>
#include <openssl/err.h>
#include <openssl/evp.h>
#include <openssl/pem.h>
#include <openssl/rand.h>

#include <cstring>
#include <iomanip>
#include <iostream>
#include <memory>
#include <optional>
#include <sstream>
#include <string>
#include <utility>

#include "absl/container/inlined_vector.h"
#include "absl/types/optional.h"
#include "absl/types/variant.h"
#include "api/array_view.h"
#include "api/units/timestamp.h"
#include "api/video/video_frame_metadata.h"
#include "common_video/h264/h264_common.h"
#include "common_video/h265/h265_common.h"
#include "modules/rtp_rtcp/source/rtp_format_h264.h"
#include "rtc_base/byte_buffer.h"
#include "rtc_base/crypto_random.h"
#include "rtc_base/event.h"
#include "rtc_base/logging.h"
#include "rtc_base/platform_thread.h"
#include "rtc_base/time_utils.h"

enum class EncryptOrDecrypt { kEncrypt = 0, kDecrypt };

#define Success 0
#define ErrorUnexpected -1
#define OperationError -2
#define ErrorDataTooSmall -3
#define ErrorInvalidAesGcmTagLength -4

webrtc::VideoCodecType get_video_codec_type(
    webrtc::TransformableFrameInterface* frame) {
  auto videoFrame =
      static_cast<webrtc::TransformableVideoFrameInterface*>(frame);
  return videoFrame->Metadata().GetCodec();
}

webrtc::H264PacketizationMode get_h264_packetization_mode(
    webrtc::TransformableFrameInterface* frame) {
  auto video_frame =
      static_cast<webrtc::TransformableVideoFrameInterface*>(frame);
  const auto& h264_header = absl::get<webrtc::RTPVideoHeaderH264>(
      video_frame->Metadata().GetRTPVideoHeaderCodecSpecifics());
  return h264_header.packetization_mode;
}

const EVP_AEAD* GetAesGcmAlgorithmFromKeySize(size_t key_size_bytes) {
  switch (key_size_bytes) {
    case 16:
      return EVP_aead_aes_128_gcm();
    case 32:
      return EVP_aead_aes_256_gcm();
    default:
      return nullptr;
  }
}

const EVP_CIPHER* GetAesCbcAlgorithmFromKeySize(size_t key_size_bytes) {
  switch (key_size_bytes) {
    case 16:
      return EVP_aes_128_cbc();
    case 32:
      return EVP_aes_256_cbc();
    default:
      return nullptr;
  }
}

inline bool FrameIsH264(webrtc::TransformableFrameInterface* frame,
                        webrtc::FrameCryptorTransformer::MediaType type) {
  switch (type) {
    case webrtc::FrameCryptorTransformer::MediaType::kVideoFrame: {
      auto videoFrame =
          static_cast<webrtc::TransformableVideoFrameInterface*>(frame);
      return videoFrame->Metadata().GetCodec() ==
             webrtc::VideoCodecType::kVideoCodecH264;
    }
    default:
      return false;
  }
}

inline bool FrameIsH265(webrtc::TransformableFrameInterface* frame,
                        webrtc::FrameCryptorTransformer::MediaType type) {
  switch (type) {
    case webrtc::FrameCryptorTransformer::MediaType::kVideoFrame: {
      auto videoFrame =
          static_cast<webrtc::TransformableVideoFrameInterface*>(frame);
      return videoFrame->Metadata().GetCodec() ==
             webrtc::VideoCodecType::kVideoCodecH265;
    }
    default:
      return false;
  }
}

inline bool IsH265SliceNalu(webrtc::H265::NaluType nalu_type) {
  // VCL NALUs (Video Coding Layer) - slice segments
  return nalu_type == webrtc::H265::NaluType::kTrailN ||
         nalu_type == webrtc::H265::NaluType::kTrailR ||
         nalu_type == webrtc::H265::NaluType::kTsaN ||
         nalu_type == webrtc::H265::NaluType::kTsaR ||
         nalu_type == webrtc::H265::NaluType::kStsaN ||
         nalu_type == webrtc::H265::NaluType::kStsaR ||
         nalu_type == webrtc::H265::NaluType::kRadlN ||
         nalu_type == webrtc::H265::NaluType::kRadlR ||
         nalu_type == webrtc::H265::NaluType::kRaslN ||
         nalu_type == webrtc::H265::NaluType::kRaslR ||
         nalu_type == webrtc::H265::NaluType::kBlaWLp ||
         nalu_type == webrtc::H265::NaluType::kBlaWRadl ||
         nalu_type == webrtc::H265::NaluType::kBlaNLp ||
         nalu_type == webrtc::H265::NaluType::kIdrWRadl ||
         nalu_type == webrtc::H265::NaluType::kIdrNLp ||
         nalu_type == webrtc::H265::NaluType::kCra;
}

inline bool NeedsRbspUnescaping(const uint8_t* frameData, size_t frameSize) {
  for (size_t i = 0; i < frameSize - 3; ++i) {
    if (frameData[i] == 0 && frameData[i + 1] == 0 && frameData[i + 2] == 3)
      return true;
  }
  return false;
}

std::string to_uint8_list(const uint8_t* data, int len) {
  std::stringstream ss;
  ss << "[";
  for (int i = 0; i < len; i++) {
    ss << static_cast<unsigned>(data[i]) << ",";
  }
  ss << "]";
  return ss.str();
}

std::string to_hex(const uint8_t* data, int len) {
  std::stringstream ss;
  ss << std::uppercase << std::hex << std::setfill('0');
  for (int i = 0; i < len; i++) {
    ss << std::setw(2) << static_cast<unsigned>(data[i]);
  }
  return ss.str();
}

uint8_t get_unencrypted_bytes(webrtc::TransformableFrameInterface* frame,
                              webrtc::FrameCryptorTransformer::MediaType type) {
  uint8_t unencrypted_bytes = 0;
  switch (type) {
    case webrtc::FrameCryptorTransformer::MediaType::kAudioFrame:
      unencrypted_bytes = 1;
      break;
    case webrtc::FrameCryptorTransformer::MediaType::kVideoFrame: {
      auto videoFrame =
          static_cast<webrtc::TransformableVideoFrameInterface*>(frame);
      auto codec = videoFrame->Metadata().GetCodec();
      if (codec == webrtc::VideoCodecType::kVideoCodecAV1) {
        unencrypted_bytes = 0;
      } else if (codec == webrtc::VideoCodecType::kVideoCodecVP8) {
        unencrypted_bytes = videoFrame->IsKeyFrame() ? 10 : 3;
      } else if (codec == webrtc::VideoCodecType::kVideoCodecH264) {
        webrtc::ArrayView<const uint8_t> data_in = frame->GetData();
        std::vector<webrtc::H264::NaluIndex> nalu_indices =
            webrtc::H264::FindNaluIndices(data_in);

        int idx = 0;
        for (const auto& index : nalu_indices) {
          const uint8_t* slice = data_in.data() + index.payload_start_offset;
          webrtc::H264::NaluType nalu_type =
              webrtc::H264::ParseNaluType(slice[0]);
          switch (nalu_type) {
            case webrtc::H264::NaluType::kIdr:
            case webrtc::H264::NaluType::kSlice:
              unencrypted_bytes = index.payload_start_offset + 2;
              RTC_LOG(LS_INFO)
                  << "NonParameterSetNalu::payload_size: " << index.payload_size
                  << ", nalu_type " << nalu_type << ", NaluIndex [" << idx++
                  << "] offset: " << index.payload_start_offset;
              return unencrypted_bytes;
            default:
              break;
          }
        }
      } else if (codec == webrtc::VideoCodecType::kVideoCodecH265) {
        webrtc::ArrayView<const uint8_t> data_in = frame->GetData();
        std::vector<webrtc::H265::NaluIndex> nalu_indices =
            webrtc::H265::FindNaluIndices(data_in);

        int idx = 0;
        for (const auto& index : nalu_indices) {
          const uint8_t* slice = data_in.data() + index.payload_start_offset;
          webrtc::H265::NaluType nalu_type =
              webrtc::H265::ParseNaluType(slice[0]);
          if (IsH265SliceNalu(nalu_type)) {
            // H.265 has a 2-byte NALU header, so unencrypted bytes = offset +
            // header size
            unencrypted_bytes =
                index.payload_start_offset + webrtc::H265::kNaluHeaderSize;
            RTC_LOG(LS_INFO)
                << "H265 NonParameterSetNalu::payload_size: "
                << index.payload_size << ", nalu_type "
                << static_cast<int>(nalu_type) << ", NaluIndex [" << idx++
                << "] offset: " << index.payload_start_offset
                << ", unencrypted_bytes: " << unencrypted_bytes;
            return unencrypted_bytes;
          }
        }
      }
      break;
    }
    default:
      break;
  }
  return unencrypted_bytes;
}

// Unencrypted-byte helpers for the LiveKit path. Trailer clear-byte rules
// live in frame_crypto_codec.cc.

int DerivePBKDF2KeyFromRawKey(const std::vector<uint8_t> raw_key,
                              const std::vector<uint8_t>& salt,
                              unsigned int optional_length_bits,
                              std::vector<uint8_t>* derived_key) {
  size_t key_size_bytes = optional_length_bits / 8;
  derived_key->resize(key_size_bytes);

  if (PKCS5_PBKDF2_HMAC((const char*)raw_key.data(), raw_key.size(),
                        salt.data(), salt.size(), 100000, EVP_sha256(),
                        key_size_bytes, derived_key->data()) != 1) {
    RTC_LOG(LS_ERROR) << "Failed to derive AES key from password.";
    return ErrorUnexpected;
  }

  return Success;
}

int AesGcmEncryptDecrypt(EncryptOrDecrypt mode,
                         const std::vector<uint8_t> raw_key,
                         const webrtc::ArrayView<uint8_t> data,
                         unsigned int tag_length_bytes,
                         webrtc::ArrayView<uint8_t> iv,
                         webrtc::ArrayView<uint8_t> additional_data,
                         const EVP_AEAD* aead_alg,
                         std::vector<uint8_t>* buffer) {
  bssl::ScopedEVP_AEAD_CTX ctx;

  if (!aead_alg) {
    RTC_LOG(LS_ERROR) << "Invalid AES-GCM key size.";
    return ErrorUnexpected;
  }

  if (!EVP_AEAD_CTX_init(ctx.get(), aead_alg, raw_key.data(), raw_key.size(),
                         tag_length_bytes, nullptr)) {
    RTC_LOG(LS_ERROR) << "Failed to initialize AES-GCM context.";
    return OperationError;
  }

  size_t len;
  int ok;

  if (mode == EncryptOrDecrypt::kDecrypt) {
    if (data.size() < tag_length_bytes) {
      RTC_LOG(LS_ERROR) << "Data too small for AES-GCM tag.";
      return ErrorDataTooSmall;
    }

    buffer->resize(data.size() - tag_length_bytes);

    ok = EVP_AEAD_CTX_open(ctx.get(), buffer->data(), &len, buffer->size(),
                           iv.data(), iv.size(), data.data(), data.size(),
                           additional_data.data(), additional_data.size());
  } else {
    buffer->resize(data.size() + EVP_AEAD_max_overhead(aead_alg));

    ok = EVP_AEAD_CTX_seal(ctx.get(), buffer->data(), &len, buffer->size(),
                           iv.data(), iv.size(), data.data(), data.size(),
                           additional_data.data(), additional_data.size());
  }

  if (!ok) {
    RTC_LOG(LS_WARNING) << "Failed to perform AES-GCM operation.";
    return OperationError;
  }

  buffer->resize(len);

  return Success;
}

int AesEncryptDecrypt(EncryptOrDecrypt mode,
                      webrtc::FrameCryptorTransformer::Algorithm algorithm,
                      const std::vector<uint8_t>& raw_key,
                      webrtc::ArrayView<uint8_t> iv,
                      webrtc::ArrayView<uint8_t> additional_data,
                      const webrtc::ArrayView<uint8_t> data,
                      std::vector<uint8_t>* buffer) {
  switch (algorithm) {
    case webrtc::FrameCryptorTransformer::Algorithm::kAesGcm:
    case webrtc::FrameCryptorTransformer::Algorithm::kAesGcmTrailer: {
      unsigned int tag_length_bits = 128;
      const EVP_AEAD* cipher = GetAesGcmAlgorithmFromKeySize(raw_key.size());
      if (!cipher) {
        RTC_LOG(LS_ERROR) << "Invalid AES-GCM key size.";
        return ErrorUnexpected;
      }
      return AesGcmEncryptDecrypt(mode, raw_key, data, tag_length_bits / 8, iv,
                                  additional_data, cipher, buffer);
    }
    default:
      RTC_LOG(LS_ERROR) << "Unsupported algorithm.";
      return ErrorUnexpected;
  }
}
namespace webrtc {

namespace {
FrameCryptorTransformer::MediaType MediaTypeFromTrackType(
    FrameCryptorTransformer::TrackType track_type) {
  switch (track_type) {
    case FrameCryptorTransformer::TrackType::kAudio:
    case FrameCryptorTransformer::TrackType::kScreenshareAudio:
      return FrameCryptorTransformer::MediaType::kAudioFrame;
    case FrameCryptorTransformer::TrackType::kVideo:
    case FrameCryptorTransformer::TrackType::kScreenshare:
      return FrameCryptorTransformer::MediaType::kVideoFrame;
  }
  return FrameCryptorTransformer::MediaType::kAudioFrame;
}

FrameCryptorTransformer::TrackType TrackTypeFromMediaType(
    FrameCryptorTransformer::MediaType type) {
  return type == FrameCryptorTransformer::MediaType::kAudioFrame
             ? FrameCryptorTransformer::TrackType::kAudio
             : FrameCryptorTransformer::TrackType::kVideo;
}

void StopOwnedThread(std::unique_ptr<Thread> thread) {
  if (!thread) {
    return;
  }
  if (!thread->IsCurrent()) {
    thread->Stop();
    return;
  }
  thread->Quit();
  PlatformThread::SpawnDetached(
      [thread = std::move(thread)]() mutable { thread->Stop(); },
      "JoinCryptoThrd");
}
}  // namespace

FrameCryptorTransformer::FrameCryptorTransformer(
    webrtc::Thread* signaling_thread,
    const std::string participant_id,
    MediaType type,
    Algorithm algorithm,
    webrtc::scoped_refptr<KeyProvider> key_provider)
    : FrameCryptorTransformer(
          signaling_thread,
          participant_id,
          TrackTypeFromMediaType(type),
          webrtc::make_ref_counted<DefaultEncryptionManager>(algorithm,
                                                             key_provider)) {
  algorithm_ = algorithm;
  key_provider_ = key_provider;
}

FrameCryptorTransformer::FrameCryptorTransformer(
    webrtc::Thread* signaling_thread,
    const std::string participant_id,
    MediaType type,
    webrtc::scoped_refptr<EncryptionManager> manager)
    : FrameCryptorTransformer(signaling_thread,
                              participant_id,
                              TrackTypeFromMediaType(type),
                              std::move(manager)) {}

FrameCryptorTransformer::FrameCryptorTransformer(
    webrtc::Thread* signaling_thread,
    const std::string participant_id,
    TrackType track_type,
    webrtc::scoped_refptr<EncryptionManager> manager)
    : signaling_thread_(signaling_thread),
      participant_id_(participant_id),
      type_(MediaTypeFromTrackType(track_type)),
      track_type_(track_type),
      encryption_manager_(std::move(manager)) {
  RTC_DCHECK(encryption_manager_ != nullptr);
  // Trailer managers share one worker. LiveKit KeyProvider has none, so we
  // start a per-transformer thread as the old FrameCryptor did.
  if (!encryption_manager_->crypto_task_queue()) {
    thread_ = webrtc::Thread::Create();
    thread_->SetName("FrameCryptorTransformer", this);
    thread_->Start();
  }
}

FrameCryptorTransformer::~FrameCryptorTransformer() {
  if (thread_) {
    StopOwnedThread(std::move(thread_));
    return;
  }
  if (!encryption_manager_) {
    return;
  }
  TaskQueueBase* q = encryption_manager_->crypto_task_queue();
  if (q && !q->IsCurrent()) {
    Event done;
    q->PostTask([&done] { done.Set(); });
    done.Wait(Event::kForever);
  }
}

void FrameCryptorTransformer::SetEncodeCodec(std::string codec) {
  webrtc::MutexLock lock(&mutex_);
  // Empty clears the pin: later frames use RTP codec metadata instead.
  if (codec.empty()) {
    encode_codec_.reset();
  } else {
    encode_codec_ = std::move(codec);
  }
}

void FrameCryptorTransformer::Transform(
    std::unique_ptr<webrtc::TransformableFrameInterface> frame) {
  webrtc::MutexLock lock(&sink_mutex_);
  if (sink_callback_ == nullptr && sink_callbacks_.size() == 0) {
    RTC_LOG(LS_WARNING)
        << "FrameCryptorTransformer::Transform sink_callback_ is NULL";
    return;
  }

  TaskQueueBase* queue = nullptr;
  {
    webrtc::MutexLock manager_lock(&mutex_);
    if (encryption_manager_) {
      queue = encryption_manager_->crypto_task_queue();
    }
  }
  // Prefer the manager worker so every track on this manager serializes.
  // LiveKit falls back to the per-transformer thread created in the ctor.
  if (!queue) {
    queue = thread_.get();
  }
  RTC_DCHECK(queue != nullptr);

  scoped_refptr<FrameCryptorTransformer> self(this);
  switch (frame->GetDirection()) {
    case webrtc::TransformableFrameInterface::Direction::kSender:
      queue->PostTask([frame = std::move(frame), self]() mutable {
        self->encryptFrame(std::move(frame));
      });
      break;
    case webrtc::TransformableFrameInterface::Direction::kReceiver:
      queue->PostTask([frame = std::move(frame), self]() mutable {
        self->decryptFrame(std::move(frame));
      });
      break;
    case webrtc::TransformableFrameInterface::Direction::kUnknown:
      // do nothing
      RTC_LOG(LS_INFO) << "FrameCryptorTransformer::Transform() kUnknown";
      break;
  }
}

namespace {
FrameCryptoInput MakeCryptoInput(
    TransformableFrameInterface* frame,
    FrameCryptorTransformer::MediaType type,
    FrameCryptorTransformer::TrackType track_type,
    int key_index,
    const std::string& participant_id,
    const std::optional<std::string>& encode_codec) {
  FrameCryptoInput in;
  in.data = frame->GetData();
  in.media_type = type;
  in.track_type = track_type;
  in.ssrc = frame->GetSsrc();
  in.rtp_timestamp = frame->GetTimestamp();
  in.key_index = key_index;
  in.participant_id = participant_id;
  // Encode may pin a lowercase codec name. Decode always passes nullopt:
  // the trailer already says how many clear bytes to leave.
  in.codec_name = encode_codec;
  if (type == FrameCryptorTransformer::MediaType::kVideoFrame) {
    auto* video = static_cast<TransformableVideoFrameInterface*>(frame);
    in.video_codec = video->Metadata().GetCodec();
    in.is_keyframe = video->IsKeyFrame();
  }
  return in;
}
}  // namespace

webrtc::scoped_refptr<webrtc::TransformedFrameCallback>
FrameCryptorTransformer::SinkFor(
    webrtc::TransformableFrameInterface* frame) {
  if (type_ == MediaType::kAudioFrame && sink_callback_) {
    return sink_callback_;
  }
  auto it = sink_callbacks_.find(frame->GetSsrc());
  if (it != sink_callbacks_.end()) {
    return it->second;
  }
  return nullptr;
}

void FrameCryptorTransformer::encryptFrame(
    std::unique_ptr<webrtc::TransformableFrameInterface> frame) {
  bool enabled_cryption = false;
  int key_index = 0;
  FrameCryptorTransformer::TrackType track_type =
      FrameCryptorTransformer::TrackType::kAudio;
  webrtc::scoped_refptr<EncryptionManager> manager;
  webrtc::scoped_refptr<webrtc::TransformedFrameCallback> sink_callback;
  std::optional<std::string> encode_codec;
  {
    webrtc::MutexLock lock(&mutex_);
    enabled_cryption = enabled_cryption_;
    key_index = key_index_;
    track_type = track_type_;
    manager = encryption_manager_;
    sink_callback = SinkFor(frame.get());
    encode_codec = encode_codec_;
  }
  if (sink_callback == nullptr) {
    if (last_enc_error_ != FrameCryptionState::kInternalError) {
      last_enc_error_ = FrameCryptionState::kInternalError;
      onFrameCryptionStateChanged(last_enc_error_);
    }
    return;
  }
  if (!enabled_cryption) {
    if (key_provider_ &&
        key_provider_->options().discard_frame_when_cryptor_not_ready) {
      return;
    }
    sink_callback->OnTransformedFrame(std::move(frame));
    return;
  }
  if (!manager) {
    return;
  }
  FrameCryptoInput input = MakeCryptoInput(frame.get(), type_, track_type,
                                           key_index, participant_id_,
                                           encode_codec);
  Buffer out;
  FrameCryptionState state = kNew;
  if (!manager->Encrypt(input, out, &state)) {
    if (state != kNew) {
      last_enc_error_ = state;
      onFrameCryptionStateChanged(last_enc_error_);
    }
    return;
  }
  frame->SetData(out);
  if (state != kOk && state != kNew) {
    last_enc_error_ = state;
    onFrameCryptionStateChanged(last_enc_error_);
  } else {
    last_enc_error_ = state;
  }
  sink_callback->OnTransformedFrame(std::move(frame));
}

void FrameCryptorTransformer::decryptFrame(
    std::unique_ptr<webrtc::TransformableFrameInterface> frame) {
  bool enabled_cryption = false;
  int key_index = 0;
  FrameCryptorTransformer::TrackType track_type =
      FrameCryptorTransformer::TrackType::kAudio;
  webrtc::scoped_refptr<EncryptionManager> manager;
  webrtc::scoped_refptr<webrtc::TransformedFrameCallback> sink_callback;
  {
    webrtc::MutexLock lock(&mutex_);
    enabled_cryption = enabled_cryption_;
    key_index = key_index_;
    track_type = track_type_;
    manager = encryption_manager_;
    sink_callback = SinkFor(frame.get());
  }
  if (sink_callback == nullptr) {
    if (last_dec_error_ != FrameCryptionState::kInternalError) {
      last_dec_error_ = FrameCryptionState::kInternalError;
      onFrameCryptionStateChanged(last_dec_error_);
    }
    return;
  }
  if (!enabled_cryption) {
    if (key_provider_ &&
        key_provider_->options().discard_frame_when_cryptor_not_ready) {
      return;
    }
    sink_callback->OnTransformedFrame(std::move(frame));
    return;
  }
  if (!manager) {
    return;
  }
  // Decode never pins a codec: clear-byte count comes from the trailer.
  FrameCryptoInput input = MakeCryptoInput(frame.get(), type_, track_type,
                                           key_index, participant_id_,
                                           std::nullopt);
  Buffer out;
  FrameCryptionState state = kNew;
  if (!manager->Decrypt(input, out, &state)) {
    if (state != kNew) {
      last_dec_error_ = state;
      onFrameCryptionStateChanged(last_dec_error_);
    }
    return;
  }
  frame->SetData(out);
  if (state != kOk && state != kNew) {
    last_dec_error_ = state;
    onFrameCryptionStateChanged(last_dec_error_);
  } else {
    last_dec_error_ = state;
  }
  sink_callback->OnTransformedFrame(std::move(frame));
}

void FrameCryptorTransformer::onFrameCryptionStateChanged(
    FrameCryptionState state) {
  webrtc::MutexLock lock(&mutex_);
  if (observer_) {
    RTC_DCHECK(signaling_thread_ != nullptr);
    signaling_thread_->PostTask([observer = observer_, state = state,
                                 participant_id = participant_id_]() mutable {
      observer->OnFrameCryptionStateChanged(participant_id, state);
    });
  }
}

Buffer FrameCryptorTransformer::makeIv(uint32_t ssrc, uint32_t timestamp) {
  uint32_t send_count = 0;
  if (send_counts_.find(ssrc) == send_counts_.end()) {
    send_counts_[ssrc] = floor(CreateRandomNonZeroId() * 0xFFFF);
  } else {
    send_count = send_counts_[ssrc];
  }
  ByteBufferWriter buf;
  buf.WriteUInt32(ssrc);
  buf.WriteUInt32(timestamp);
  buf.WriteUInt32(timestamp - (send_count % 0xFFFF));
  send_counts_[ssrc] = send_count + 1;

  RTC_CHECK_EQ(buf.Length(), getIvSize());

  return Buffer(buf.Data(), buf.Length());
}

uint8_t FrameCryptorTransformer::getIvSize() {
  switch (algorithm_) {
    case Algorithm::kAesGcm:
    case Algorithm::kAesGcmTrailer:
      return 12;
    default:
      return 0;
  }
}

DataPacketCryptor::DataPacketCryptor(
    FrameCryptorTransformer::Algorithm algorithm,
    webrtc::scoped_refptr<KeyProvider> key_provider)
    : algorithm_(algorithm), key_provider_(key_provider) {
  RTC_DCHECK(key_provider_ != nullptr);
}

DataPacketCryptor::~DataPacketCryptor() {}

RTCErrorOr<webrtc::scoped_refptr<EncryptedPacket>> DataPacketCryptor::Encrypt(
    const std::string participant_id,
    int key_index,
    const std::vector<uint8_t>& data) {
  auto key_handler = key_provider_->options().shared_key
                         ? key_provider_->GetSharedKey(participant_id)
                         : key_provider_->GetKey(participant_id);

  if (key_handler == nullptr || key_handler->GetKeySet(key_index) == nullptr) {
    RTC_LOG(LS_INFO) << "DataPacketCryptor::Encrypt() no keys, or "
                        "key_index["
                     << key_index << "] out of range for participant "
                     << participant_id;
    return RTCError(RTCErrorType::INVALID_PARAMETER,
                    "DataPacketCryptor::Encrypt() no keys, or key_index[" +
                        std::to_string(key_index) +
                        "] out of range for participant " + participant_id);
  }

  auto key_set = key_handler->GetKeySet(key_index);
  auto timestamp = Timestamp::Millis(TimeMillis())
                       .ms();   // use current time millis as timestamp
  auto iv = makeIv(timestamp);  // for data packets, ssrc is always 0

  std::vector<uint8_t> buffer;
  Buffer payload(data.data(), data.size());
  auto frame_header = Buffer::CreateUninitializedWithSize(
      0);  // no frame header for data packets
  if (AesEncryptDecrypt(EncryptOrDecrypt::kEncrypt, algorithm_,
                        key_set->encryption_key, iv, frame_header, payload,
                        &buffer) == Success) {
    webrtc::scoped_refptr<EncryptedPacket> encryptedPacket =
        webrtc::make_ref_counted<EncryptedPacket>(
            buffer, std::vector<uint8_t>(iv.begin(), iv.end()), key_index);
    return encryptedPacket;
  }

  return RTCError(RTCErrorType::INTERNAL_ERROR,
                  "DataPacketCryptor::Encrypt() failed");
}

RTCErrorOr<std::vector<uint8_t>> DataPacketCryptor::Decrypt(
    const std::string participant_id,
    const webrtc::scoped_refptr<EncryptedPacket> encryptedPacket) {
  auto key_handler = key_provider_->options().shared_key
                         ? key_provider_->GetSharedKey(participant_id)
                         : key_provider_->GetKey(participant_id);
  int key_index = encryptedPacket->key_index;
  if (key_handler == nullptr || key_handler->GetKeySet(key_index) == nullptr) {
    RTC_LOG(LS_INFO) << "DataPacketCryptor::Decrypt() no keys, or "
                        "key_index["
                     << key_index << "] out of range for participant "
                     << participant_id;
    return RTCError(RTCErrorType::INVALID_PARAMETER,
                    "DataPacketCryptor::Decrypt() no keys, or key_index[" +
                        std::to_string(key_index) +
                        "] out of range for participant " + participant_id);
  }

  std::vector<uint8_t> buffer;
  Buffer encrypted_payload(encryptedPacket->data.data(),
                           encryptedPacket->data.size());
  Buffer iv(encryptedPacket->iv.data(), encryptedPacket->iv.size());
  auto frame_header = Buffer::CreateUninitializedWithSize(
      0);  // no frame header for data packets

  auto key_set = key_handler->GetKeySet(key_index);
  auto initialKeyMaterial = key_set->material;
  bool decryption_success = false;

  if (AesEncryptDecrypt(EncryptOrDecrypt::kDecrypt, algorithm_,
                        key_set->encryption_key, iv, frame_header,
                        encrypted_payload, &buffer) == Success) {
    decryption_success = true;
  } else {
    RTC_LOG(LS_WARNING) << "DataPacketCryptor::Decrypt() failed with key_index "
                        << static_cast<int>(key_index);
    webrtc::scoped_refptr<ParticipantKeyHandler::KeySet> ratcheted_key_set;
    auto currentKeyMaterial = key_set->material;
    int ratchet_count = 0;
    if (key_provider_->options().ratchet_window_size > 0) {
      while (ratchet_count < key_provider_->options().ratchet_window_size) {
        ratchet_count++;

        RTC_LOG(LS_INFO) << "ratcheting key attempt " << ratchet_count << " of "
                         << key_provider_->options().ratchet_window_size;

        auto new_material = key_handler->RatchetKeyMaterial(currentKeyMaterial);
        ratcheted_key_set = key_handler->DeriveKeys(
            new_material, key_provider_->options().ratchet_salt, 128);

        if (AesEncryptDecrypt(EncryptOrDecrypt::kDecrypt, algorithm_,
                              ratcheted_key_set->encryption_key, iv,
                              frame_header, encrypted_payload,
                              &buffer) == Success) {
          RTC_LOG(LS_INFO) << "DataPacketCryptor::Decrypt() successfully "
                              "ratcheted to key_index="
                           << static_cast<int>(key_index);
          decryption_success = true;
          // success, so we set the new key
          key_handler->SetKeyFromMaterial(new_material, key_index);
          key_handler->SetHasValidKey();
          break;
        }
        // for the next ratchet attempt
        currentKeyMaterial = new_material;
      }

      /* Since the key it is first send and only afterwards actually used for
        encrypting, there were situations when the decrypting failed due to the
        fact that the received frame was not encrypted yet and ratcheting, of
        course, did not solve the problem. So if we fail RATCHET_WINDOW_SIZE
        times, we come back to the initial key.
       */
      if (!decryption_success ||
          ratchet_count >= key_provider_->options().ratchet_window_size) {
        key_handler->SetKeyFromMaterial(initialKeyMaterial, key_index);
      }
    }
  }

  if (decryption_success) {
    return buffer;
  }

  return RTCError(RTCErrorType::INTERNAL_ERROR,
                  "DataPacketCryptor::Decrypt() failed");
}

Buffer DataPacketCryptor::makeIv(uint32_t timestamp) {
  if (send_count_ == 0) {
    send_count_ = floor(CreateRandomNonZeroId() * 0xFFFF);
  }
  ByteBufferWriter buf;
  uint32_t random_u32 = CreateRandomId();
  buf.WriteUInt32(random_u32);
  buf.WriteUInt32(timestamp);
  buf.WriteUInt32(timestamp - (send_count_ % 0xFFFF));
  send_count_ += 1;

  RTC_CHECK_EQ(buf.Length(), 12);

  return Buffer(buf.Data(), buf.Length());
}

}  // namespace webrtc
