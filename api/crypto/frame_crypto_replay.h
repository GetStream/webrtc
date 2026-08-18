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

#ifndef API_CRYPTO_FRAME_CRYPTO_REPLAY_H_
#define API_CRYPTO_FRAME_CRYPTO_REPLAY_H_

#include <cstdint>
#include <memory>
#include <string>

#include "api/array_view.h"
#include "api/crypto/frame_crypto_transformer.h"

namespace webrtc {

// One FrameReplayWindow per (sender user id, track kind). Audio and video
// from the same person do not share replay state. The manager only sees
// this type; epoch and window live in their own files.
class FrameReplayWindows {
 public:
  FrameReplayWindows();
  ~FrameReplayWindows();

  FrameReplayWindows(const FrameReplayWindows&) = delete;
  FrameReplayWindows& operator=(const FrameReplayWindows&) = delete;

  // true = this counter is not a known replay. Does not consume the slot.
  bool Peek(const std::string& participant_id,
            FrameCryptorTransformer::TrackType track_type,
            uint32_t counter,
            ArrayView<const uint8_t> iv_prefix);
  // Record the counter only after AES-GCM succeeds. Peek must have passed.
  void Commit(const std::string& participant_id,
              FrameCryptorTransformer::TrackType track_type,
              uint32_t counter,
              ArrayView<const uint8_t> iv_prefix);

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace webrtc

#endif  // API_CRYPTO_FRAME_CRYPTO_REPLAY_H_
