#ifndef DYNAMIC_PROCESSING_HPP
#define DYNAMIC_PROCESSING_HPP

#include <syslog.h>

#include "modules/audio_processing/audio_buffer.h"
#include "modules/audio_processing/audio_processing_impl.h"
#include "modules/audio_processing/include/audio_processing.h"

namespace external {

class DynamicProcessing : public webrtc::CustomProcessing {
 public:
  DynamicProcessing(const DynamicProcessing&) = delete;
  DynamicProcessing(DynamicProcessing&&) = delete;
  DynamicProcessing& operator=(const DynamicProcessing&) = delete;
  DynamicProcessing& operator=(DynamicProcessing&&) = delete;
  ~DynamicProcessing();

  static DynamicProcessing* getInstance(const char* libname_cstr) {
    if (m_instance == nullptr) {
      m_instance = new DynamicProcessing(libname_cstr);
    }
    return m_instance;
  }

  void Initialize(int sample_rate_hz, int num_channels) override;
  void Process(webrtc::AudioBuffer* audio) override;
  std::string ToString() const override;
  void SetRuntimeSetting(
      webrtc::AudioProcessing::RuntimeSetting setting) override;

 private:
  DynamicProcessing(const char* libname_cstr);

  const char* libname_cstr;

  static DynamicProcessing* m_instance;
};
}  // namespace external

#endif  // DYNAMIC_PROCESSING_HPP
