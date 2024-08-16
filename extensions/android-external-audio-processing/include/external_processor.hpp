#ifndef EXTERNAL_PROCESSOR_HPP
#define EXTERNAL_PROCESSOR_HPP

#include <cstdint>

namespace external {

// interface for external processor
class ExternalProcessor {
 public:
  // Initializes the processor with a specific sample rate and number of
  // channels.
  virtual void Init(int sample_rate_hz, int num_channels) = 0;
  // Processes the audio data.
  virtual void ProcessFrame(float* const* channels,
                            size_t num_frames,
                            size_t num_bands,
                            size_t num_channels) = 0;

  virtual ~ExternalProcessor() {}
};
}  // namespace external

#endif  // EXTERNAL_PROCESSOR_HPP
