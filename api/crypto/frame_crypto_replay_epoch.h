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

#ifndef API_CRYPTO_FRAME_CRYPTO_REPLAY_EPOCH_H_
#define API_CRYPTO_FRAME_CRYPTO_REPLAY_EPOCH_H_

#include <array>
#include <cstddef>
#include <cstdint>
#include <utility>

#include "api/array_view.h"

namespace webrtc {

// How many recent counters we remember for one iv_prefix. A packet older
// than this, or a duplicate inside this range, is dropped as a replay.
constexpr uint32_t kReplayWindowSize = 1024;
constexpr size_t kReplayWindowWords = kReplayWindowSize / 32;

// One key import. The 8-byte iv_prefix is drawn when the key is set; if
// the same user re-imports the key, they get a new prefix and a new epoch.
// Bitmap bit i means "we already accepted the counter that maps to slot i".
class FrameReplayEpoch {
 public:
  FrameReplayEpoch(ArrayView<const uint8_t> prefix, uint32_t counter);

  ArrayView<const uint8_t> prefix() const { return prefix_; }

  // true = this counter has not been seen (or is ahead of highest_).
  bool Accepts(uint32_t counter) const;
  // Mark counter as used. If it jumps ahead, skipped slots are cleared
  // so a late packet in the gap can still be accepted.
  void Record(uint32_t counter);

 private:
  std::pair<size_t, uint32_t> Slot(uint32_t counter) const;
  bool IsMarked(uint32_t counter) const;
  void Mark(uint32_t counter);
  void Clear(uint32_t counter);

  std::array<uint8_t, 8> prefix_{};
  uint32_t highest_ = 0;
  std::array<uint32_t, kReplayWindowWords> bitmap_{};
};

}  // namespace webrtc

#endif  // API_CRYPTO_FRAME_CRYPTO_REPLAY_EPOCH_H_
