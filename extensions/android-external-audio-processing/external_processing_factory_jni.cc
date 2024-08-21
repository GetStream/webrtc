#include <syslog.h>

#include <cstring>

#include "extensions/android-external-audio-processing/generated_external_jni/DynamicAudioProcessingFactory_jni.h"
#include "external_processing.hpp"
#include "rtc_base/checks.h"
#include "rtc_base/ref_counted_object.h"
#include "rtc_base/thread.h"
#include "rtc_base/time_utils.h"
#include "sdk/android/src/jni/jni_helpers.h"

namespace external {
webrtc::AudioProcessing* apm_ptr;
static jlong JNI_ExternalAudioProcessingFactory_CreateAudioProcessingModule(
    JNIEnv* env,
    const webrtc::JavaParamRef<jstring>& libname
) {

  if (libname.is_null()) {
    ::syslog(LOG_ERR, "EXTERNAL-JNI: #GetApm; libname is null");
    return 0;
  }

  const char* libname_cstr = env->GetStringUTFChars(libname.obj(), nullptr);

  ::syslog(LOG_INFO, "EXTERNAL-JNI: #GetApm; libname: %s", libname_cstr);

  // TODO env->ReleaseStringUTFChars(libname.obj(), init_string);

  std::unique_ptr<webrtc::CustomProcessing> external_processing(
      DynamicProcessing::getInstance(libname_cstr));
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
  delete apm_ptr;
}

}  // end of namespace external
