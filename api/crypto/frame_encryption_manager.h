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

#ifndef API_CRYPTO_FRAME_ENCRYPTION_MANAGER_H_
#define API_CRYPTO_FRAME_ENCRYPTION_MANAGER_H_

#include <cstdint>
#include <optional>
#include <string>
#include <string_view>

#include "api/array_view.h"
#include "api/crypto/frame_crypto_transformer.h"
#include "api/ref_count.h"
#include "api/task_queue/task_queue_base.h"
#include "api/video/video_codec_type.h"
#include "rtc_base/buffer.h"
#include "rtc_base/system/rtc_export.h"

namespace webrtc {

// One media frame plus the metadata needed to encrypt or decrypt it.
// `data` is the codec payload (not the RTP header). `track_type` is the
// product kind (audio / video / screenshare) used for replay and events.
// `key_index` is ignored on the trailer encode path (we always use the
// latest key). LiveKit legacy encode still reads it.
struct FrameCryptoInput {
  ArrayView<const uint8_t> data;
  FrameCryptorTransformer::MediaType media_type =
      FrameCryptorTransformer::MediaType::kAudioFrame;
  FrameCryptorTransformer::TrackType track_type =
      FrameCryptorTransformer::TrackType::kAudio;
  std::optional<VideoCodecType> video_codec;
  // Optional encode-side codec pin from encrypt(sender, codec). When set,
  // it overrides `video_codec` (JS worker does this at attach). Decode
  // never sets it; the trailer is self-describing.
  std::optional<std::string> codec_name;
  bool is_keyframe = false;
  uint32_t ssrc = 0;
  uint32_t rtp_timestamp = 0;
  int key_index = 0;
  std::string_view participant_id;
};

// Injected into FrameCryptorTransformer. Integrators implement this (or use
// DefaultEncryptionManager) and pass the instance in; keys live here, not on
// the transformer.
class RTC_EXPORT EncryptionManager : public RefCountInterface {
 public:
  // false → transformer must not deliver the frame to the sink.
  // On true, `out` is the payload to put on the frame.
  virtual bool Encrypt(const FrameCryptoInput& in,
                       Buffer& out,
                       FrameCryptionState* state) = 0;
  virtual bool Decrypt(const FrameCryptoInput& in,
                       Buffer& out,
                       FrameCryptionState* state) = 0;

  // Key bytes are owned by the manager. Index 0–255; size 16 or 32 for the
  // default JS implementation. Custom managers may impose their own rules.
  virtual bool SetKey(std::string_view participant_id,
                      int key_index,
                      ArrayView<const uint8_t> key) = 0;
  virtual bool SetSharedKey(int key_index, ArrayView<const uint8_t> key) = 0;
  virtual void RemoveKey(std::string_view /*participant_id*/,
                         int /*key_index*/) {}
  virtual void RemoveSharedKey(int /*key_index*/) {}
  virtual void RemoveAllKeys(std::string_view /*participant_id*/) {}

  // Shared sequencing queue. Trailer encrypt/decrypt for every sender and
  // receiver on this manager run here so counters and replay stay consistent.
  // nullptr → transformer starts its own thread (LiveKit path).
  virtual TaskQueueBase* crypto_task_queue() { return nullptr; }

 protected:
  ~EncryptionManager() override = default;
};

}  // namespace webrtc

#endif  // API_CRYPTO_FRAME_ENCRYPTION_MANAGER_H_
