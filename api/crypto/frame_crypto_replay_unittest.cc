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

#include <array>
#include <cstdint>

#include "test/gtest.h"

namespace webrtc {
namespace {

std::array<uint8_t, 8> Prefix() {
  return {9, 9, 9, 9, 9, 9, 9, 9};
}

TEST(FrameReplayWindows, IsolatesParticipantAndTrackType) {
  FrameReplayWindows windows;
  auto p = Prefix();
  windows.Commit("alice", FrameCryptorTransformer::TrackType::kAudio, 1, p);
  EXPECT_FALSE(windows.Peek("alice", FrameCryptorTransformer::TrackType::kAudio,
                            1, p));
  EXPECT_TRUE(windows.Peek("alice", FrameCryptorTransformer::TrackType::kVideo,
                           1, p));
  EXPECT_TRUE(windows.Peek("bob", FrameCryptorTransformer::TrackType::kAudio, 1,
                           p));
}

TEST(FrameReplayWindows, ScreenshareIsNotVideo) {
  FrameReplayWindows windows;
  auto p = Prefix();
  windows.Commit("alice", FrameCryptorTransformer::TrackType::kVideo, 3, p);
  EXPECT_TRUE(windows.Peek(
      "alice", FrameCryptorTransformer::TrackType::kScreenshare, 3, p));
}

}  // namespace
}  // namespace webrtc
