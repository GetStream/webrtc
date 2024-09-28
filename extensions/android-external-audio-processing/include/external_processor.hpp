#ifndef EXTERNAL_PROCESSOR_HPP
#define EXTERNAL_PROCESSOR_HPP

#include <cstdint>
#include <array>

namespace external {

static constexpr unsigned int kFunctionCount = 4;

// Function ID struct
struct FunctionId {
  static constexpr unsigned int ExternalProcessorCreate = 0;
  static constexpr unsigned int ExternalProcessorInitialize = 1;
  static constexpr unsigned int ExternalProcessorProcessFrame = 2;
  static constexpr unsigned int ExternalProcessorDestroy = 3;
};

static constexpr std::array<const char *, kFunctionCount> kFunctionNames =
    {
        "ExternalProcessorCreate",
        "ExternalProcessorInitialize",
        "ExternalProcessorProcessFrame",
        "ExternalProcessorDestroy"
};

// Function type definitions
using ExternalProcessorCreateFuncType = bool(*)();
using ExternalProcessorInitializeFuncType = bool(*)(int sample_rate_hz, int num_channels);
using ExternalProcessorProcessFrameFuncType = bool(*)(float* const* channels,
                                                       size_t num_frames,
                                                       size_t num_bands,
                                                       size_t num_channels);
using ExternalProcessorDestroyFuncType = bool(*)();

extern "C" bool ExternalProcessorCreate();

extern "C" bool ExternalProcessorInitialize(int sample_rate_hz,
                                            int num_channels);

extern "C" bool ExternalProcessorProcessFrame(float* const* channels,
                                              size_t num_frames,
                                              size_t num_bands,
                                              size_t num_channels);

extern "C" bool ExternalProcessorDestroy();

}  // namespace external

#endif  // EXTERNAL_PROCESSOR_HPP
