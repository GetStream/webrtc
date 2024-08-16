#include <syslog.h>

#include <cstring>
#include <exception>
#include <typeinfo>

#include "external_processing.hpp"
#include "extensions/android-external-audio-processing/generated_external_jni/ExternalAudioProcessingFactory_jni.h"
#include "rtc_base/checks.h"
#include "rtc_base/ref_counted_object.h"
#include "rtc_base/thread.h"
#include "rtc_base/time_utils.h"
#include "sdk/android/src/jni/jni_helpers.h"

namespace external {
webrtc::AudioProcessing* apm_ptr;
static jlong JNI_ExternalAudioProcessingFactory_GetAudioProcessingModule(
    JNIEnv* env,
    jlong processor
) {

  ::syslog(LOG_INFO, "EXTERNAL-JNI: #GetAudioProcessingModule; processor: %ld", static_cast<long>(processor));

  // Cast the jlong to ExternalProcessor*
  ExternalProcessor* external_processor = reinterpret_cast<ExternalProcessor*>(processor);

  ::syslog(LOG_INFO, "EXTERNAL-JNI: #GetAudioProcessingModule; external_processor: %p", (void*)external_processor);

  if (external_processor == nullptr) {
    ::syslog(LOG_ERR, "EXTERNAL-JNI: #GetAudioProcessingModule; ExternalProcessor is null!");
    return 0;
  }

  ::syslog(LOG_INFO, "EXTERNAL-JNI: #GetAudioProcessingModule; The class name of external_processor is: %s", typeid(*external_processor).name());

  ::syslog(LOG_INFO, "EXTERNAL-JNI: #GetAudioProcessingModule; Size of ExternalProcessor: %zu", sizeof(*external_processor));

  if (reinterpret_cast<uintptr_t>(external_processor) % alignof(external::ExternalProcessor) != 0) {
    ::syslog(LOG_ERR, "EXTERNAL-JNI: #GetAudioProcessingModule; Misaligned external_processor pointer!");
  }

  void* vtable = *(void**)external_processor;
  ::syslog(LOG_INFO, "EXTERNAL-JNI: #GetAudioProcessingModule; external_processor vtable address: %p", vtable);

  external_processor->Init(28256, 31);

  ::syslog(LOG_INFO, "EXTERNAL-JNI: #GetAudioProcessingModule; external_processor->Init was called");

  std::unique_ptr<webrtc::CustomProcessing> external_processing(
      ExternalProcessing::getInstance(external_processor));
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
