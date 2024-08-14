#include "external_processing.hpp"

#include <syslog.h>

#include "rtc_base/logging.h"
#include "rtc_base/time_utils.h"

namespace External {

ExternalProcessing* ExternalProcessing::m_instance = nullptr;

ExternalProcessing::ExternalProcessing() {}

ExternalProcessing::~ExternalProcessing() {
  ::syslog(LOG_INFO, "EXTERNAL-CIT: External Global Destroy");
}

void ExternalProcessing::Reset(int new_rate) {
  ::syslog(LOG_INFO, "EXTERNAL-CIT: ExternalProcessing Reset new_rate: %i",
           new_rate);
}

void ExternalProcessing::Initialize(int sample_rate_hz, int num_channels) {
  ::syslog(LOG_INFO,
           "EXTERNAL-CIT: ExternalProcessing Init sample_rate_hz: %i\
             num_channels: %i",
           sample_rate_hz, num_channels);
}
void ExternalProcessing::Process(webrtc::AudioBuffer* audio) {
  ::syslog(LOG_INFO, "EXTERNAL-CIT: ExternalProcessing Process");
}

std::string ExternalProcessing::ToString() const {
  return "ExternalProcessing";
}

void ExternalProcessing::SetRuntimeSetting(
    webrtc::AudioProcessing::RuntimeSetting setting) {
  ::syslog(LOG_INFO, "EXTERNAL-CIT: ExternalProcessing SetRuntimeSetting");
}

}  // end of namespace External
