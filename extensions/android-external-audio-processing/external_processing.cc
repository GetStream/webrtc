#include "external_processing.hpp"

#include <dlfcn.h>
#include <syslog.h>

#include "rtc_base/time_utils.h"

namespace external {

ExternalProcessing* ExternalProcessing::m_instance = nullptr;

ExternalProcessing::ExternalProcessing() {
  ::syslog(LOG_INFO, "ExternalProcessing: #Constructor;");
}

ExternalProcessing::~ExternalProcessing() {
  ::syslog(LOG_INFO, "ExternalProcessing: #Destructor;");

  Destroy();
}

bool ExternalProcessing::Create(const char* libname) {
  ::syslog(LOG_INFO, "ExternalProcessing: #Create; libname: %s", libname);

  // Load the shared library
  dlerror();  // Clear any existing errors
  void* handle = dlopen(libname, RTLD_LAZY);
  if (!handle) {
    ::syslog(LOG_ERR, "ExternalProcessing: #Create; Failed to load library: %s",
             dlerror());
    return false;
  }

  // Load external processor functions
  for (size_t functionId = 0; functionId < kFunctionCount; ++functionId) {
    const char* functionName = kFunctionNames[functionId];
    syslog(LOG_INFO, "ExternalProcessing: #Create; Loading function: %s",
           functionName);
    void* functionPtr = dlsym(handle, functionName);
    const char* dlsym_error = dlerror();
    if (dlsym_error) {
      syslog(LOG_ERR,
             "ExternalProcessing: #Create; Failed to load the function: %s",
             dlsym_error);
      return false;
    }
    m_functionPointers[functionId] = functionPtr;
  }

  void* createPtr = m_functionPointers[FunctionId::ExternalProcessorCreate];
  if (!createPtr) {
    ::syslog(LOG_ERR,
             "ExternalProcessing: #Create; Failed to access "
             "ExternalProcessorCreate function");
    dlclose(handle);
    return false;
  }

  auto createFunc =
      reinterpret_cast<ExternalProcessorCreateFuncType>(createPtr);
  if (!createFunc()) {
    ::syslog(LOG_ERR,
             "ExternalProcessing: #Create; Failed to invoke "
             "ExternalProcessorCreate function");
    dlclose(handle);
    return false;
  }

  m_handle = handle;

  ::syslog(LOG_INFO, "ExternalProcessing: #Create; completed successfully");

  return true;
}

bool ExternalProcessing::Destroy() {
  ::syslog(LOG_INFO, "ExternalProcessing: #Destroy;");

  void* destroyPtr = m_functionPointers[FunctionId::ExternalProcessorDestroy];
  if (destroyPtr) {
    ::syslog(LOG_INFO,
             "ExternalProcessing: #Destroy; Invoke ExternalProcessorDestroy "
             "function");

    auto destroyFunc =
        reinterpret_cast<ExternalProcessorDestroyFuncType>(destroyPtr);
    if (destroyFunc()) {
      ::syslog(LOG_INFO,
               "ExternalProcessing: #Destroy; Invoked ExternalProcessorDestroy "
               "successfully");
    }
  }
  for (auto& functionPtr : m_functionPointers) {
    functionPtr = nullptr;
  }
  if (m_handle) {
    dlclose(m_handle);
    m_handle = nullptr;
  }

  return true;
}

void ExternalProcessing::Initialize(int sample_rate_hz, int num_channels) {
  if (m_functionPointers.size() <=
      static_cast<size_t>(FunctionId::ExternalProcessorInitialize)) {
    ::syslog(LOG_ERR,
             "ExternalProcessing: #Initialize; m_functionPointers is not large "
             "enough");
    return;
  }
  void* initializePtr =
      m_functionPointers[FunctionId::ExternalProcessorInitialize];
  if (!initializePtr) {
    ::syslog(LOG_ERR,
             "ExternalProcessing: #Initialize; Failed to access "
             "ExternalProcessorInitialize function");
    return;
  }

  auto initializeFunc =
      reinterpret_cast<ExternalProcessorInitializeFuncType>(initializePtr);
  if (!initializeFunc(sample_rate_hz, num_channels)) {
    ::syslog(LOG_ERR,
             "ExternalProcessing: #Initialize; Failed to invoke "
             "ExternalProcessorInitialize function");
    return;
  }
  ::syslog(LOG_INFO,
           "ExternalProcessing: #Initialize; Invoked "
           "ExternalProcessorInitialize; sample_rate_hz: %i, "
           "num_channels: %i",
           sample_rate_hz, num_channels);
}

void ExternalProcessing::Process(webrtc::AudioBuffer* audio) {
  float* const* channels = audio->channels();
  size_t num_frames = audio->num_frames();
  size_t num_bands = audio->num_bands();
  size_t num_channels = audio->num_channels();

  if (m_functionPointers.size() <=
      static_cast<size_t>(FunctionId::ExternalProcessorProcessFrame)) {
    ::syslog(
        LOG_ERR,
        "ExternalProcessing: #Process; m_functionPointers is not large enough");
    return;
  }
  void* processPtr =
      m_functionPointers[FunctionId::ExternalProcessorProcessFrame];
  if (!processPtr) {
    ::syslog(LOG_ERR,
             "ExternalProcessing: #Process; Failed to access "
             "ExternalProcessorProcessFrame function");
    return;
  }

  auto processFunc =
      reinterpret_cast<ExternalProcessorProcessFrameFuncType>(processPtr);
  if (!processFunc(channels, num_frames, num_bands, num_channels)) {
    ::syslog(LOG_ERR,
             "ExternalProcessing: #Process; Failed to invoke "
             "ExternalProcessorProcessFrame function");
    return;
  }
  ::syslog(LOG_INFO,
           "ExternalProcessing: #Process; Invoked "
           "ExternalProcessorProcessFrame; num_frames: %zu, num_bands: %zu, "
           "num_channels: %zu",
           num_frames, num_bands, num_channels);
}

std::string ExternalProcessing::ToString() const {
  return "ExternalProcessing";
}

void ExternalProcessing::SetRuntimeSetting(
    webrtc::AudioProcessing::RuntimeSetting setting) {
  ::syslog(LOG_INFO, "EXTERNAL-CIT: ExternalProcessing #SetRuntimeSetting;");
}

}  // end of namespace external
