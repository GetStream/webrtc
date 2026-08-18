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

#ifndef API_CRYPTO_DEFAULT_ENCRYPTION_MANAGER_H_
#define API_CRYPTO_DEFAULT_ENCRYPTION_MANAGER_H_

#include <array>
#include <atomic>
#include <cstdint>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "api/array_view.h"
#include "api/crypto/frame_encryption_manager.h"
#include "api/ref_count.h"
#include "api/scoped_refptr.h"
#include "api/task_queue/pending_task_safety_flag.h"
#include "api/task_queue/task_queue_base.h"
#include "rtc_base/synchronization/mutex.h"
#include "rtc_base/thread.h"

namespace webrtc {

class FrameReplayWindows;

// AES-GCM frame encryption with a 20-byte trailer. Keys live here. Attach
// this instance to FrameCryptorTransformer (or implement EncryptionManager
// yourself).
class RTC_EXPORT DefaultEncryptionManager : public EncryptionManager {
 public:
  // AES-128 vs AES-256. The key size is locked at construction: a 16-byte
  // key is rejected on AES-256 and a 32-byte key is rejected on AES-128.
  enum class Cipher {
    kAes128Gcm,
    kAes256Gcm,
  };

  struct KeyFingerprint {
    std::string participant_id;
    int key_index = 0;
    std::array<uint8_t, 8> fingerprint{};
    bool shared = false;
    bool active_shared = false;
    // 16-char lowercase hex of the first 8 bytes of SHA-256(raw key).
    // Safe to log; it is not the key.
    std::string Hex() const;
  };

  // Host-facing events. Name() is the stable string, e.g. "e2ee.missing_key".
  enum class E2eeEventType {
    kDecryptionFailed,
    kDecryptionResumed,
    kDecryptionStalled,
    kEncryptionFailed,
    kMissingKey,
    kUnencryptedFrame,
    kUnsupportedVersion,
    kKeyState,
    kPerfReport,
  };

  // One row of `e2ee.perf_report`. `codec` is set on encode samples only.
  struct TrackPerf {
    std::string participant_id;
    FrameCryptorTransformer::TrackType track_type =
        FrameCryptorTransformer::TrackType::kAudio;
    std::string codec;
    double fps = 0;
    double max_crypto_ms = 0;
  };

  struct E2eeEvent {
    E2eeEventType type = E2eeEventType::kMissingKey;
    std::string participant_id;
    std::optional<FrameCryptorTransformer::TrackType> track_type;
    std::optional<int> key_index;
    std::optional<uint8_t> version;
    std::string reason;
    std::vector<KeyFingerprint> key_state;
    std::vector<TrackPerf> encode_perf;
    std::vector<TrackPerf> decode_perf;
    // Event name, e.g. "e2ee.missing_key".
    const char* Name() const;
  };

  class Observer : public RefCountInterface {
   public:
    virtual void OnE2eeEvent(const E2eeEvent& event) = 0;

   protected:
    ~Observer() override = default;
  };

  // AES-128, empty local participant id. CreateEncryptor needs a non-empty id.
  DefaultEncryptionManager();
  explicit DefaultEncryptionManager(Cipher cipher);
  explicit DefaultEncryptionManager(std::string local_participant_id,
                                    Cipher cipher = Cipher::kAes128Gcm);
  // LiveKit AES-GCM/CBC path used by the old FrameCryptorTransformer ctor
  // (algorithm + KeyProvider). Not the trailer format.
  DefaultEncryptionManager(FrameCryptorTransformer::Algorithm algorithm,
                           scoped_refptr<KeyProvider> key_provider);
  ~DefaultEncryptionManager() override;

  bool Encrypt(const FrameCryptoInput& in,
               Buffer& out,
               FrameCryptionState* state) override;
  bool Decrypt(const FrameCryptoInput& in,
               Buffer& out,
               FrameCryptionState* state) override;

  bool SetKey(std::string_view participant_id,
              int key_index,
              ArrayView<const uint8_t> key) override;
  bool SetSharedKey(int key_index, ArrayView<const uint8_t> key) override;
  void RemoveKey(std::string_view participant_id, int key_index) override;
  void RemoveAllKeys(std::string_view participant_id) override;
  void RemoveSharedKey(int key_index) override;

  TaskQueueBase* crypto_task_queue() override;

  void SetObserver(scoped_refptr<Observer> observer,
                   TaskQueueBase* notify_queue = nullptr);
  void RequestKeyState();
  // Once a second while on, emit `e2ee.perf_report` with per-track fps
  // and max AES time. Off by default. No-op (false) after Dispose.
  bool EnablePerformanceReporting(bool enabled);
  void Dispose();
  bool disposed() const;
  const std::string& local_participant_id() const {
    return local_participant_id_;
  }
  Cipher cipher() const { return cipher_; }

  // Attach an enabled transformer to a local sender (encrypt) or a remote
  // receiver (decrypt). `participant_id` on decrypt is the sender's user id.
  // `codec` pins the encode-side clear-byte rule (`opus`/`vp8`/`vp9`/`h264`).
  // Omit it (or pass empty) to read the codec from each encoded frame.
  // `signaling_thread` may be nullptr: attach then uses crypto_task_queue().
  scoped_refptr<FrameCryptorTransformer> CreateEncryptor(
      Thread* signaling_thread,
      FrameCryptorTransformer::TrackType track_type,
      std::optional<std::string> codec = std::nullopt);
  scoped_refptr<FrameCryptorTransformer> CreateDecryptor(
      Thread* signaling_thread,
      std::string_view participant_id,
      FrameCryptorTransformer::TrackType track_type);

  // Tests only: pin the 8-byte IV prefix instead of drawing it from CSPRNG,
  // so ciphertext can be compared to a known vector.
  bool SetKeyWithIvPrefix(std::string_view participant_id,
                          int key_index,
                          ArrayView<const uint8_t> key,
                          std::array<uint8_t, 8> iv_prefix);
  bool SetSharedKeyWithIvPrefix(int key_index,
                                ArrayView<const uint8_t> key,
                                std::array<uint8_t, 8> iv_prefix);
  void SetSendCounterForTest(uint32_t counter);
  void WaitUntilIdleForTest();
  // Drain perf accumulators now, instead of waiting for the 1s tick.
  void FlushPerfReportsForTest();

  std::vector<KeyFingerprint> KeyState() const;

 private:
  // One imported key: raw AES bytes, the 8-byte IV prefix drawn at import,
  // and SHA-256(raw)[:8] for host logs.
  struct RawKeyMaterial {
    std::vector<uint8_t> key;
    std::array<uint8_t, 8> iv_prefix{};
    std::array<uint8_t, 8> fingerprint{};
  };

  bool StoreRawKey(std::string_view participant_id,
                   int key_index,
                   std::vector<uint8_t> key,
                   const std::array<uint8_t, 8>* forced_prefix,
                   bool shared);
  // Decode: per-user (id, index) first, else shared key at that index.
  std::optional<RawKeyMaterial> GetDecryptKey(const std::string& participant_id,
                                              int key_index) const;
  // Encode: latest per-user key, else the active shared key.
  std::optional<std::pair<int, RawKeyMaterial>> GetLatestKey(
      const std::string& participant_id) const;
  // Global send counter. Fails closed at 0xffffffff — make a new manager.
  std::optional<uint32_t> TakeSendCounter();
  bool EncryptFramed(const FrameCryptoInput& in,
                     Buffer& out,
                     FrameCryptionState* state);
  bool DecryptFramed(const FrameCryptoInput& in,
                     Buffer& out,
                     FrameCryptionState* state);
  bool EncryptLegacy(const FrameCryptoInput& in,
                     Buffer& out,
                     FrameCryptionState* state);
  bool DecryptLegacy(const FrameCryptoInput& in,
                     Buffer& out,
                     FrameCryptionState* state);
  Buffer MakeLegacyIv(uint32_t ssrc, uint32_t timestamp);
  uint8_t LegacyIvSize() const;
  bool UsesFrameTrailer() const {
    return algorithm_ == FrameCryptorTransformer::Algorithm::kAesGcmTrailer;
  }
  bool IsDisposed() const;
  void Emit(E2eeEvent event);
  // Host attach prefers the PeerConnection signaling thread (SetFrameTransformer
  // must run there on iOS). Android JNI has no factory pointer, so nullptr
  // falls back to the shared crypto worker.
  Thread* SignalingThreadOrCrypto(Thread* signaling_thread);
  // Count only successful encrypt/decrypt. Encode rows include a codec label;
  // decode rows do not (the trailer does not carry the codec name).
  void RecordPerf(bool encode, const FrameCryptoInput& in, int64_t started_us);
  void FlushPerfReports();
  void SchedulePerfFlush();

  FrameCryptorTransformer::Algorithm algorithm_;
  scoped_refptr<KeyProvider> key_provider_;
  Cipher cipher_ = Cipher::kAes128Gcm;
  size_t expected_key_size_ = 16;
  std::string local_participant_id_;
  scoped_refptr<Observer> observer_;
  TaskQueueBase* notify_queue_ = nullptr;
  bool disposed_ = false;
  mutable Mutex mutex_;
  std::map<std::string, std::map<int, RawKeyMaterial>> raw_keys_;
  std::map<int, RawKeyMaterial> raw_shared_keys_;
  std::map<std::string, int> latest_key_index_;
  std::optional<int> active_shared_key_index_;
  uint32_t send_counter_ = 0;
  std::map<uint32_t, uint32_t> send_counts_;
  // One worker thread for all trailer encrypt/decrypt on this manager.
  std::unique_ptr<Thread> crypto_thread_;
  std::unique_ptr<FrameReplayWindows> replay_windows_;

  // Replay, stall, and encode-fail latch are per (user, track kind), not
  // per RTP SSRC. Audio and video from the same person do not share state.
  struct TrackId {
    std::string participant_id;
    FrameCryptorTransformer::TrackType track_type =
        FrameCryptorTransformer::TrackType::kAudio;
    bool operator<(const TrackId& o) const {
      if (participant_id != o.participant_id)
        return participant_id < o.participant_id;
      return static_cast<int>(track_type) < static_cast<int>(o.track_type);
    }
  };
  struct DecodeTrackState {
    // Consecutive AES failures per key index. At 11 we emit stalled.
    std::map<int, int> fail_counts;
    bool failure_reported = false;
    bool stalled = false;
    // Last time we emitted each throttled event (1s gap).
    std::map<int, std::optional<int64_t>> missing_key_ms;
    std::optional<int64_t> failure_ms;
    std::optional<int64_t> cleartext_ms;
    std::optional<int64_t> version_ms;
  };
  std::map<TrackId, DecodeTrackState> decode_tracks_;
  std::map<TrackId, bool> encode_failed_latched_;
  std::map<std::string, std::optional<int64_t>> encode_missing_key_ms_;

  struct PerfKey {
    std::string participant_id;
    FrameCryptorTransformer::TrackType track_type =
        FrameCryptorTransformer::TrackType::kAudio;
    std::string codec;
    bool operator<(const PerfKey& o) const {
      if (participant_id != o.participant_id)
        return participant_id < o.participant_id;
      if (static_cast<int>(track_type) != static_cast<int>(o.track_type))
        return static_cast<int>(track_type) < static_cast<int>(o.track_type);
      return codec < o.codec;
    }
  };
  struct PerfAccum {
    int count = 0;
    double max_crypto_ms = 0;
  };
  // Relaxed atomic so Encrypt/Decrypt can skip TimeMicros when reporting is off.
  std::atomic<bool> perf_enabled_{false};
  int64_t perf_last_tick_us_ = 0;
  std::map<PerfKey, PerfAccum> encode_perf_;
  std::map<PerfKey, PerfAccum> decode_perf_;
  // Cancels the 1s delayed flush if reporting is turned off or we Dispose.
  scoped_refptr<PendingTaskSafetyFlag> perf_safety_;
};

}  // namespace webrtc

#endif  // API_CRYPTO_DEFAULT_ENCRYPTION_MANAGER_H_
