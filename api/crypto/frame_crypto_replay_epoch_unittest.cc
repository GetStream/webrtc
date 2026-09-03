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

#include <array>
#include <cstdint>

#include "test/gtest.h"

namespace webrtc {
namespace {

std::array<uint8_t, 8> Prefix(uint8_t tag) {
  std::array<uint8_t, 8> p{};
  p[0] = tag;
  return p;
}

TEST(FrameReplayEpoch, DuplicateAndAhead) {
  FrameReplayEpoch epoch(Prefix(1), 10);
  EXPECT_EQ(epoch.prefix()[0], 1);
  EXPECT_FALSE(epoch.Accepts(10));
  EXPECT_TRUE(epoch.Accepts(11));
  epoch.Record(11);
  EXPECT_FALSE(epoch.Accepts(11));
  EXPECT_TRUE(epoch.Accepts(12));
}

TEST(FrameReplayEpoch, GapCanBeFilledLater) {
  FrameReplayEpoch epoch(Prefix(1), 5);
  epoch.Record(8);
  // 6 and 7 were skipped, so they are still allowed.
  EXPECT_TRUE(epoch.Accepts(6));
  EXPECT_TRUE(epoch.Accepts(7));
  EXPECT_FALSE(epoch.Accepts(5));
  EXPECT_FALSE(epoch.Accepts(8));
  epoch.Record(6);
  EXPECT_FALSE(epoch.Accepts(6));
}

TEST(FrameReplayEpoch, JumpLargerThanWindowForgetsOldCounters) {
  FrameReplayEpoch epoch(Prefix(1), 11);
  epoch.Record(11 + kReplayWindowSize);
  // 11 is now at the back edge of the window and is too old.
  EXPECT_FALSE(epoch.Accepts(11));
  // Bitmap was cleared, so a counter still inside the window is allowed.
  EXPECT_TRUE(epoch.Accepts(12));
}

}  // namespace
}  // namespace webrtc
