#ifndef EXTERNAL_PROCESSOR_HPP
#define EXTERNAL_PROCESSOR_HPP

#include <cstdint>

namespace external {

// interface for external processor
class ExternalProcessor {
 public:
  // Initializes the processor with a specific sample rate and number of
  // channels.
  virtual int Init(int sample_rate_hz, int num_channels) = 0;
  // Processes the audio data.
  virtual int ProcessFrame(float* const* channels,
                            size_t num_frames,
                            size_t num_bands,
                            size_t num_channels) = 0;

  virtual ~ExternalProcessor() {}
};

extern "C" ExternalProcessor* CreateExternalProcessorInstance();

extern "C" void DestroyExternalProcessorInstance(ExternalProcessor *instance);

}  // namespace external

#endif  // EXTERNAL_PROCESSOR_HPP
