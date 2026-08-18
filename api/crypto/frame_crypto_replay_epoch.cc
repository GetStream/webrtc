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

#include "api/crypto/frame_crypto_replay_epoch.h"

#include <cstring>

namespace webrtc {

FrameReplayEpoch::FrameReplayEpoch(ArrayView<const uint8_t> prefix,
                                   uint32_t counter)
    : highest_(counter) {
  memcpy(prefix_.data(), prefix.data(), 8);
  Mark(counter);
}

bool FrameReplayEpoch::Accepts(uint32_t counter) const {
  if (counter > highest_) {
    return true;
  }
  // Older than the 1024-wide window: too late, treat as replay.
  if (highest_ >= kReplayWindowSize &&
      counter <= highest_ - kReplayWindowSize) {
    return false;
  }
  return !IsMarked(counter);
}

void FrameReplayEpoch::Record(uint32_t counter) {
  if (counter > highest_) {
    if (counter - highest_ >= kReplayWindowSize) {
      // Jump larger than the window: nothing in the old bitmap is useful.
      bitmap_.fill(0);
    } else {
      // Counters we skipped were never received. Clear those bits so a
      // later packet with a skipped counter can still be accepted.
      for (uint32_t c = highest_ + 1; c < counter; ++c) {
        Clear(c);
      }
    }
    highest_ = counter;
  }
  Mark(counter);
}

std::pair<size_t, uint32_t> FrameReplayEpoch::Slot(uint32_t counter) const {
  // RFC 6479-style circular bitmap: counter maps to one of 1024 bits.
  const uint32_t idx = counter % kReplayWindowSize;
  return {idx >> 5, 1u << (idx & 31)};
}

bool FrameReplayEpoch::IsMarked(uint32_t counter) const {
  const auto [word, mask] = Slot(counter);
  return (bitmap_[word] & mask) != 0;
}

void FrameReplayEpoch::Mark(uint32_t counter) {
  const auto [word, mask] = Slot(counter);
  bitmap_[word] |= mask;
}

void FrameReplayEpoch::Clear(uint32_t counter) {
  const auto [word, mask] = Slot(counter);
  bitmap_[word] &= ~mask;
}

}  // namespace webrtc
