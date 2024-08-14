#include "modules/audio_processing/audio_buffer.h"
#include "modules/audio_processing/audio_processing_impl.h"
#include "modules/audio_processing/include/audio_processing.h"

namespace External {

class ExternalProcessor : public webrtc::CustomProcessing {
 public:
  ExternalProcessor(const ExternalProcessor&) = delete;
  ExternalProcessor(ExternalProcessor&&) = delete;
  ExternalProcessor& operator=(const ExternalProcessor&) = delete;
  ExternalProcessor& operator=(ExternalProcessor&&) = delete;
  ~ExternalProcessor();

  static ExternalProcessor* getInstance() {
    if (m_instance == nullptr) {
      m_instance = new ExternalProcessor();
    }
    return m_instance;
  }

  void Reset(int new_rate);
  void Initialize(int sample_rate_hz, int num_channels) override;
  void Process(webrtc::AudioBuffer* audio) override;
  std::string ToString() const override;
  void SetRuntimeSetting(
      webrtc::AudioProcessing::RuntimeSetting setting) override;

 private:
  ExternalProcessor();

  static ExternalProcessor* m_instance;
};
}  // namespace External
