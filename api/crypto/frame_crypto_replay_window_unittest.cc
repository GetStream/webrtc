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

TEST(FrameReplayWindow, UnknownPrefixIsAllowedUntilCommit) {
  FrameReplayWindow w;
  auto a = Prefix(1);
  EXPECT_TRUE(w.Peek(1, a));
  w.Commit(1, a);
  EXPECT_FALSE(w.Peek(1, a));
  EXPECT_TRUE(w.Peek(2, a));
}

TEST(FrameReplayWindow, NewPrefixStartsANewEpoch) {
  FrameReplayWindow w;
  auto a = Prefix(1);
  auto b = Prefix(2);
  w.Commit(5, a);
  EXPECT_FALSE(w.Peek(5, a));
  EXPECT_TRUE(w.Peek(5, b));
  w.Commit(5, b);
  EXPECT_FALSE(w.Peek(5, b));
  EXPECT_FALSE(w.Peek(5, a));
}

TEST(FrameReplayWindow, KeepsThreeEpochsThenDropsOldest) {
  FrameReplayWindow w;
  auto a = Prefix(1);
  auto b = Prefix(2);
  auto c = Prefix(3);
  auto d = Prefix(4);
  w.Commit(1, a);
  w.Commit(1, b);
  w.Commit(1, c);
  EXPECT_FALSE(w.Peek(1, a));
  w.Commit(1, d);
  // A was the oldest of four; unknown prefix is allowed again.
  EXPECT_TRUE(w.Peek(1, a));
  EXPECT_FALSE(w.Peek(1, b));
  EXPECT_FALSE(w.Peek(1, c));
  EXPECT_FALSE(w.Peek(1, d));
}

}  // namespace
}  // namespace webrtc
