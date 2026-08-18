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

#include "api/crypto/default_encryption_manager.h"

#include <array>
#include <cstdint>
#include <vector>

#include "api/make_ref_counted.h"
#include "rtc_base/thread.h"
#include "test/gtest.h"

namespace webrtc {
namespace {

TEST(DefaultEncryptionManagerFile, EventNamesAndFingerprintHex) {
  using T = DefaultEncryptionManager::E2eeEventType;
  DefaultEncryptionManager::E2eeEvent ev;
  ev.type = T::kMissingKey;
  EXPECT_STREQ(ev.Name(), "e2ee.missing_key");
  ev.type = T::kKeyState;
  EXPECT_STREQ(ev.Name(), "e2ee.key_state");
  ev.type = T::kPerfReport;
  EXPECT_STREQ(ev.Name(), "e2ee.perf_report");

  DefaultEncryptionManager::KeyFingerprint fp;
  fp.fingerprint = {0x00, 0x0f, 0xa0, 0xff, 0x10, 0x2b, 0x3c, 0x4d};
  EXPECT_EQ(fp.Hex(), "000fa0ff102b3c4d");
}

TEST(DefaultEncryptionManagerFile, EmptyLocalIdCannotCreateEncryptor) {
  AutoThread main;
  auto manager = make_ref_counted<DefaultEncryptionManager>();
  EXPECT_EQ(manager->CreateEncryptor(Thread::Current(),
                                     FrameCryptorTransformer::TrackType::kAudio),
            nullptr);
}

TEST(DefaultEncryptionManagerFile, CipherSizeAndDispose) {
  auto aes128 = make_ref_counted<DefaultEncryptionManager>(
      "local", DefaultEncryptionManager::Cipher::kAes128Gcm);
  std::vector<uint8_t> k16(16, 1);
  std::vector<uint8_t> k32(32, 1);
  EXPECT_TRUE(aes128->SetKey("local", 0, k16));
  EXPECT_FALSE(aes128->SetKey("local", 0, k32));
  aes128->Dispose();
  EXPECT_TRUE(aes128->disposed());
  EXPECT_FALSE(aes128->SetKey("local", 0, k16));
}

}  // namespace
}  // namespace webrtc
