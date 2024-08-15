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
webrtc::AudioProcessing* apm_ptr;
static jlong JNI_ExternalAudioProcessingFactory_GetAudioProcessingModule(
    JNIEnv* env,
    jlong native_external_processor,
) {

  // Cast the jlong to ExternalProcessor*
  ExternalProcessor* external_processor = reinterpret_cast<ExternalProcessor*>(native_external_processor);


  std::unique_ptr<webrtc::CustomProcessing> external_processing(
      ExternalProcessing::getInstance());
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

}  // end of namespace external
