#include "dynamic_processing.hpp"

#include <dlfcn.h>
#include <syslog.h>

#include "rtc_base/time_utils.h"

namespace external {

DynamicProcessing* DynamicProcessing::m_instance = nullptr;

DynamicProcessing::DynamicProcessing(const char* libname_cstr)
    : libname_cstr(libname_cstr) {
  ::syslog(LOG_INFO, "EXTERNAL-CIT: DynamicProcessing #Constructor;");
}

DynamicProcessing::~DynamicProcessing() {
  ::syslog(LOG_INFO, "EXTERNAL-CIT: DynamicProcessing #Destructor;");
}

void DynamicProcessing::Initialize(int sample_rate_hz, int num_channels) {
  ::syslog(LOG_INFO,
           "EXTERNAL-CIT: DynamicProcessing #Initialize; sample_rate_hz: %i, "
           "num_channels: %i",
           sample_rate_hz, num_channels);


  dlerror();
  auto libPath = env->GetStringUTFChars(libname_cstr, nullptr);
  ::syslog(LOG_INFO, "EXTERNAL-CIT: #Initialize; libPath: %s", libPath);
  void *_dllHandle = dlopen(libPath, RTLD_LAZY);
  if (!_dllHandle) {
    ::syslog(LOG_ERR, "EXTERNAL-CIT: #Initialize; Failed to load the library = %s\n", libPath);
    return;
  }

  const unsigned int _functionCount = 2;

  std::array<const char *, _functionCount> _functionNames =
      {
          "Init",
          "ProcessFrame"
      };

  std::array<void *, _functionCount> _functionPointers = {};

  for (size_t functionId = 0; functionId < _functionCount; ++functionId)
  {
    const char * functionName = _functionNames[functionId];
    ::syslog(LOG_INFO,"EXTERNAL-CIT: #Initialize; Loading function: %s", functionName);
    void * functionPtr = dlsym(_dllHandle, functionName);
    const char* dlsym_error = dlerror();
    if (dlsym_error) {
      ::syslog(LOG_ERR, "EXTERNAL-CIT: #Initialize; Failed to load the function: %s", dlsym_error);
      return;
    }
    _functionPointers[functionId] = functionPtr;
  }

  // get anotherGlobalGetGreeting function pointer
  void* InitPtr = _functionPointers[0];

  if (InitPtr == nullptr) {
    syslog(LOG_ERR, "EXTERNAL-CIT: #Initialize; Failed to get the Init function");
    return;
  }

  using InitFuncType = int(*)(int, int);
  // using ProcessFrameFuncType = int(*)(float* const*, size_t, size_t, size_t);

  auto InitFunc = reinterpret_cast<InitFuncType>(InitPtr);

  int result = InitFunc(sample_rate_hz, num_channels);
  if (result != 0) {
    ::syslog(LOG_ERR, "KrispLib: #Load; Failed to initialize Krisp globals");
    return;
  }
  ::syslog(LOG_INFO, "EXTERNAL-CIT: #Initialize; Krisp globals initialized successfully");
}

void DynamicProcessing::Process(webrtc::AudioBuffer* audio) {
  ::syslog(LOG_INFO, "EXTERNAL-CIT: DynamicProcessing #Process;");
  float* const* channels = audio->channels();
  size_t num_frames = audio->num_frames();
  size_t num_bands = audio->num_bands();
  size_t num_channels = audio->num_channels();
}

std::string DynamicProcessing::ToString() const {
  return "DynamicProcessing";
}

void DynamicProcessing::SetRuntimeSetting(
    webrtc::AudioProcessing::RuntimeSetting setting) {
  ::syslog(LOG_INFO, "EXTERNAL-CIT: DynamicProcessing #SetRuntimeSetting;");
}

}  // end of namespace external
