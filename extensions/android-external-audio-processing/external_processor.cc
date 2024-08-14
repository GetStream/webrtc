#include "external_processor.hpp"

#include <syslog.h>

#include "rtc_base/logging.h"
#include "rtc_base/time_utils.h"

namespace External {

ExternalProcessor* ExternalProcessor::m_instance = nullptr;

ExternalProcessor::ExternalProcessor() {}

ExternalProcessor::~ExternalProcessor() {
  ::syslog(LOG_INFO, "EXTERNAL-CIT: External Global Destroy");
}

void ExternalProcessor::Reset(int new_rate) {
  ::syslog(LOG_INFO, "EXTERNAL-CIT: ExternalProcessor Reset new_rate: %i",
           new_rate);
}

void ExternalProcessor::Initialize(int sample_rate_hz, int num_channels) {
  ::syslog(LOG_INFO,
           "EXTERNAL-CIT: ExternalProcessor Init sample_rate_hz: %i\
             num_channels: %i",
           sample_rate_hz, num_channels);
}
void ExternalProcessor::Process(webrtc::AudioBuffer* audio) {
  ::syslog(LOG_INFO, "EXTERNAL-CIT: ExternalProcessor Process");
}

std::string ExternalProcessor::ToString() const {
  return "ExternalProcessor";
}

void ExternalProcessor::SetRuntimeSetting(
    webrtc::AudioProcessing::RuntimeSetting setting) {
  ::syslog(LOG_INFO, "EXTERNAL-CIT: ExternalProcessor SetRuntimeSetting");
}

}  // end of namespace External
