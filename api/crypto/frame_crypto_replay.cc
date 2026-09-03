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

#include "api/crypto/frame_crypto_replay.h"

#include <map>

#include "api/crypto/frame_crypto_replay_window.h"

namespace webrtc {

struct FrameReplayWindows::Impl {
  // Replay is per sender + track kind, not SSRC. Simulcast SSRCs from the
  // same camera still share one counter space on the JS worker.
  struct Key {
    std::string participant_id;
    FrameCryptorTransformer::TrackType track_type =
        FrameCryptorTransformer::TrackType::kAudio;
    bool operator<(const Key& o) const {
      if (participant_id != o.participant_id)
        return participant_id < o.participant_id;
      return static_cast<int>(track_type) < static_cast<int>(o.track_type);
    }
  };
  std::map<Key, FrameReplayWindow> windows_;
};

FrameReplayWindows::FrameReplayWindows() : impl_(std::make_unique<Impl>()) {}

FrameReplayWindows::~FrameReplayWindows() = default;

bool FrameReplayWindows::Peek(const std::string& participant_id,
                              FrameCryptorTransformer::TrackType track_type,
                              uint32_t counter,
                              ArrayView<const uint8_t> iv_prefix) {
  // operator[] inserts an empty window the first time we see a track.
  // Peek on an empty window allows an unknown prefix, and does not mark
  // the counter; Commit is what records it, after AES succeeds.
  return impl_->windows_[Impl::Key{participant_id, track_type}].Peek(
      counter, iv_prefix);
}

void FrameReplayWindows::Commit(const std::string& participant_id,
                                FrameCryptorTransformer::TrackType track_type,
                                uint32_t counter,
                                ArrayView<const uint8_t> iv_prefix) {
  impl_->windows_[Impl::Key{participant_id, track_type}].Commit(counter,
                                                                iv_prefix);
}

}  // namespace webrtc
