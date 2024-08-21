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

  static ExternalProcessing* getInstance() {
    if (m_instance == nullptr) {
      m_instance = new ExternalProcessing();
    }
    return m_instance;
  }

  bool Create(const char* libname);

  bool Destroy();

  void Initialize(int sample_rate_hz, int num_channels) override;
  void Process(webrtc::AudioBuffer* audio) override;
  std::string ToString() const override;
  void SetRuntimeSetting(
      webrtc::AudioProcessing::RuntimeSetting setting) override;

 private:
  ExternalProcessing();

  void* m_handle = nullptr;
  ExternalProcessor* m_processor = nullptr;

  static ExternalProcessing* m_instance;
};
}  // namespace external

#endif  // EXTERNAL_PROCESSING_HPP
