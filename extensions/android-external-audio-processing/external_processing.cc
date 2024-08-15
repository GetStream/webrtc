#include "external_processing.hpp"

#include <syslog.h>

#include "include/external_processor.hpp"
#include "rtc_base/logging.h"
#include "rtc_base/time_utils.h"

namespace External {

ExternalProcessing* ExternalProcessing::m_instance = nullptr;

ExternalProcessing::ExternalProcessing(ExternalProcessor* processor)
    : external_processor(processor) {}

ExternalProcessing::~ExternalProcessing() {
  ::syslog(LOG_INFO, "EXTERNAL-CIT: External Global Destroy");
}

void ExternalProcessing::Initialize(int sample_rate_hz, int num_channels) {
  ::syslog(LOG_INFO,
           "EXTERNAL-CIT: ExternalProcessing Init sample_rate_hz: %i\
             num_channels: %i",
           sample_rate_hz, num_channels);
  if (external_processor == nullptr) {
    ::syslog(LOG_INFO, "EXTERNAL-CIT: external_processor is null");
    return;
  }
  external_processor->Init(sample_rate_hz, num_channels);
}

void ExternalProcessing::Process(webrtc::AudioBuffer* audio) {
  ::syslog(LOG_INFO, "EXTERNAL-CIT: ExternalProcessing Process");
  float* const* channels = audio->channels();
  size_t num_frames = audio->num_frames();
  size_t num_bands = audio->num_bands();
  size_t num_channels = audio->num_channels();
  if (external_processor == nullptr) {
    ::syslog(LOG_INFO, "EXTERNAL-CIT: external_processor is null");
    return;
  }
  external_processor->ProcessFrame(channels, num_frames, num_bands, num_channels);
}

std::string ExternalProcessing::ToString() const {
  return "ExternalProcessing";
}

void ExternalProcessing::SetRuntimeSetting(
    webrtc::AudioProcessing::RuntimeSetting setting) {
  ::syslog(LOG_INFO, "EXTERNAL-CIT: ExternalProcessing SetRuntimeSetting");
}

}  // end of namespace External
