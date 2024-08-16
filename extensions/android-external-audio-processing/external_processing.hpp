#ifndef EXTERNAL_PROCESSING_HPP
#define EXTERNAL_PROCESSING_HPP

#include <syslog.h>

#include "include/external_processor.hpp"
#include "modules/audio_processing/audio_buffer.h"
#include "modules/audio_processing/audio_processing_impl.h"
#include "modules/audio_processing/include/audio_processing.h"

namespace external {

class ExternalProcessing : public webrtc::CustomProcessing {
 public:
  ExternalProcessing(const ExternalProcessing&) = delete;
  ExternalProcessing(ExternalProcessing&&) = delete;
  ExternalProcessing& operator=(const ExternalProcessing&) = delete;
  ExternalProcessing& operator=(ExternalProcessing&&) = delete;
  ~ExternalProcessing();

  static ExternalProcessing* getInstance(ExternalProcessor* processor) {
    ::syslog(LOG_INFO, "EXTERNAL-HPP: ExternalProcessing #getInstance; processor: %p", (void*)processor);
    if (m_instance == nullptr) {
      m_instance = new ExternalProcessing(processor);
    }
    ::syslog(LOG_INFO, "EXTERNAL-HPP: ExternalProcessing #getInstance; m_instance: %p", (void*)m_instance);
    return m_instance;
  }

  void Initialize(int sample_rate_hz, int num_channels) override;
  void Process(webrtc::AudioBuffer* audio) override;
  std::string ToString() const override;
  void SetRuntimeSetting(
      webrtc::AudioProcessing::RuntimeSetting setting) override;

 private:
  ExternalProcessing(ExternalProcessor* processor);

  ExternalProcessor* external_processor;

  static ExternalProcessing* m_instance;
};
}  // namespace external

#endif  // EXTERNAL_PROCESSING_HPP
