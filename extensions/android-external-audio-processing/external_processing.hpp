#ifndef DYNAMIC_PROCESSING_HPP
#define DYNAMIC_PROCESSING_HPP

#include <syslog.h>

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

  static ExternalProcessing* getInstance(const char* libname_cstr) {
    if (m_instance == nullptr) {
      m_instance = new ExternalProcessing(libname_cstr);
    }
    return m_instance;
  }

  void Initialize(int sample_rate_hz, int num_channels) override;
  void Process(webrtc::AudioBuffer* audio) override;
  std::string ToString() const override;
  void SetRuntimeSetting(
      webrtc::AudioProcessing::RuntimeSetting setting) override;

 private:
  ExternalProcessing(const char* libname_cstr);

  const char* libname_cstr;

  static ExternalProcessing* m_instance;
};
}  // namespace external

#endif  // DYNAMIC_PROCESSING_HPP
