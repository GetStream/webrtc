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

#ifndef API_CRYPTO_FRAME_CRYPTO_REPLAY_WINDOW_H_
#define API_CRYPTO_FRAME_CRYPTO_REPLAY_WINDOW_H_

#include <cstdint>
#include <vector>

#include "api/array_view.h"
#include "api/crypto/frame_crypto_replay_epoch.h"

namespace webrtc {

// How many iv_prefix epochs we keep for one sender track. A key re-import
// creates a new prefix; we remember the last three so in-flight packets
// from the previous key still decrypt.
constexpr int kReplayMaxEpochs = 3;

// Newest epoch first. Peek does not mutate; Commit is called only after
// AES-GCM succeeds so a failed decrypt cannot burn a counter slot.
class FrameReplayWindow {
 public:
  bool Peek(uint32_t counter, ArrayView<const uint8_t> iv_prefix) const;
  // Inserts a new epoch at the front when the prefix is unseen. Oldest of
  // the three is dropped; Peek of an unknown prefix is allowed.
  void Commit(uint32_t counter, ArrayView<const uint8_t> iv_prefix);

 private:
  const FrameReplayEpoch* Find(ArrayView<const uint8_t> prefix) const;
  FrameReplayEpoch* Find(ArrayView<const uint8_t> prefix);

  std::vector<FrameReplayEpoch> epochs_;
};

}  // namespace webrtc

#endif  // API_CRYPTO_FRAME_CRYPTO_REPLAY_WINDOW_H_
