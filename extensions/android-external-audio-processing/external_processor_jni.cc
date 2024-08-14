#include <syslog.h>

#include <cstring>

#include "extensions/android-external-audio-processing/generated_external_jni/ExternalAudioProcessingImpl_jni.h"
#include "external_processor.hpp"
#include "rtc_base/checks.h"
#include "rtc_base/ref_counted_object.h"
#include "rtc_base/thread.h"
#include "rtc_base/time_utils.h"
#include "sdk/android/src/jni/jni_helpers.h"

namespace External {
webrtc::AudioProcessing* apm_ptr;
static jlong JNI_ExternalAudioProcessingImpl_ExternalGetApm(JNIEnv* env) {
  std::unique_ptr<webrtc::CustomProcessing> external_processor(
      ExternalProcessor::getInstance());
  auto apm = webrtc::AudioProcessingBuilder()
                 .SetCapturePostProcessing(std::move(external_processor))
                 .Create();
  webrtc::AudioProcessing::Config config;
  config.echo_canceller.enabled = false;
  config.echo_canceller.mobile_mode = true;
  apm->ApplyConfig(config);
  apm_ptr = apm.release();
  return webrtc::jni::jlongFromPointer(apm_ptr);
}

static void JNI_ExternalAudioProcessingImpl_ExternalDisable(JNIEnv* env,
                                                            jboolean disable) {
  ExternalProcessor::SetBypassFlag(disable);
}

static jboolean JNI_ExternalAudioProcessingImpl_IsExternalDisabled(
    JNIEnv* env) {
  return ExternalProcessor::GetBypassFlag();
}

static void JNI_ExternalAudioProcessingImpl_ExternalInit(
    JNIEnv* env,
    const webrtc::JavaParamRef<jstring>& model) {
  jstring modelName = model.obj();
  const char* ch_name = env->GetStringUTFChars(modelName, nullptr);
  ExternalProcessor::ExternalGlobalInit(ch_name);
  env->ReleaseStringUTFChars(modelName, ch_name);
}

static void JNI_ExternalAudioProcessingImpl_ExternalInitBlob(
    JNIEnv* env,
    const webrtc::JavaParamRef<jbyteArray>& data) {
  jbyteArray jdata = data.obj();
  jsize size = env->GetArrayLength(jdata);

  jbyte* elements = env->GetByteArrayElements(jdata, nullptr);
  unsigned int csize = static_cast<unsigned int>(size);
  char* charArray = new char[csize];
  std::memcpy(charArray, elements, csize);

  ExternalProcessor::ExternalGlobalInitBlob(charArray, csize);

  env->ReleaseByteArrayElements(jdata, elements, JNI_ABORT);
  delete[] charArray;
}
static void JNI_ExternalAudioProcessingImpl_ExternalDestroy(JNIEnv* env) {
  delete apm_ptr;
}

}  // end of namespace External
