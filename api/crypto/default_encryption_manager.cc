/*
 * Copyright 2026 Stream
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

#include "api/crypto/default_encryption_manager.h"

#include <openssl/evp.h>
#include <openssl/sha.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstring>
#include <optional>
#include <utility>

#include "api/crypto/frame_crypto_codec.h"
#include "api/crypto/frame_crypto_replay.h"
#include "api/crypto/frame_crypto_trailer.h"
#include "api/task_queue/pending_task_safety_flag.h"
#include "api/units/time_delta.h"
#include "common_video/h264/h264_common.h"
#include "common_video/h265/h265_common.h"
#include "rtc_base/byte_buffer.h"
#include "rtc_base/crypto_random.h"
#include "rtc_base/event.h"
#include "rtc_base/logging.h"
#include "rtc_base/time_utils.h"

namespace webrtc {
namespace {

enum class EncryptOrDecrypt { kEncrypt = 0, kDecrypt };
constexpr int kSuccess = 0;
constexpr int kErrorUnexpected = -1;
constexpr int kOperationError = -2;
constexpr int kErrorDataTooSmall = -3;
// After this many AES failures on one key index we emit "stalled". The
// first 10 still emit "decryption_failed" (throttled to 1/s).
constexpr int kDecryptFailureTolerance = 10;

const EVP_AEAD* AesGcmFromKeySize(size_t key_size_bytes) {
  switch (key_size_bytes) {
    case 16:
      return EVP_aead_aes_128_gcm();
    case 32:
      return EVP_aead_aes_256_gcm();
    default:
      return nullptr;
  }
}

// AES-GCM with a 16-byte tag. `additional_data` is the clear header: it is
// authenticated but not encrypted, so a truncated header fails the tag.
int AesGcmCrypt(EncryptOrDecrypt mode,
                const std::vector<uint8_t>& raw_key,
                ArrayView<const uint8_t> data,
                ArrayView<uint8_t> iv,
                ArrayView<uint8_t> additional_data,
                std::vector<uint8_t>* buffer) {
  const EVP_AEAD* aead_alg = AesGcmFromKeySize(raw_key.size());
  if (!aead_alg) {
    return kErrorUnexpected;
  }
  bssl::ScopedEVP_AEAD_CTX ctx;
  if (!EVP_AEAD_CTX_init(ctx.get(), aead_alg, raw_key.data(), raw_key.size(),
                         16, nullptr)) {
    return kOperationError;
  }
  size_t len = 0;
  int ok = 0;
  if (mode == EncryptOrDecrypt::kDecrypt) {
    // Ciphertext must include the 16-byte tag.
    if (data.size() < 16) {
      return kErrorDataTooSmall;
    }
    buffer->resize(data.size() - 16);
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
    return kOperationError;
  }
  buffer->resize(len);
  return kSuccess;
}

// Trailer key_index is one byte, so only 0–255 are legal.
bool IsValidRawKeyIndex(int key_index) {
  return key_index >= 0 && key_index <= 255;
}

// 8 random bytes stored with the key. Concatenated with the frame counter
// they make the 12-byte AES-GCM IV. Re-importing the same key draws a new
// prefix so two imports do not reuse IVs.
bool FillCsRngPrefix(std::array<uint8_t, 8>* prefix) {
  std::string data;
  if (!CreateRandomData(8, &data) || data.size() != 8) {
    return false;
  }
  memcpy(prefix->data(), data.data(), 8);
  return true;
}

// First 8 bytes of SHA-256(raw key). Safe to put in host events; it is not
// the key itself.
std::array<uint8_t, 8> FingerprintKey(const std::vector<uint8_t>& key) {
  uint8_t hash[SHA256_DIGEST_LENGTH];
  SHA256(key.data(), key.size(), hash);
  std::array<uint8_t, 8> fp{};
  memcpy(fp.data(), hash, 8);
  return fp;
}

// Missing-key / failure / plaintext events fire at most once a second per
// track (and per key index for missing-key).
constexpr int64_t kNotifyIntervalMs = 1000;

bool ThrottleFire(std::optional<int64_t>* last_ms, int64_t now_ms) {
  if (!last_ms->has_value() || now_ms - **last_ms > kNotifyIntervalMs) {
    *last_ms = now_ms;
    return true;
  }
  return false;
}

// LiveKit path only: which H.265 NAL types count as a coded slice so we
// know where the unencrypted header ends.
inline bool IsH265SliceNalu(H265::NaluType nalu_type) {
  return nalu_type == H265::NaluType::kTrailN ||
         nalu_type == H265::NaluType::kTrailR ||
         nalu_type == H265::NaluType::kTsaN ||
         nalu_type == H265::NaluType::kTsaR ||
         nalu_type == H265::NaluType::kStsaN ||
         nalu_type == H265::NaluType::kStsaR ||
         nalu_type == H265::NaluType::kRadlN ||
         nalu_type == H265::NaluType::kRadlR ||
         nalu_type == H265::NaluType::kRaslN ||
         nalu_type == H265::NaluType::kRaslR ||
         nalu_type == H265::NaluType::kBlaWLp ||
         nalu_type == H265::NaluType::kBlaWRadl ||
         nalu_type == H265::NaluType::kBlaNLp ||
         nalu_type == H265::NaluType::kIdrWRadl ||
         nalu_type == H265::NaluType::kIdrNLp ||
         nalu_type == H265::NaluType::kCra;
}

// LiveKit path only. Trailer encode uses GetClearBytes in frame_crypto_codec
// instead (AV1/H.265 fail closed there; here AV1 encrypts the whole frame).
uint8_t LegacyUnencryptedBytes(const FrameCryptoInput& in) {
  if (in.media_type == FrameCryptorTransformer::MediaType::kAudioFrame) {
    return 1;
  }
  if (!in.video_codec) {
    return 0;
  }
  if (*in.video_codec == kVideoCodecAV1) {
    return 0;
  }
  if (*in.video_codec == kVideoCodecVP8) {
    return in.is_keyframe ? 10 : 3;
  }
  if (*in.video_codec == kVideoCodecH264) {
    std::vector<H264::NaluIndex> nalu_indices = H264::FindNaluIndices(in.data);
    for (const auto& index : nalu_indices) {
      const uint8_t* slice = in.data.data() + index.payload_start_offset;
      H264::NaluType nalu_type = H264::ParseNaluType(slice[0]);
      if (nalu_type == H264::NaluType::kIdr ||
          nalu_type == H264::NaluType::kSlice) {
        return static_cast<uint8_t>(index.payload_start_offset + 2);
      }
    }
    return 0;
  }
  if (*in.video_codec == kVideoCodecH265) {
    std::vector<H265::NaluIndex> nalu_indices = H265::FindNaluIndices(in.data);
    for (const auto& index : nalu_indices) {
      const uint8_t* slice = in.data.data() + index.payload_start_offset;
      H265::NaluType nalu_type = H265::ParseNaluType(slice[0]);
      if (IsH265SliceNalu(nalu_type)) {
        return static_cast<uint8_t>(index.payload_start_offset +
                                    H265::kNaluHeaderSize);
      }
    }
    return 0;
  }
  return 0;
}

// LiveKit path: cheap scan for 00 00 03 before calling ParseRbsp.
bool NeedsRbspUnescaping(const uint8_t* frame_data, size_t frame_size) {
  if (frame_size < 3) {
    return false;
  }
  for (size_t i = 0; i < frame_size - 3; ++i) {
    if (frame_data[i] == 0 && frame_data[i + 1] == 0 &&
        frame_data[i + 2] == 3) {
      return true;
    }
  }
  return false;
}

}  // namespace

std::string DefaultEncryptionManager::KeyFingerprint::Hex() const {
  static constexpr char kHex[] = "0123456789abcdef";
  std::string out(16, '0');
  for (int i = 0; i < 8; ++i) {
    out[i * 2] = kHex[fingerprint[i] >> 4];
    out[i * 2 + 1] = kHex[fingerprint[i] & 0xf];
  }
  return out;
}

const char* DefaultEncryptionManager::E2eeEvent::Name() const {
  switch (type) {
    case E2eeEventType::kDecryptionFailed:
      return "e2ee.decryption_failed";
    case E2eeEventType::kDecryptionResumed:
      return "e2ee.decryption_resumed";
    case E2eeEventType::kDecryptionStalled:
      return "e2ee.decryption_stalled";
    case E2eeEventType::kEncryptionFailed:
      return "e2ee.encryption_failed";
    case E2eeEventType::kMissingKey:
      return "e2ee.missing_key";
    case E2eeEventType::kUnencryptedFrame:
      return "e2ee.unencrypted_frame";
    case E2eeEventType::kUnsupportedVersion:
      return "e2ee.unsupported_version";
    case E2eeEventType::kKeyState:
      return "e2ee.key_state";
    case E2eeEventType::kPerfReport:
      return "e2ee.perf_report";
  }
  return "e2ee.missing_key";
}

DefaultEncryptionManager::DefaultEncryptionManager()
    : DefaultEncryptionManager(std::string(), Cipher::kAes128Gcm) {}

DefaultEncryptionManager::DefaultEncryptionManager(Cipher cipher)
    : DefaultEncryptionManager(std::string(), cipher) {}

DefaultEncryptionManager::DefaultEncryptionManager(
    std::string local_participant_id,
    Cipher cipher)
    : algorithm_(FrameCryptorTransformer::Algorithm::kAesGcmTrailer),
      cipher_(cipher),
      expected_key_size_(cipher == Cipher::kAes256Gcm ? 32u : 16u),
      local_participant_id_(std::move(local_participant_id)),
      replay_windows_(std::make_unique<FrameReplayWindows>()) {}

// Old FrameCryptorTransformer(algorithm, KeyProvider) ctor. Keys stay on
// the LiveKit KeyProvider; this manager only wraps encrypt/decrypt.
DefaultEncryptionManager::DefaultEncryptionManager(
    FrameCryptorTransformer::Algorithm algorithm,
    scoped_refptr<KeyProvider> key_provider)
    : algorithm_(algorithm),
      key_provider_(std::move(key_provider)),
      replay_windows_(std::make_unique<FrameReplayWindows>()) {}

DefaultEncryptionManager::~DefaultEncryptionManager() {
  // Kill the delayed perf flush before Stop(), otherwise it could run on a
  // thread that is already tearing down.
  if (perf_safety_) {
    perf_safety_->SetNotAlive();
  }
  if (crypto_thread_) {
    crypto_thread_->Stop();
  }
}

TaskQueueBase* DefaultEncryptionManager::crypto_task_queue() {
  // LiveKit path keeps the transformer's own thread. Trailer path shares
  // one worker on this manager so senders and receivers serialize.
  if (!UsesFrameTrailer()) {
    return nullptr;
  }
  MutexLock lock(&mutex_);
  if (!crypto_thread_) {
    crypto_thread_ = Thread::Create();
    crypto_thread_->SetName("FrameCrypto", this);
    crypto_thread_->Start();
  }
  return crypto_thread_.get();
}

bool DefaultEncryptionManager::IsDisposed() const {
  MutexLock lock(&mutex_);
  return disposed_;
}

void DefaultEncryptionManager::Emit(E2eeEvent event) {
  scoped_refptr<Observer> observer;
  TaskQueueBase* queue = nullptr;
  {
    MutexLock lock(&mutex_);
    if (disposed_ || !observer_) {
      return;
    }
    observer = observer_;
    queue = notify_queue_;
  }
  // Post so we never call the host while holding mutex_ (re-entrancy).
  if (queue) {
    queue->PostTask([observer = std::move(observer),
                     event = std::move(event)] { observer->OnE2eeEvent(event); });
    return;
  }
  observer->OnE2eeEvent(event);
}

void DefaultEncryptionManager::SetObserver(scoped_refptr<Observer> observer,
                                           TaskQueueBase* notify_queue) {
  MutexLock lock(&mutex_);
  if (disposed_) {
    return;
  }
  observer_ = std::move(observer);
  // nullptr → Emit calls the observer on the crypto thread. ObjC hops to
  // main itself; tests pass a queue to keep assertions on one thread.
  notify_queue_ = notify_queue;
}

void DefaultEncryptionManager::RequestKeyState() {
  E2eeEvent ev;
  ev.type = E2eeEventType::kKeyState;
  ev.key_state = KeyState();
  Emit(std::move(ev));
}

void DefaultEncryptionManager::Dispose() {
  MutexLock lock(&mutex_);
  disposed_ = true;
  observer_ = nullptr;
  notify_queue_ = nullptr;
  // Encrypt/Decrypt refuse work after this. Keys stay until destruction.
  perf_enabled_.store(false, std::memory_order_relaxed);
  encode_perf_.clear();
  decode_perf_.clear();
  if (perf_safety_) {
    perf_safety_->SetNotAlive();
    perf_safety_ = nullptr;
  }
}

bool DefaultEncryptionManager::disposed() const {
  return IsDisposed();
}

scoped_refptr<FrameCryptorTransformer> DefaultEncryptionManager::CreateEncryptor(
    Thread* signaling_thread,
    FrameCryptorTransformer::TrackType track_type,
    std::optional<std::string> codec) {
  std::string local_id;
  {
    MutexLock lock(&mutex_);
    // Encode looks up keys under this id. Empty id would never find a key.
    if (disposed_ || local_participant_id_.empty()) {
      return nullptr;
    }
    local_id = local_participant_id_;
  }
  Thread* thread = SignalingThreadOrCrypto(signaling_thread);
  scoped_refptr<FrameCryptorTransformer> cryptor(new FrameCryptorTransformer(
      thread, local_id, track_type, scoped_refptr<EncryptionManager>(this)));
  cryptor->SetEnabled(true);
  // Empty string means "no pin", same as omitting codec at the host API.
  if (codec && !codec->empty()) {
    cryptor->SetEncodeCodec(*codec);
  }
  return cryptor;
}

scoped_refptr<FrameCryptorTransformer> DefaultEncryptionManager::CreateDecryptor(
    Thread* signaling_thread,
    std::string_view participant_id,
    FrameCryptorTransformer::TrackType track_type) {
  // participant_id is the remote sender. Decode looks up keys under that id.
  if (IsDisposed() || participant_id.empty()) {
    return nullptr;
  }
  Thread* thread = SignalingThreadOrCrypto(signaling_thread);
  scoped_refptr<FrameCryptorTransformer> cryptor(new FrameCryptorTransformer(
      thread, std::string(participant_id), track_type,
      scoped_refptr<EncryptionManager>(this)));
  cryptor->SetEnabled(true);
  return cryptor;
}

bool DefaultEncryptionManager::StoreRawKey(
    std::string_view participant_id,
    int key_index,
    std::vector<uint8_t> key,
    const std::array<uint8_t, 8>* forced_prefix,
    bool shared) {
  if (!IsValidRawKeyIndex(key_index) || key.size() != expected_key_size_) {
    // Import failures stay in logs. The host already got false / an error
    // from setKey; we do not emit an e2ee.* event for a bad import.
    RTC_LOG(LS_ERROR) << "e2ee.error: key import rejected (index or length)";
    return false;
  }
  std::array<uint8_t, 8> prefix{};
  if (forced_prefix) {
    // Tests pin the prefix so ciphertext matches a known vector.
    prefix = *forced_prefix;
  } else if (!FillCsRngPrefix(&prefix)) {
    RTC_LOG(LS_ERROR) << "e2ee.error: CSPRNG failed to generate ivPrefix";
    return false;
  }
  RawKeyMaterial material;
  material.fingerprint = FingerprintKey(key);
  material.key = std::move(key);
  material.iv_prefix = prefix;
  MutexLock lock(&mutex_);
  if (disposed_) {
    return false;
  }
  if (shared) {
    raw_shared_keys_[key_index] = std::move(material);
    // Last shared import is the one encode uses when the user has no key.
    active_shared_key_index_ = key_index;
  } else {
    const std::string user(participant_id);
    raw_keys_[user][key_index] = std::move(material);
    // Last per-user import is "latest". Removing it does not promote an
    // older index; encode then falls back to active shared, or fails.
    latest_key_index_[user] = key_index;
  }
  return true;
}

bool DefaultEncryptionManager::SetKey(std::string_view participant_id,
                                      int key_index,
                                      ArrayView<const uint8_t> key) {
  return StoreRawKey(participant_id, key_index,
                     std::vector<uint8_t>(key.begin(), key.end()), nullptr,
                     false);
}

bool DefaultEncryptionManager::SetSharedKey(int key_index,
                                            ArrayView<const uint8_t> key) {
  return StoreRawKey({}, key_index,
                     std::vector<uint8_t>(key.begin(), key.end()), nullptr,
                     true);
}

void DefaultEncryptionManager::RemoveKey(std::string_view participant_id,
                                         int key_index) {
  MutexLock lock(&mutex_);
  if (disposed_) {
    return;
  }
  const std::string user(participant_id);
  auto it = raw_keys_.find(user);
  if (it == raw_keys_.end()) {
    return;
  }
  if (!it->second.erase(key_index)) {
    return;
  }
  if (it->second.empty()) {
    raw_keys_.erase(it);
  }
  auto latest = latest_key_index_.find(user);
  if (latest != latest_key_index_.end() && latest->second == key_index) {
    latest_key_index_.erase(latest);
  }
}

void DefaultEncryptionManager::RemoveAllKeys(std::string_view participant_id) {
  MutexLock lock(&mutex_);
  if (disposed_) {
    return;
  }
  const std::string user(participant_id);
  raw_keys_.erase(user);
  latest_key_index_.erase(user);
}

void DefaultEncryptionManager::RemoveSharedKey(int key_index) {
  MutexLock lock(&mutex_);
  if (disposed_) {
    return;
  }
  raw_shared_keys_.erase(key_index);
  if (active_shared_key_index_ == key_index) {
    active_shared_key_index_.reset();
  }
}

bool DefaultEncryptionManager::SetKeyWithIvPrefix(
    std::string_view participant_id,
    int key_index,
    ArrayView<const uint8_t> key,
    std::array<uint8_t, 8> iv_prefix) {
  return StoreRawKey(participant_id, key_index,
                     std::vector<uint8_t>(key.begin(), key.end()), &iv_prefix,
                     false);
}

bool DefaultEncryptionManager::SetSharedKeyWithIvPrefix(
    int key_index,
    ArrayView<const uint8_t> key,
    std::array<uint8_t, 8> iv_prefix) {
  return StoreRawKey({}, key_index,
                     std::vector<uint8_t>(key.begin(), key.end()), &iv_prefix,
                     true);
}

void DefaultEncryptionManager::SetSendCounterForTest(uint32_t counter) {
  MutexLock lock(&mutex_);
  send_counter_ = counter;
}

void DefaultEncryptionManager::WaitUntilIdleForTest() {
  TaskQueueBase* queue = crypto_task_queue();
  if (!queue) {
    return;
  }
  Event done;
  queue->PostTask([&done] { done.Set(); });
  done.Wait(Event::kForever);
}

void DefaultEncryptionManager::FlushPerfReportsForTest() {
  FlushPerfReports();
}

Thread* DefaultEncryptionManager::SignalingThreadOrCrypto(
    Thread* signaling_thread) {
  // iOS attach hops SetFrameTransformer onto this thread. Crypto itself
  // still runs on crypto_task_queue() (see FrameCryptorTransformer::Transform).
  if (signaling_thread) {
    return signaling_thread;
  }
  return static_cast<Thread*>(crypto_task_queue());
}

bool DefaultEncryptionManager::EnablePerformanceReporting(bool enabled) {
  // LiveKit AES-GCM/CBC has no e2ee.perf_report; only the trailer path does.
  if (!UsesFrameTrailer()) {
    return false;
  }
  {
    MutexLock lock(&mutex_);
    if (disposed_) {
      return false;
    }
    if (perf_enabled_.load(std::memory_order_relaxed) == enabled) {
      return true;
    }
    perf_enabled_.store(enabled, std::memory_order_relaxed);
    if (!enabled) {
      encode_perf_.clear();
      decode_perf_.clear();
      if (perf_safety_) {
        perf_safety_->SetNotAlive();
        perf_safety_ = nullptr;
      }
      return true;
    }
    perf_safety_ = PendingTaskSafetyFlag::Create();
    perf_last_tick_us_ = TimeMicros();
  }
  SchedulePerfFlush();
  return true;
}

void DefaultEncryptionManager::SchedulePerfFlush() {
  scoped_refptr<PendingTaskSafetyFlag> flag;
  TaskQueueBase* queue = crypto_task_queue();
  {
    MutexLock lock(&mutex_);
    if (!perf_enabled_.load(std::memory_order_relaxed) || disposed_ ||
        !perf_safety_ || !queue) {
      return;
    }
    flag = perf_safety_;
  }
  queue->PostDelayedTask(
      SafeTask(std::move(flag),
               [this] {
                 FlushPerfReports();
                 // Re-arm from the crypto thread so ticks stay 1s apart
                 // even if enable() was called from the host thread.
                 SchedulePerfFlush();
               }),
      TimeDelta::Millis(1000));
}

void DefaultEncryptionManager::RecordPerf(bool encode,
                                          const FrameCryptoInput& in,
                                          int64_t started_us) {
  MutexLock lock(&mutex_);
  if (!perf_enabled_.load(std::memory_order_relaxed) || disposed_) {
    return;
  }
  PerfKey key;
  key.participant_id = std::string(in.participant_id);
  key.track_type = in.track_type;
  // Encode labels use the pin if the host passed one, else the frame codec.
  // Decode never has a pin, so we leave codec empty to match JS samples.
  if (encode) {
    key.codec = FrameCodecLabel(in);
  }
  PerfAccum& slot = encode ? encode_perf_[key] : decode_perf_[key];
  slot.count++;
  const double ms = (TimeMicros() - started_us) / 1000.0;
  if (ms > slot.max_crypto_ms) {
    slot.max_crypto_ms = ms;
  }
}

void DefaultEncryptionManager::FlushPerfReports() {
  std::map<PerfKey, PerfAccum> encode;
  std::map<PerfKey, PerfAccum> decode;
  int64_t last = 0;
  const int64_t now = TimeMicros();
  {
    MutexLock lock(&mutex_);
    if (!perf_enabled_.load(std::memory_order_relaxed) || disposed_) {
      return;
    }
    encode.swap(encode_perf_);
    decode.swap(decode_perf_);
    last = perf_last_tick_us_;
    perf_last_tick_us_ = now;
  }
  // Floor at 1ms so the first tick after enable cannot divide by ~0.
  const double dt_sec = std::max(0.001, (now - last) / 1000000.0);
  E2eeEvent ev;
  ev.type = E2eeEventType::kPerfReport;
  for (const auto& row : encode) {
    TrackPerf p;
    p.participant_id = row.first.participant_id;
    p.track_type = row.first.track_type;
    p.codec = row.first.codec;
    p.fps = row.second.count / dt_sec;
    p.max_crypto_ms = row.second.max_crypto_ms;
    ev.encode_perf.push_back(std::move(p));
  }
  for (const auto& row : decode) {
    TrackPerf p;
    p.participant_id = row.first.participant_id;
    p.track_type = row.first.track_type;
    p.fps = row.second.count / dt_sec;
    p.max_crypto_ms = row.second.max_crypto_ms;
    ev.decode_perf.push_back(std::move(p));
  }
  Emit(std::move(ev));
}

std::optional<DefaultEncryptionManager::RawKeyMaterial>
DefaultEncryptionManager::GetDecryptKey(const std::string& participant_id,
                                        int key_index) const {
  MutexLock lock(&mutex_);
  // Sender's per-user key at the trailer key_index, else shared at that
  // index. A user named "shared" is a normal user, not the shared store.
  auto user = raw_keys_.find(participant_id);
  if (user != raw_keys_.end()) {
    auto slot = user->second.find(key_index);
    if (slot != user->second.end()) {
      return slot->second;
    }
  }
  auto shared = raw_shared_keys_.find(key_index);
  if (shared != raw_shared_keys_.end()) {
    return shared->second;
  }
  return std::nullopt;
}

std::optional<std::pair<int, DefaultEncryptionManager::RawKeyMaterial>>
DefaultEncryptionManager::GetLatestKey(const std::string& participant_id) const {
  MutexLock lock(&mutex_);
  auto latest = latest_key_index_.find(participant_id);
  if (latest != latest_key_index_.end()) {
    auto user = raw_keys_.find(participant_id);
    if (user != raw_keys_.end()) {
      auto slot = user->second.find(latest->second);
      if (slot != user->second.end()) {
        return std::make_pair(latest->second, slot->second);
      }
    }
  }
  // Removing the latest per-user key does not promote an older index.
  // Encode then uses the active shared key, or fails missing-key.
  if (active_shared_key_index_) {
    auto shared = raw_shared_keys_.find(*active_shared_key_index_);
    if (shared != raw_shared_keys_.end()) {
      return std::make_pair(*active_shared_key_index_, shared->second);
    }
  }
  return std::nullopt;
}

std::vector<DefaultEncryptionManager::KeyFingerprint>
DefaultEncryptionManager::KeyState() const {
  MutexLock lock(&mutex_);
  std::vector<KeyFingerprint> out;
  for (const auto& user : raw_keys_) {
    for (const auto& slot : user.second) {
      KeyFingerprint fp;
      fp.participant_id = user.first;
      fp.key_index = slot.first;
      fp.fingerprint = slot.second.fingerprint;
      out.push_back(fp);
    }
  }
  for (const auto& slot : raw_shared_keys_) {
    KeyFingerprint fp;
    fp.key_index = slot.first;
    fp.fingerprint = slot.second.fingerprint;
    fp.shared = true;
    fp.active_shared = active_shared_key_index_ == slot.first;
    out.push_back(fp);
  }
  return out;
}

std::optional<uint32_t> DefaultEncryptionManager::TakeSendCounter() {
  MutexLock lock(&mutex_);
  // Counter is global on this manager (all senders share it). Wrap is
  // fail-closed: the host must construct a new manager.
  if (send_counter_ == 0xffffffffu) {
    return std::nullopt;
  }
  ++send_counter_;
  return send_counter_;
}

bool DefaultEncryptionManager::Encrypt(const FrameCryptoInput& in,
                                       Buffer& out,
                                       FrameCryptionState* state) {
  // Sample only when reporting is on, and only after a successful encrypt.
  const int64_t t0 =
      perf_enabled_.load(std::memory_order_relaxed) ? TimeMicros() : 0;
  if (IsDisposed()) {
    *state = kInternalError;
    return false;
  }
  bool ok = false;
  if (!UsesFrameTrailer()) {
    // LiveKit path: empty frames skip AES. Trailer encode still runs the
    // codec pin first (pinned unsupported codecs drop empty frames too).
    if (in.data.empty()) {
      out.SetData(in.data.data(), in.data.size());
      *state = kOk;
      ok = true;
    } else {
      ok = EncryptLegacy(in, out, state);
    }
  } else {
    ok = EncryptFramed(in, out, state);
  }
  if (ok && t0) {
    RecordPerf(true, in, t0);
  }
  return ok;
}

bool DefaultEncryptionManager::Decrypt(const FrameCryptoInput& in,
                                       Buffer& out,
                                       FrameCryptionState* state) {
  const int64_t t0 =
      perf_enabled_.load(std::memory_order_relaxed) ? TimeMicros() : 0;
  if (IsDisposed()) {
    *state = kInternalError;
    return false;
  }
  bool ok = false;
  // Decode has no codec pin, so empty payloads always forward (spec §6).
  // Encode checks a pin first and can still drop empty frames (pinned av1).
  if (in.data.empty()) {
    out.SetData(in.data.data(), in.data.size());
    *state = kOk;
    ok = true;
  } else {
    ok = UsesFrameTrailer() ? DecryptFramed(in, out, state)
                            : DecryptLegacy(in, out, state);
  }
  if (ok && t0) {
    RecordPerf(false, in, t0);
  }
  return ok;
}

bool DefaultEncryptionManager::EncryptFramed(const FrameCryptoInput& in,
                                             Buffer& out,
                                             FrameCryptionState* state) {
  const TrackId track{std::string(in.participant_id), in.track_type};
  // Hard encode failures (codec, AES, counter) fire once per track, then
  // stay silent (kNew) until a frame succeeds and clears the latch.
  auto fail_encode = [&](FrameCryptionState err, std::string_view reason) {
    bool& latched = encode_failed_latched_[track];
    if (latched) {
      *state = kNew;
      return false;
    }
    latched = true;
    *state = err;
    E2eeEvent ev;
    ev.type = E2eeEventType::kEncryptionFailed;
    ev.participant_id = std::string(in.participant_id);
    ev.track_type = in.track_type;
    ev.reason = std::string(reason);
    Emit(std::move(ev));
    return false;
  };

  // Spec §6 / JS encodeTransform: empty payload is forwarded before key or
  // codec checks. A pinned unsupported codec (JS selectTransform) still
  // drops every frame, including empty ones.
  // Copy so the pin can override video_codec without mutating the caller's
  // input. Perf still labels from `in` (codec_name is already the pin).
  FrameCryptoInput local = in;
  if (!ApplyEncodeCodecPin(&local)) {
    std::string reason = "unsupported codec for E2EE";
    if (in.codec_name) {
      reason += ": ";
      reason += *in.codec_name;
    }
    return fail_encode(kEncryptionFailed, reason);
  }
  if (local.data.empty()) {
    out.SetData(local.data.data(), local.data.size());
    *state = kOk;
    return true;
  }

  // Key first, then codec, then counter. That matches the order a missing
  // key should be reported before "unsupported codec".
  auto latest = GetLatestKey(std::string(in.participant_id));
  if (!latest) {
    if (ThrottleFire(&encode_missing_key_ms_[std::string(in.participant_id)],
                     TimeMillis())) {
      *state = kMissingKey;
      E2eeEvent ev;
      ev.type = E2eeEventType::kMissingKey;
      ev.participant_id = std::string(in.participant_id);
      Emit(std::move(ev));
    } else {
      *state = kNew;
    }
    return false;
  }

  size_t clear_bytes = 0;
  const auto support = GetClearBytes(local, &clear_bytes);
  if (support == FrameCodecSupport::kUnsupported) {
    return fail_encode(kEncryptionFailed, "no clear-byte rule for video");
  }
  if (clear_bytes > kFrameTrailerMaxClearBytes) {
    return fail_encode(kEncryptionFailed, "clearBytes exceeds trailer capacity");
  }
  const int key_index = latest->first;
  const RawKeyMaterial material = latest->second;
  auto counter = TakeSendCounter();
  if (!counter) {
    return fail_encode(
        kCounterExhausted,
        "frame counter exhausted, create a new EncryptionManager");
  }
  uint8_t iv[12];
  FillFrameIv(iv, material.iv_prefix, *counter);
  // AAD is the clear header, same as decode. SFU/RTP can read it; GCM
  // still authenticates it so a truncated header fails the tag.
  Buffer frame_header(local.data.data(), clear_bytes);
  ArrayView<const uint8_t> payload(local.data.data() + clear_bytes,
                                   local.data.size() - clear_bytes);
  std::vector<uint8_t> ciphertext;
  if (AesGcmCrypt(EncryptOrDecrypt::kEncrypt, material.key, payload, iv,
                  frame_header, &ciphertext) != kSuccess) {
    return fail_encode(kEncryptionFailed, "AES-GCM encrypt failed");
  }
  encode_failed_latched_[track] = false;
  // H.264 ciphertext+trailer can invent 00 00 01 in the bitstream. Escape
  // that unit; the decoder unescapes before AES. Skip when there is no
  // clear header (nothing for a start-code scan to latch onto).
  const bool is_rbsp = local.video_codec && *local.video_codec == kVideoCodecH264 &&
                       clear_bytes > 0;
  uint8_t trailer_bytes[kFrameTrailerLen];
  WriteFrameTrailer(trailer_bytes, *counter, material.iv_prefix,
                    static_cast<uint8_t>(key_index),
                    static_cast<uint16_t>(clear_bytes), is_rbsp);
  out.Clear();
  out.AppendData(frame_header);
  if (is_rbsp) {
    std::vector<uint8_t> unit;
    unit.reserve(ciphertext.size() + kFrameTrailerLen);
    unit.insert(unit.end(), ciphertext.begin(), ciphertext.end());
    unit.insert(unit.end(), trailer_bytes, trailer_bytes + kFrameTrailerLen);
    const int seed = BoundarySeedZeros(frame_header);
    std::vector<uint8_t> escaped(RbspEscapedLength(unit, seed));
    RbspEscapeInto(escaped.data(), unit, seed);
    out.AppendData(escaped.data(), escaped.size());
  } else {
    out.AppendData(ciphertext.data(), ciphertext.size());
    out.AppendData(trailer_bytes, kFrameTrailerLen);
  }
  *state = kOk;
  return true;
}

bool DefaultEncryptionManager::DecryptFramed(const FrameCryptoInput& in,
                                             Buffer& out,
                                             FrameCryptionState* state) {
  const TrackId track{std::string(in.participant_id), in.track_type};
  DecodeTrackState& dec = decode_tracks_[track];
  const int64_t now = TimeMillis();

  auto trailer = ReadFrameTrailer(in.data);
  if (!trailer) {
    // Magic matched but version is not 1: drop, do not treat as plaintext.
    const auto version = ReadFramingVersion(in.data);
    if (version && *version != kFrameTrailerVersion) {
      if (ThrottleFire(&dec.version_ms, now)) {
        *state = kUnsupportedVersion;
        E2eeEvent ev;
        ev.type = E2eeEventType::kUnsupportedVersion;
        ev.participant_id = std::string(in.participant_id);
        ev.track_type = in.track_type;
        ev.version = *version;
        Emit(std::move(ev));
      } else {
        *state = kNew;
      }
      return false;
    }
    // No trailer: forward as cleartext and tell the host (throttled).
    out.SetData(in.data.data(), in.data.size());
    if (ThrottleFire(&dec.cleartext_ms, now)) {
      *state = kUnencrypted;
      E2eeEvent ev;
      ev.type = E2eeEventType::kUnencryptedFrame;
      ev.participant_id = std::string(in.participant_id);
      ev.track_type = in.track_type;
      Emit(std::move(ev));
    } else {
      *state = kOk;
    }
    return true;
  }
  uint32_t frame_counter = trailer->frame_counter;
  std::array<uint8_t, 8> iv_prefix = trailer->iv_prefix;
  uint8_t key_index = trailer->key_index;
  const size_t clear_bytes = trailer->clear_bytes;
  std::vector<uint8_t> ciphertext;
  if (trailer->is_rbsp) {
    // Unescape ciphertext+trailer as one unit. Escape bytes can sit inside
    // the trailer, so counter / prefix / key index must be re-read after.
    const int seed = BoundarySeedZeros(in.data.subview(0, clear_bytes));
    auto unit = RbspUnescape(in.data.subview(clear_bytes), seed);
    auto fields = ReadUnescapedTrailerFields(unit);
    if (!fields) {
      *state = kNew;
      return false;
    }
    frame_counter = fields->frame_counter;
    iv_prefix = fields->iv_prefix;
    key_index = fields->key_index;
    ciphertext.assign(unit.begin(),
                      unit.begin() + static_cast<long>(unit.size() -
                                                       kFrameTrailerLen));
  } else {
    // Unescaped path: ciphertext is everything between the clear header and
    // the 20-byte trailer, including the 16-byte GCM tag.
    ciphertext.assign(in.data.data() + clear_bytes,
                      in.data.data() + in.data.size() - kFrameTrailerLen);
  }

  auto material = GetDecryptKey(std::string(in.participant_id), key_index);
  if (!material) {
    if (ThrottleFire(&dec.missing_key_ms[key_index], now)) {
      *state = kMissingKey;
      E2eeEvent ev;
      ev.type = E2eeEventType::kMissingKey;
      ev.participant_id = std::string(in.participant_id);
      ev.track_type = in.track_type;
      ev.key_index = key_index;
      Emit(std::move(ev));
    } else {
      *state = kNew;
    }
    return false;
  }
  // Replay check before AES so we do not spend CPU on a duplicate. Peek
  // does not consume the slot; Commit runs only after AES succeeds.
  if (!replay_windows_->Peek(std::string(in.participant_id), in.track_type,
                             frame_counter, iv_prefix)) {
    *state = kNew;
    return false;
  }

  uint8_t iv[12];
  FillFrameIv(iv, iv_prefix, frame_counter);
  // AAD is the clear header: GCM rejects a truncated or swapped header.
  Buffer frame_header(in.data.data(), clear_bytes);
  std::vector<uint8_t> plaintext;
  if (AesGcmCrypt(EncryptOrDecrypt::kDecrypt, material->key, ciphertext, iv,
                  frame_header, &plaintext) != kSuccess) {
    int& fails = dec.fail_counts[key_index];
    fails++;
    const bool stalled = (fails == kDecryptFailureTolerance + 1);
    if (ThrottleFire(&dec.failure_ms, now)) {
      dec.failure_reported = true;
      E2eeEvent ev;
      ev.type = E2eeEventType::kDecryptionFailed;
      ev.participant_id = std::string(in.participant_id);
      ev.track_type = in.track_type;
      Emit(std::move(ev));
      if (!stalled) {
        *state = kDecryptionFailed;
        return false;
      }
    }
    if (stalled && !dec.stalled) {
      dec.stalled = true;
      *state = kStalled;
      E2eeEvent ev;
      ev.type = E2eeEventType::kDecryptionStalled;
      ev.participant_id = std::string(in.participant_id);
      ev.track_type = in.track_type;
      ev.key_index = key_index;
      Emit(std::move(ev));
      return false;
    }
    *state = kNew;
    return false;
  }

  replay_windows_->Commit(std::string(in.participant_id), in.track_type,
                          frame_counter, iv_prefix);
  dec.fail_counts.erase(key_index);
  dec.stalled = false;
  // Pair with the last throttled decryption_failed: host UIs treat resumed
  // as "media is decrypting again", not as a per-frame ok.
  if (dec.failure_reported) {
    dec.failure_reported = false;
    *state = kResumed;
    E2eeEvent ev;
    ev.type = E2eeEventType::kDecryptionResumed;
    ev.participant_id = std::string(in.participant_id);
    ev.track_type = in.track_type;
    Emit(std::move(ev));
  } else {
    *state = kOk;
  }
  out.Clear();
  out.AppendData(frame_header);
  out.AppendData(plaintext.data(), plaintext.size());
  return true;
}

Buffer DefaultEncryptionManager::MakeLegacyIv(uint32_t ssrc,
                                              uint32_t timestamp) {
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
  return Buffer(buf.Data(), buf.Length());
}

uint8_t DefaultEncryptionManager::LegacyIvSize() const {
  return algorithm_ == FrameCryptorTransformer::Algorithm::kAesGcm ||
                 algorithm_ ==
                     FrameCryptorTransformer::Algorithm::kAesGcmTrailer
             ? 12
             : 0;
}

bool DefaultEncryptionManager::EncryptLegacy(const FrameCryptoInput& in,
                                             Buffer& out,
                                             FrameCryptionState* state) {
  if (!key_provider_) {
    *state = kMissingKey;
    return false;
  }
  auto key_handler = key_provider_->options().shared_key
                         ? key_provider_->GetSharedKey(
                               std::string(in.participant_id))
                         : key_provider_->GetKey(std::string(in.participant_id));
  if (key_handler == nullptr ||
      key_handler->GetKeySet(in.key_index) == nullptr) {
    *state = kMissingKey;
    return false;
  }
  auto key_set = key_handler->GetKeySet(in.key_index);
  const uint8_t unencrypted_bytes = LegacyUnencryptedBytes(in);
  Buffer frame_header(in.data.data(), unencrypted_bytes);
  // LiveKit trailer is 2 bytes: IV length, then key index. IV is appended
  // before that, not mixed into a 12-byte prefix||counter.
  Buffer frame_trailer = Buffer::CreateUninitializedWithSize(2);
  frame_trailer[0] = LegacyIvSize();
  frame_trailer[1] = static_cast<uint8_t>(in.key_index);
  Buffer iv = MakeLegacyIv(in.ssrc, in.rtp_timestamp);
  Buffer payload(in.data.data() + unencrypted_bytes,
                 in.data.size() - unencrypted_bytes);
  std::vector<uint8_t> buffer;
  if (AesGcmCrypt(EncryptOrDecrypt::kEncrypt, key_set->encryption_key, payload,
                  iv, frame_header, &buffer) != kSuccess) {
    *state = kEncryptionFailed;
    return false;
  }
  Buffer encrypted_payload(buffer.data(), buffer.size());
  Buffer data_without_header;
  data_without_header.AppendData(encrypted_payload);
  data_without_header.AppendData(iv);
  data_without_header.AppendData(frame_trailer);
  out.Clear();
  out.AppendData(frame_header);
  if (in.video_codec && *in.video_codec == kVideoCodecH264) {
    H264::WriteRbsp(data_without_header.data(), data_without_header.size(),
                    &out);
  } else if (in.video_codec && *in.video_codec == kVideoCodecH265) {
    H265::WriteRbsp(data_without_header.data(), data_without_header.size(),
                    &out);
  } else {
    out.AppendData(data_without_header);
  }
  *state = kOk;
  return true;
}

bool DefaultEncryptionManager::DecryptLegacy(const FrameCryptoInput& in,
                                             Buffer& out,
                                             FrameCryptionState* state) {
  if (!key_provider_) {
    *state = kMissingKey;
    return false;
  }
  // Optional "this frame is intentionally unencrypted" magic at the tail.
  auto uncrypted_magic_bytes = key_provider_->options().uncrypted_magic_bytes;
  if (uncrypted_magic_bytes.size() > 0 &&
      in.data.size() >= uncrypted_magic_bytes.size()) {
    auto tmp = in.data.subview(in.data.size() - uncrypted_magic_bytes.size(),
                               uncrypted_magic_bytes.size());
    std::vector<uint8_t> data(tmp.begin(), tmp.end());
    if (uncrypted_magic_bytes == data) {
      out.Clear();
      out.AppendData(
          in.data.subview(0, in.data.size() - uncrypted_magic_bytes.size()));
      *state = kOk;
      return true;
    }
  }

  const uint8_t unencrypted_bytes = LegacyUnencryptedBytes(in);
  Buffer frame_header(in.data.data(), unencrypted_bytes);
  const uint8_t iv_length = in.data[in.data.size() - 2];
  const uint8_t key_index = in.data[in.data.size() - 1];
  if (iv_length != LegacyIvSize()) {
    *state = kDecryptionFailed;
    return false;
  }
  auto key_handler = key_provider_->options().shared_key
                         ? key_provider_->GetSharedKey(
                               std::string(in.participant_id))
                         : key_provider_->GetKey(std::string(in.participant_id));
  if (key_index >= key_provider_->options().key_ring_size ||
      key_handler == nullptr || key_handler->GetKeySet(key_index) == nullptr) {
    *state = kMissingKey;
    return false;
  }
  if (!key_handler->HasValidKey() &&
      key_provider_->options().failure_tolerance >= 0) {
    *state = kDecryptionFailed;
    return false;
  }
  auto key_set = key_handler->GetKeySet(key_index);
  Buffer iv = Buffer::CreateUninitializedWithSize(iv_length);
  for (size_t i = 0; i < iv_length; i++) {
    iv[i] = in.data[in.data.size() - 2 - iv_length + i];
  }
  Buffer encrypted_buffer(in.data.data() + unencrypted_bytes,
                          in.data.size() - unencrypted_bytes);
  if (in.video_codec && *in.video_codec == kVideoCodecH264 &&
      NeedsRbspUnescaping(encrypted_buffer.data(), encrypted_buffer.size())) {
    encrypted_buffer.SetData(
        H264::ParseRbsp(encrypted_buffer.data(), encrypted_buffer.size()));
  } else if (in.video_codec && *in.video_codec == kVideoCodecH265 &&
             NeedsRbspUnescaping(encrypted_buffer.data(),
                                 encrypted_buffer.size())) {
    encrypted_buffer.SetData(
        H265::ParseRbsp(encrypted_buffer.data(), encrypted_buffer.size()));
  }
  Buffer encrypted_payload(encrypted_buffer.data(),
                           encrypted_buffer.size() - iv_length - 2);
  std::vector<uint8_t> buffer;
  bool decryption_success = false;
  auto initial_key_material = key_set->material;
  if (AesGcmCrypt(EncryptOrDecrypt::kDecrypt, key_set->encryption_key,
                  encrypted_payload, iv, frame_header, &buffer) == kSuccess) {
    decryption_success = true;
  } else if (key_provider_->options().ratchet_window_size > 0) {
    // Try the next N ratcheted keys. On success keep the new material; on
    // failure restore the original so a bad window does not advance the ring.
    auto current = key_set->material;
    int ratchet_count = 0;
    while (ratchet_count < key_provider_->options().ratchet_window_size) {
      ratchet_count++;
      auto new_material = key_handler->RatchetKeyMaterial(current);
      auto ratcheted = key_handler->DeriveKeys(
          new_material, key_provider_->options().ratchet_salt, 128);
      if (AesGcmCrypt(EncryptOrDecrypt::kDecrypt, ratcheted->encryption_key,
                      encrypted_payload, iv, frame_header,
                      &buffer) == kSuccess) {
        decryption_success = true;
        key_handler->SetKeyFromMaterial(new_material, key_index);
        key_handler->SetHasValidKey();
        *state = kKeyRatcheted;
        break;
      }
      current = new_material;
    }
    if (!decryption_success ||
        ratchet_count >= key_provider_->options().ratchet_window_size) {
      key_handler->SetKeyFromMaterial(initial_key_material, key_index);
    }
  }
  if (!decryption_success) {
    if (key_handler->DecryptionFailure()) {
      *state = kDecryptionFailed;
    }
    return false;
  }
  out.Clear();
  out.AppendData(frame_header);
  out.AppendData(buffer.data(), buffer.size());
  if (*state != kKeyRatcheted) {
    *state = kOk;
  }
  return true;
}

}  // namespace webrtc
