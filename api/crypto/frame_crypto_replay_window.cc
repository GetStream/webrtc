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

#include "api/crypto/frame_crypto_replay_window.h"

#include <cstring>

namespace webrtc {
namespace {

bool PrefixEqual(ArrayView<const uint8_t> a, ArrayView<const uint8_t> b) {
  return a.size() == b.size() && memcmp(a.data(), b.data(), a.size()) == 0;
}

}  // namespace

bool FrameReplayWindow::Peek(uint32_t counter,
                             ArrayView<const uint8_t> iv_prefix) const {
  const FrameReplayEpoch* epoch = Find(iv_prefix);
  // Unknown prefix: first packet after a key change is always allowed.
  return epoch ? epoch->Accepts(counter) : true;
}

void FrameReplayWindow::Commit(uint32_t counter,
                               ArrayView<const uint8_t> iv_prefix) {
  if (FrameReplayEpoch* epoch = Find(iv_prefix)) {
    epoch->Record(counter);
    return;
  }
  // Newest prefix first. A relay cannot invent prefixes to evict a real
  // epoch because we only get here after GCM authenticated the frame.
  epochs_.insert(epochs_.begin(), FrameReplayEpoch(iv_prefix, counter));
  if (epochs_.size() > static_cast<size_t>(kReplayMaxEpochs)) {
    epochs_.pop_back();
  }
}

const FrameReplayEpoch* FrameReplayWindow::Find(
    ArrayView<const uint8_t> prefix) const {
  for (const auto& epoch : epochs_) {
    if (PrefixEqual(epoch.prefix(), prefix)) {
      return &epoch;
    }
  }
  return nullptr;
}

FrameReplayEpoch* FrameReplayWindow::Find(ArrayView<const uint8_t> prefix) {
  // Same scan as the const overload; non-const callers need a mutable epoch.
  return const_cast<FrameReplayEpoch*>(
      static_cast<const FrameReplayWindow*>(this)->Find(prefix));
}

}  // namespace webrtc
