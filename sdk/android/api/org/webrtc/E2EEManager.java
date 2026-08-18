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

package org.webrtc;

import androidx.annotation.Nullable;

/**
 * Attach encrypt/decrypt transforms. {@link EncryptionManager} is the default
 * AES-GCM implementation; a custom class can implement this for a different
 * scheme. Java cannot put this next to EncryptionManager in one file (one
 * public type per file).
 */
public interface E2EEManager {
  void encrypt(RtpSender sender,
      @Nullable String codec,
      @Nullable EncryptionManager.TrackType trackType);
  void decrypt(RtpReceiver receiver,
      String userId,
      @Nullable EncryptionManager.TrackType trackType);
}
