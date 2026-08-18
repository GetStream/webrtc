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

#include <optional>
#include <string>
#include <vector>

#include "api/array_view.h"
#include "api/crypto/default_encryption_manager.h"
#include "api/make_ref_counted.h"
#include "api/media_types.h"
#include "api/rtp_receiver_interface.h"
#include "api/rtp_sender_interface.h"
#include "api/scoped_refptr.h"
#include "rtc_base/thread.h"
#include "sdk/android/generated_peerconnection_jni/EncryptionManager_jni.h"
#include "sdk/android/native_api/jni/java_types.h"
#include "sdk/android/src/jni/jni_helpers.h"
#include "sdk/android/src/jni/jvm.h"

namespace webrtc {
namespace jni {
namespace {

DefaultEncryptionManager::Cipher CipherFromIndex(int algorithm) {
  return algorithm == 1 ? DefaultEncryptionManager::Cipher::kAes256Gcm
                        : DefaultEncryptionManager::Cipher::kAes128Gcm;
}

FrameCryptorTransformer::TrackType TrackTypeFromIndex(int track_type) {
  return static_cast<FrameCryptorTransformer::TrackType>(track_type);
}

bool TrackTypeOk(int track_type) {
  return track_type >= 0 && track_type <= 3;
}

FrameCryptorTransformer::TrackType ResolveTrackType(int track_type,
                                                    MediaType media) {
  // -1 (and any other out-of-range value that passed the JNI guard) means
  // "default from RTP": audio sender → kAudio, video sender → kVideo.
  if (TrackTypeOk(track_type)) {
    return TrackTypeFromIndex(track_type);
  }
  return media == MediaType::AUDIO ? FrameCryptorTransformer::TrackType::kAudio
                                   : FrameCryptorTransformer::TrackType::kVideo;
}

std::vector<uint8_t> KeyBytes(JNIEnv* env,
                              const JavaParamRef<jbyteArray>& j_key) {
  std::vector<int8_t> raw = JavaToNativeByteArray(env, j_key);
  return std::vector<uint8_t>(raw.begin(), raw.end());
}

ScopedJavaLocalRef<jobject> NativeToJavaKeyState(
    JNIEnv* env,
    const std::vector<DefaultEncryptionManager::KeyFingerprint>& keys) {
  std::vector<DefaultEncryptionManager::KeyFingerprint> per_user;
  std::vector<DefaultEncryptionManager::KeyFingerprint> shared;
  for (const auto& fp : keys) {
    if (fp.shared) {
      shared.push_back(fp);
    } else {
      per_user.push_back(fp);
    }
  }
  auto j_per_user = NativeToJavaList(env, per_user, [](JNIEnv* e, const auto& fp) {
    return Java_UserKey_Constructor(e, NativeToJavaString(e, fp.participant_id),
                                    fp.key_index,
                                    NativeToJavaString(e, fp.Hex()));
  });
  auto j_shared = NativeToJavaList(env, shared, [](JNIEnv* e, const auto& fp) {
    return Java_SharedKey_Constructor(e, fp.key_index,
                                      NativeToJavaString(e, fp.Hex()),
                                      fp.active_shared);
  });
  return Java_KeyStateReport_Constructor(env, j_per_user, j_shared);
}

ScopedJavaLocalRef<jobject> NativeToJavaE2eeEvent(
    JNIEnv* env,
    const DefaultEncryptionManager::E2eeEvent& event) {
  ScopedJavaLocalRef<jobject> j_type =
      Java_E2eeEventType_fromNativeIndex(env, static_cast<int>(event.type));
  ScopedJavaLocalRef<jobject> j_track;
  if (event.track_type) {
    j_track = Java_TrackType_fromNativeIndex(
        env, static_cast<int>(*event.track_type));
  }
  std::optional<int32_t> key_index;
  if (event.key_index) {
    key_index = *event.key_index;
  }
  std::optional<int32_t> version;
  if (event.version) {
    version = *event.version;
  }
  ScopedJavaLocalRef<jstring> j_reason;
  if (!event.reason.empty()) {
    j_reason = NativeToJavaString(env, event.reason);
  }
  ScopedJavaLocalRef<jobject> j_key_state;
  if (event.type == DefaultEncryptionManager::E2eeEventType::kKeyState) {
    j_key_state = NativeToJavaKeyState(env, event.key_state);
  }
  ScopedJavaLocalRef<jobject> j_encode;
  ScopedJavaLocalRef<jobject> j_decode;
  if (event.type == DefaultEncryptionManager::E2eeEventType::kPerfReport) {
    auto make_perf = [](JNIEnv* e, const DefaultEncryptionManager::TrackPerf& p,
                        bool with_codec) {
      ScopedJavaLocalRef<jstring> j_codec;
      // Decode samples leave codec null; encode samples keep the pin/label.
      if (with_codec && !p.codec.empty()) {
        j_codec = NativeToJavaString(e, p.codec);
      }
      return Java_TrackPerf_Constructor(
          e, NativeToJavaString(e, p.participant_id),
          Java_TrackType_fromNativeIndex(e, static_cast<int>(p.track_type)),
          j_codec, p.fps, p.max_crypto_ms);
    };
    j_encode = NativeToJavaList(
        env, event.encode_perf,
        [&](JNIEnv* e, const auto& p) { return make_perf(e, p, true); });
    j_decode = NativeToJavaList(
        env, event.decode_perf,
        [&](JNIEnv* e, const auto& p) { return make_perf(e, p, false); });
  }
  return Java_E2eeEvent_Constructor(
      env, j_type, NativeToJavaString(env, event.participant_id), j_track,
      NativeToJavaInteger(env, key_index), NativeToJavaInteger(env, version),
      j_reason, j_key_state, j_encode, j_decode);
}

class EncryptionManagerObserverJni
    : public DefaultEncryptionManager::Observer {
 public:
  EncryptionManagerObserverJni(JNIEnv* jni, const JavaRef<jobject>& j_observer)
      : j_observer_global_(jni, j_observer) {}

  void OnE2eeEvent(
      const DefaultEncryptionManager::E2eeEvent& event) override {
    // This runs on the crypto worker. The Java observer must hop to the
    // UI thread itself if it updates views.
    JNIEnv* env = AttachCurrentThreadIfNeeded();
    ScopedLocalRefFrame local_ref_scope(env);
    Java_Observer_onE2eeEvent(env, j_observer_global_,
                              NativeToJavaE2eeEvent(env, event));
  }

 private:
  const ScopedJavaGlobalRef<jobject> j_observer_global_;
};

DefaultEncryptionManager* NativeManager(jlong pointer) {
  return reinterpret_cast<DefaultEncryptionManager*>(pointer);
}

}  // namespace

static jlong JNI_EncryptionManager_Create(
    JNIEnv* env,
    const JavaParamRef<jstring>& j_user_id,
    jint j_algorithm) {
  if (j_user_id.is_null()) {
    return 0;
  }
  std::string user_id = JavaToNativeString(env, j_user_id);
  if (user_id.empty()) {
    return 0;
  }
  auto manager = make_ref_counted<DefaultEncryptionManager>(
      std::move(user_id), CipherFromIndex(j_algorithm));
  return jlongFromPointer(manager.release());
}

static jboolean JNI_EncryptionManager_SetKey(
    JNIEnv* env,
    jlong native_manager,
    const JavaParamRef<jstring>& j_user_id,
    jint j_key_index,
    const JavaParamRef<jbyteArray>& j_key) {
  auto* manager = NativeManager(native_manager);
  if (!manager || j_user_id.is_null() || j_key.is_null()) {
    return false;
  }
  auto key = KeyBytes(env, j_key);
  return manager->SetKey(JavaToNativeString(env, j_user_id), j_key_index, key);
}

static jboolean JNI_EncryptionManager_SetSharedKey(
    JNIEnv* env,
    jlong native_manager,
    jint j_key_index,
    const JavaParamRef<jbyteArray>& j_key) {
  auto* manager = NativeManager(native_manager);
  if (!manager || j_key.is_null()) {
    return false;
  }
  auto key = KeyBytes(env, j_key);
  return manager->SetSharedKey(j_key_index, key);
}

static void JNI_EncryptionManager_RemoveKey(
    JNIEnv* env,
    jlong native_manager,
    const JavaParamRef<jstring>& j_user_id,
    jint j_key_index) {
  auto* manager = NativeManager(native_manager);
  if (!manager || j_user_id.is_null()) {
    return;
  }
  manager->RemoveKey(JavaToNativeString(env, j_user_id), j_key_index);
}

static void JNI_EncryptionManager_RemoveAllKeys(
    JNIEnv* env,
    jlong native_manager,
    const JavaParamRef<jstring>& j_user_id) {
  auto* manager = NativeManager(native_manager);
  if (!manager || j_user_id.is_null()) {
    return;
  }
  manager->RemoveAllKeys(JavaToNativeString(env, j_user_id));
}

static void JNI_EncryptionManager_RemoveSharedKey(JNIEnv* env,
                                                  jlong native_manager,
                                                  jint j_key_index) {
  auto* manager = NativeManager(native_manager);
  if (!manager) {
    return;
  }
  manager->RemoveSharedKey(j_key_index);
}

static jboolean JNI_EncryptionManager_Encrypt(
    JNIEnv* env,
    jlong native_manager,
    jlong native_sender,
    const JavaParamRef<jstring>& j_codec,
    jint j_track_type) {
  auto* manager = NativeManager(native_manager);
  auto* sender = reinterpret_cast<RtpSenderInterface*>(native_sender);
  if (!manager || !sender) {
    return false;
  }
  if (j_track_type != -1 && !TrackTypeOk(j_track_type)) {
    return false;
  }
  std::optional<std::string> codec;
  if (!j_codec.is_null()) {
    codec = JavaToNativeString(env, j_codec);
  }
  // No factory on the Java object. Crypto still serializes on the manager
  // worker; nullptr here only skips the iOS signaling-thread hop.
  scoped_refptr<FrameCryptorTransformer> cryptor = manager->CreateEncryptor(
      nullptr, ResolveTrackType(j_track_type, sender->media_type()), codec);
  if (!cryptor) {
    return false;
  }
  sender->SetFrameTransformer(cryptor);
  return true;
}

static jboolean JNI_EncryptionManager_Decrypt(
    JNIEnv* env,
    jlong native_manager,
    jlong native_receiver,
    const JavaParamRef<jstring>& j_user_id,
    jint j_track_type) {
  auto* manager = NativeManager(native_manager);
  auto* receiver = reinterpret_cast<RtpReceiverInterface*>(native_receiver);
  if (!manager || !receiver || j_user_id.is_null()) {
    return false;
  }
  if (j_track_type != -1 && !TrackTypeOk(j_track_type)) {
    return false;
  }
  std::string user_id = JavaToNativeString(env, j_user_id);
  // Same as encrypt: no factory, so the transformer uses crypto_task_queue().
  scoped_refptr<FrameCryptorTransformer> cryptor = manager->CreateDecryptor(
      nullptr, user_id,
      ResolveTrackType(j_track_type, receiver->media_type()));
  if (!cryptor) {
    return false;
  }
  receiver->SetFrameTransformer(cryptor);
  return true;
}

static jboolean JNI_EncryptionManager_EnablePerformanceReporting(
    JNIEnv* env,
    jlong native_manager,
    jboolean enabled) {
  auto* manager = NativeManager(native_manager);
  if (!manager) {
    return false;
  }
  return manager->EnablePerformanceReporting(enabled);
}

static void JNI_EncryptionManager_RequestKeyState(JNIEnv* env,
                                                  jlong native_manager) {
  auto* manager = NativeManager(native_manager);
  if (!manager) {
    return;
  }
  manager->RequestKeyState();
}

static jlong JNI_EncryptionManager_SetObserver(
    JNIEnv* env,
    jlong native_manager,
    const JavaParamRef<jobject>& j_observer) {
  auto* manager = NativeManager(native_manager);
  if (!manager) {
    return 0;
  }
  if (j_observer.is_null()) {
    manager->SetObserver(nullptr);
    return 0;
  }
  auto observer =
      make_ref_counted<EncryptionManagerObserverJni>(env, j_observer);
  // Extra ref held until Java calls dispose / replaces the observer.
  observer->AddRef();
  manager->SetObserver(observer);
  return jlongFromPointer(observer.get());
}

static void JNI_EncryptionManager_Dispose(JNIEnv* env, jlong native_manager) {
  auto* manager = NativeManager(native_manager);
  if (!manager) {
    return;
  }
  manager->SetObserver(nullptr);
  manager->Dispose();
  manager->Release();
}

}  // namespace jni
}  // namespace webrtc
