#include <syslog.h>

#include <cstring>

#include "extensions/android-external-audio-processing/generated_external_jni/ExternalAudioProcessingFactory_jni.h"
#include "external_processing.hpp"
#include "rtc_base/checks.h"
#include "rtc_base/ref_counted_object.h"
#include "rtc_base/thread.h"
#include "rtc_base/time_utils.h"
#include "sdk/android/src/jni/jni_helpers.h"

namespace external {

webrtc::AudioProcessing* apm_ptr = nullptr;

static jlong JNI_ExternalAudioProcessingFactory_CreateAudioProcessingModule(
    JNIEnv* env,
    const webrtc::JavaParamRef<jstring>& libnameRef
) {

  if (libnameRef.is_null()) {
    ::syslog(LOG_ERR, "EXTERNAL-JNI: #GetApm; libname is null");
    return 0;
  }

  const char* libname = env->GetStringUTFChars(libnameRef.obj(), nullptr);

  ::syslog(LOG_INFO, "EXTERNAL-JNI: #GetApm; libname: %s", libname);

  auto instance = ExternalProcessing::getInstance();
  if (!instance->Load(libname)) {
    ::syslog(LOG_ERR, "EXTERNAL-JNI: #GetApm; Failed to load external processor");
    env->ReleaseStringUTFChars(libnameRef.obj(), libname);
    return 0;
  }

  env->ReleaseStringUTFChars(libnameRef.obj(), libname);

  std::unique_ptr<webrtc::CustomProcessing> external_processing(instance);
  auto apm = webrtc::AudioProcessingBuilder()
                 .SetCapturePostProcessing(std::move(external_processing))
                 .Create();
  webrtc::AudioProcessing::Config config;
  config.echo_canceller.enabled = false;
  config.echo_canceller.mobile_mode = true;
  apm->ApplyConfig(config);
  apm_ptr = apm.release();
  return webrtc::jni::jlongFromPointer(apm_ptr);
}

static void JNI_ExternalAudioProcessingFactory_DestroyAudioProcessingModule(
    JNIEnv* env
) {
  ExternalProcessing::getInstance()->Destroy();
  delete apm_ptr;
  apm_ptr = nullptr;
}

}  // end of namespace external
