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

#include "api/crypto/frame_crypto_trailer.h"

#include <array>
#include <cstdint>
#include <cstring>
#include <vector>

#include "test/gtest.h"

namespace webrtc {
namespace {

std::array<uint8_t, 8> Prefix() {
  return {1, 2, 3, 4, 5, 6, 7, 8};
}

TEST(FrameCryptoTrailer, WriteThenReadRoundTrip) {
  // Parser requires clear_bytes <= payload before the 20-byte trailer.
  std::vector<uint8_t> frame(12 + kFrameTrailerLen);
  WriteFrameTrailer(frame.data() + 12, 0x01020304, Prefix(), 9, 12, true);
  auto t = ReadFrameTrailer(frame);
  ASSERT_TRUE(t);
  EXPECT_EQ(t->frame_counter, 0x01020304u);
  EXPECT_EQ(t->iv_prefix, Prefix());
  EXPECT_EQ(t->key_index, 9);
  EXPECT_EQ(t->clear_bytes, 12);
  EXPECT_TRUE(t->is_rbsp);
  EXPECT_EQ(ReadFramingVersion(frame), kFrameTrailerVersion);
}

TEST(FrameCryptoTrailer, RbspFlagOffWhenNotH264) {
  std::vector<uint8_t> frame(3 + kFrameTrailerLen);
  WriteFrameTrailer(frame.data() + 3, 1, Prefix(), 0, 3, false);
  auto t = ReadFrameTrailer(frame);
  ASSERT_TRUE(t);
  EXPECT_FALSE(t->is_rbsp);
  EXPECT_EQ(t->clear_bytes, 3);
}

std::vector<uint8_t> Framed(size_t body,
                            uint16_t clear_bytes,
                            uint8_t version = kFrameTrailerVersion) {
  std::vector<uint8_t> frame(body + kFrameTrailerLen, 0x99);
  WriteFrameTrailer(frame.data() + body, 1, Prefix(), 0, clear_bytes, false);
  frame[frame.size() - 5] = version;
  return frame;
}

TEST(FrameCryptoTrailer, RejectsTooShortBadMagicWrongVersionAndOversizeClear) {
  EXPECT_FALSE(ReadFrameTrailer({}));
  EXPECT_FALSE(ReadFramingVersion({}));

  uint8_t buf[kFrameTrailerLen];
  WriteFrameTrailer(buf, 1, Prefix(), 0, 0, false);
  buf[kFrameTrailerLen - 1] ^= 0xff;
  EXPECT_FALSE(ReadFrameTrailer(buf));
  EXPECT_FALSE(ReadFramingVersion(buf));

  WriteFrameTrailer(buf, 1, Prefix(), 0, 0, false);
  buf[15] = 2;
  EXPECT_FALSE(ReadFrameTrailer(buf));
  EXPECT_EQ(ReadFramingVersion(buf), 2);

  // Trailer-only buffer: any non-zero clear_bytes is larger than the payload.
  WriteFrameTrailer(buf, 1, Prefix(), 0, 1, false);
  EXPECT_FALSE(ReadFrameTrailer(buf));
  // Magic+version still match. Decode uses that to pick unencrypted vs
  // unsupported-version, not "drop as corrupt framed".
  EXPECT_EQ(ReadFramingVersion(buf), kFrameTrailerVersion);
}

TEST(FrameCryptoTrailer, IdentSuffixIsLastFiveBytes) {
  // Frozen across versions: an older receiver finds us from these 5 bytes
  // alone. Literals on purpose — reading them from the constants would
  // move with a layout break.
  auto frame = Framed(5, 0);
  EXPECT_EQ(frame[frame.size() - 5], 1);
  EXPECT_EQ(frame[frame.size() - 4], 0xe2);
  EXPECT_EQ(frame[frame.size() - 3], 0xee);
  EXPECT_EQ(frame[frame.size() - 2], 0xfe);
  EXPECT_EQ(frame[frame.size() - 1], 0xed);
  EXPECT_EQ(ReadFramingVersion(frame), 1);
}

TEST(FrameCryptoTrailer, OversizeClearBytesIsNotATrailerButVersionStillReads) {
  // Body is 5 bytes; trailer claims 6. Inside the 15-bit field, so only the
  // length check rejects it. JS readTrailer returns null; readFramingVersion
  // still returns 1, and decode forwards as unencrypted.
  auto frame = Framed(5, 6);
  EXPECT_FALSE(ReadFrameTrailer(frame));
  EXPECT_EQ(ReadFramingVersion(frame), kFrameTrailerVersion);

  // Same with the RBSP flag set: suffix is independent of that high bit.
  std::vector<uint8_t> rbsp(5 + kFrameTrailerLen, 0x99);
  WriteFrameTrailer(rbsp.data() + 5, 1, Prefix(), 0, 6, true);
  EXPECT_FALSE(ReadFrameTrailer(rbsp));
  EXPECT_EQ(ReadFramingVersion(rbsp), kFrameTrailerVersion);
}

TEST(FrameCryptoTrailer, ClearBytesEqualToBodyParses) {
  auto frame = Framed(5, 5);
  auto t = ReadFrameTrailer(frame);
  ASSERT_TRUE(t);
  EXPECT_EQ(t->clear_bytes, 5);
  EXPECT_FALSE(t->is_rbsp);
}

TEST(FrameCryptoTrailer, FutureVersionReadableWhenParseFails) {
  auto frame = Framed(5, 0, 99);
  EXPECT_EQ(ReadFramingVersion(frame), 99);
  EXPECT_FALSE(ReadFrameTrailer(frame));
}

TEST(FrameCryptoTrailer, GrownFutureTrailerStillReadsSuffixFromEnd) {
  // Simulate a v2 trailer with 4 extra bytes ahead of the frozen suffix.
  auto src = Framed(5, 0);
  std::vector<uint8_t> grown(src.size() + 4, 0);
  memcpy(grown.data(), src.data(), src.size() - 5);
  memcpy(grown.data() + grown.size() - 5, src.data() + src.size() - 5, 5);
  grown[grown.size() - 5] = 2;
  EXPECT_EQ(ReadFramingVersion(grown), 2);
  EXPECT_FALSE(ReadFrameTrailer(grown));
}

TEST(FrameCryptoTrailer, MagicMismatchIsNotOurs) {
  auto frame = Framed(5, 0);
  frame.back() ^= 0x01;
  EXPECT_FALSE(ReadFramingVersion(frame));
  EXPECT_FALSE(ReadFrameTrailer(frame));
  EXPECT_FALSE(ReadFramingVersion(std::vector<uint8_t>(4, 0)));
}

TEST(FrameCryptoTrailer, FillFrameIvIsPrefixThenBigEndianCounter) {
  uint8_t iv[12];
  FillFrameIv(iv, Prefix(), 0x01020304);
  EXPECT_EQ(0, memcmp(iv, Prefix().data(), 8));
  EXPECT_EQ(iv[8], 0x01);
  EXPECT_EQ(iv[9], 0x02);
  EXPECT_EQ(iv[10], 0x03);
  EXPECT_EQ(iv[11], 0x04);
}

TEST(FrameCryptoTrailer, UnescapedFieldsRereadCounterPrefixKeyIndex) {
  std::vector<uint8_t> unit(4 + kFrameTrailerLen, 0xaa);
  WriteFrameTrailer(unit.data() + 4, 42, Prefix(), 7, 0, false);
  auto fields = ReadUnescapedTrailerFields(unit);
  ASSERT_TRUE(fields);
  EXPECT_EQ(fields->frame_counter, 42u);
  EXPECT_EQ(fields->iv_prefix, Prefix());
  EXPECT_EQ(fields->key_index, 7);
  EXPECT_FALSE(ReadUnescapedTrailerFields({}));
}

}  // namespace
}  // namespace webrtc
