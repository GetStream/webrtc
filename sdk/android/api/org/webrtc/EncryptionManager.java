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
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

/**
 * JS {@code EncryptionManager}: one object holds keys and attaches
 * encrypt/decrypt transforms. LiveKit {@link FrameCryptor} is a different API
 * and is unchanged.
 */
public class EncryptionManager implements E2EEManager {
  /** AES-GCM key size. Default is AES-128. */
  public enum Algorithm {
    AES_128_GCM(0),
    AES_256_GCM(1);

    private final int value;

    Algorithm(int value) {
      this.value = value;
    }

    public int getValue() {
      return value;
    }
  }

  /**
   * JS worker {@code trackType} (protobuf TrackType names). Optional on
   * encrypt/decrypt: omitted values default to audio vs video from the RTP
   * sender or receiver. Pass screenshare explicitly so replay stays per track.
   */
  public enum TrackType {
    AUDIO(0),
    VIDEO(1),
    SCREEN_SHARE(2),
    SCREEN_SHARE_AUDIO(3);

    private final int value;

    TrackType(int value) {
      this.value = value;
    }

    public int getValue() {
      return value;
    }

    @CalledByNative("TrackType")
    static TrackType fromNativeIndex(int nativeIndex) {
      return values()[nativeIndex];
    }
  }

  /** Event names such as {@code e2ee.missing_key}. */
  public enum E2eeEventType {
    DECRYPTION_FAILED(0, "e2ee.decryption_failed"),
    DECRYPTION_RESUMED(1, "e2ee.decryption_resumed"),
    DECRYPTION_STALLED(2, "e2ee.decryption_stalled"),
    ENCRYPTION_FAILED(3, "e2ee.encryption_failed"),
    MISSING_KEY(4, "e2ee.missing_key"),
    UNENCRYPTED_FRAME(5, "e2ee.unencrypted_frame"),
    UNSUPPORTED_VERSION(6, "e2ee.unsupported_version"),
    KEY_STATE(7, "e2ee.key_state"),
    PERF_REPORT(8, "e2ee.perf_report");

    public final String name;
    private final int value;

    E2eeEventType(int value, String name) {
      this.value = value;
      this.name = name;
    }

    public int getValue() {
      return value;
    }

    @CalledByNative("E2eeEventType")
    static E2eeEventType fromNativeIndex(int nativeIndex) {
      return values()[nativeIndex];
    }
  }

  public static class UserKey {
    public final String userId;
    public final int keyIndex;
    /** Hex of SHA-256(rawKey)[:8]. Never key material. */
    public final String fingerprint;

    @CalledByNative("UserKey")
    UserKey(String userId, int keyIndex, String fingerprint) {
      this.userId = userId;
      this.keyIndex = keyIndex;
      this.fingerprint = fingerprint;
    }
  }

  public static class SharedKey {
    public final int keyIndex;
    public final String fingerprint;
    public final boolean isActive;

    @CalledByNative("SharedKey")
    SharedKey(int keyIndex, String fingerprint, boolean isActive) {
      this.keyIndex = keyIndex;
      this.fingerprint = fingerprint;
      this.isActive = isActive;
    }
  }

  /** JS {@code e2ee.key_state} payload. */
  public static class KeyStateReport {
    public final List<UserKey> perUserKeys;
    public final List<SharedKey> sharedKeys;

    @CalledByNative("KeyStateReport")
    KeyStateReport(List<UserKey> perUserKeys, List<SharedKey> sharedKeys) {
      this.perUserKeys = Collections.unmodifiableList(new ArrayList<>(perUserKeys));
      this.sharedKeys = Collections.unmodifiableList(new ArrayList<>(sharedKeys));
    }
  }

  /** One row of {@code e2ee.perf_report}. {@code codec} is set on encode samples only. */
  public static class TrackPerf {
    public final String userId;
    public final TrackType trackType;
    @Nullable public final String codec;
    public final double fps;
    public final double maxCryptoMs;

    @CalledByNative("TrackPerf")
    TrackPerf(String userId, TrackType trackType, @Nullable String codec, double fps,
        double maxCryptoMs) {
      this.userId = userId;
      this.trackType = trackType;
      this.codec = codec;
      this.fps = fps;
      this.maxCryptoMs = maxCryptoMs;
    }
  }

  public static class E2eeEvent {
    public final E2eeEventType type;
    public final String name;
    public final String userId;
    @Nullable public final TrackType trackType;
    @Nullable public final Integer keyIndex;
    @Nullable public final Integer version;
    @Nullable public final String reason;
    @Nullable public final KeyStateReport keyState;
    @Nullable public final List<TrackPerf> encode;
    @Nullable public final List<TrackPerf> decode;

    @CalledByNative("E2eeEvent")
    E2eeEvent(E2eeEventType type, String userId, @Nullable TrackType trackType,
        @Nullable Integer keyIndex, @Nullable Integer version, @Nullable String reason,
        @Nullable KeyStateReport keyState, @Nullable List<TrackPerf> encode,
        @Nullable List<TrackPerf> decode) {
      this.type = type;
      this.name = type.name;
      this.userId = userId;
      this.trackType = trackType;
      this.keyIndex = keyIndex;
      this.version = version;
      this.reason = reason;
      this.keyState = keyState;
      this.encode = encode == null ? null : Collections.unmodifiableList(new ArrayList<>(encode));
      this.decode = decode == null ? null : Collections.unmodifiableList(new ArrayList<>(decode));
    }
  }

  public interface Observer {
    @CalledByNative("Observer")
    void onE2eeEvent(E2eeEvent event);
  }

  private final String userId;
  private final Algorithm algorithm;
  private long nativeManager;
  private long observerPtr;

  public static boolean isSupported() {
    // Browsers gate on Encoded Transform + secure context. Native always has
    // the insertable-transform path, so this is always true.
    return true;
  }

  public static EncryptionManager create(String userId) {
    return new EncryptionManager(userId, Algorithm.AES_128_GCM);
  }

  /** Matches JS {@code create(userId, algorithm)}. Keys live on this object. */
  public static EncryptionManager create(String userId, Algorithm algorithm) {
    return new EncryptionManager(userId, algorithm);
  }

  public EncryptionManager(String userId) {
    this(userId, Algorithm.AES_128_GCM);
  }

  public EncryptionManager(String userId, Algorithm algorithm) {
    if (userId == null || userId.isEmpty()) {
      throw new IllegalArgumentException("userId");
    }
    if (algorithm == null) {
      throw new NullPointerException("algorithm");
    }
    long nativeManager = nativeCreate(userId, algorithm.getValue());
    if (nativeManager == 0) {
      throw new IllegalStateException("Failed to create EncryptionManager");
    }
    this.userId = userId;
    this.algorithm = algorithm;
    this.nativeManager = nativeManager;
  }

  public String userId() {
    return userId;
  }

  public Algorithm algorithm() {
    return algorithm;
  }

  public boolean isDisposed() {
    return nativeManager == 0;
  }

  public void setKey(String userId, int keyIndex, byte[] rawKey) {
    checkUsable();
    validateKeyIndex(keyIndex);
    validateKey(rawKey);
    if (!nativeSetKey(nativeManager, userId, keyIndex, rawKey)) {
      throw new IllegalStateException("setKey failed");
    }
  }

  public void setSharedKey(int keyIndex, byte[] rawKey) {
    checkUsable();
    validateKeyIndex(keyIndex);
    validateKey(rawKey);
    if (!nativeSetSharedKey(nativeManager, keyIndex, rawKey)) {
      throw new IllegalStateException("setSharedKey failed");
    }
  }

  public void removeKey(String userId, int keyIndex) {
    checkUsable();
    validateKeyIndex(keyIndex);
    nativeRemoveKey(nativeManager, userId, keyIndex);
  }

  public void removeAllKeys(String userId) {
    checkUsable();
    nativeRemoveAllKeys(nativeManager, userId);
  }

  public void removeSharedKey(int keyIndex) {
    checkUsable();
    validateKeyIndex(keyIndex);
    nativeRemoveSharedKey(nativeManager, keyIndex);
  }

  public void encrypt(RtpSender sender) {
    // No codec pin, no screenshare override: audio vs video from the sender.
    encrypt(sender, null, null);
  }

  @Override
  public void encrypt(RtpSender sender, @Nullable String codec, @Nullable TrackType trackType) {
    checkUsable();
    if (sender == null) {
      throw new NullPointerException("sender");
    }
    // -1 tells JNI to pick audio vs video from the sender's media type.
    // Screenshare must still be passed so replay stays on its own window.
    int track = trackType == null ? -1 : trackType.getValue();
    if (!nativeEncrypt(nativeManager, sender.getNativeRtpSender(), codec, track)) {
      throw new IllegalStateException("failed to attach encrypt transform");
    }
  }

  public void decrypt(RtpReceiver receiver, String userId) {
    decrypt(receiver, userId, null);
  }

  @Override
  public void decrypt(RtpReceiver receiver, String userId, @Nullable TrackType trackType) {
    checkUsable();
    if (receiver == null) {
      throw new NullPointerException("receiver");
    }
    if (userId == null || userId.isEmpty()) {
      throw new IllegalArgumentException("userId");
    }
    // Same sentinel as encrypt: omitted trackType → audio vs video from RTP.
    int track = trackType == null ? -1 : trackType.getValue();
    if (!nativeDecrypt(nativeManager, receiver.getNativeRtpReceiver(), userId, track)) {
      throw new IllegalStateException("failed to attach decrypt transform");
    }
  }

  public void enablePerformanceReporting(boolean enabled) {
    checkUsable();
    if (!nativeEnablePerformanceReporting(nativeManager, enabled)) {
      throw new IllegalStateException("enablePerformanceReporting failed");
    }
  }

  public void requestKeyState() {
    checkUsable();
    nativeRequestKeyState(nativeManager);
  }

  public void setObserver(@Nullable Observer observer) {
    checkUsable();
    long newPtr = nativeSetObserver(nativeManager, observer);
    if (observerPtr != 0) {
      JniCommon.nativeReleaseRef(observerPtr);
    }
    observerPtr = newPtr;
  }

  public void dispose() {
    if (nativeManager == 0) {
      return;
    }
    nativeDispose(nativeManager);
    nativeManager = 0;
    if (observerPtr != 0) {
      JniCommon.nativeReleaseRef(observerPtr);
      observerPtr = 0;
    }
  }

  private void checkUsable() {
    if (nativeManager == 0) {
      throw new IllegalStateException("EncryptionManager is disposed");
    }
  }

  private void validateKeyIndex(int keyIndex) {
    if (keyIndex < 0 || keyIndex > 255) {
      throw new IllegalArgumentException(
          "keyIndex must be an integer between 0 and 255, got " + keyIndex);
    }
  }

  private void validateKey(byte[] rawKey) {
    if (rawKey == null) {
      throw new NullPointerException("rawKey");
    }
    int expected = algorithm == Algorithm.AES_256_GCM ? 32 : 16;
    if (rawKey.length != expected) {
      throw new IllegalArgumentException("Key must be exactly " + expected + " bytes ("
          + (algorithm == Algorithm.AES_256_GCM ? "AES-256" : "AES-128") + ")");
    }
  }

  private static native long nativeCreate(String userId, int algorithm);
  private static native boolean nativeSetKey(
      long nativeManager, String userId, int keyIndex, byte[] rawKey);
  private static native boolean nativeSetSharedKey(
      long nativeManager, int keyIndex, byte[] rawKey);
  private static native void nativeRemoveKey(long nativeManager, String userId, int keyIndex);
  private static native void nativeRemoveAllKeys(long nativeManager, String userId);
  private static native void nativeRemoveSharedKey(long nativeManager, int keyIndex);
  private static native boolean nativeEncrypt(
      long nativeManager, long nativeSender, String codec, int trackType);
  private static native boolean nativeDecrypt(
      long nativeManager, long nativeReceiver, String userId, int trackType);
  private static native boolean nativeEnablePerformanceReporting(
      long nativeManager, boolean enabled);
  private static native void nativeRequestKeyState(long nativeManager);
  private static native long nativeSetObserver(long nativeManager, Observer observer);
  private static native void nativeDispose(long nativeManager);
}
