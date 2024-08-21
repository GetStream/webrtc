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
    ::syslog(LOG_ERR, "ExternalProcessing: #Create; Failed to load library: %s", dlerror());
    return false;
  }

  // Load the factory function for creating the ExternalProcessor instance
  auto createInstance = (external::ExternalProcessor* (*)())dlsym(handle, "CreateExternalProcessorInstance");
  const char* dlsymError = dlerror();
  if (dlsymError) {
    ::syslog(LOG_ERR, "ExternalProcessing: #Create; Failed to load createInstance function: %s", dlsymError);
    dlclose(handle);
    return false;
  }

  // Create the ExternalProcessor instance
  external::ExternalProcessor* processor = createInstance();
  if (!processor) {
    ::syslog(LOG_ERR, "ExternalProcessing: #Create; Failed to create ExternalProcessor instance");
    dlclose(handle);
    return false;
  }

  m_handle = handle;
  m_processor = processor;

  if (!m_processor->Create()) {
    ::syslog(LOG_ERR, "ExternalProcessing: #Create; Failed to initialize ExternalProcessor instance");
    Destroy();
  }

  ::syslog(LOG_INFO, "ExternalProcessing: #Create; Created ExternalProcessor instance");

  return true;
}

bool ExternalProcessing::Destroy() {
  ::syslog(LOG_INFO, "ExternalProcessing: #Destroy;");

  if (m_processor) {
    if (!m_processor->Destroy()) {
      syslog(LOG_ERR, "ExternalProcessing: #Destroy; Failed to destroy ExternalProcessor instance");
    }
    delete m_processor;
    m_processor = nullptr;
  }
  if (m_handle) {
    dlclose(m_handle);
    m_handle = nullptr;
  }

  return true;
}

void ExternalProcessing::Initialize(int sample_rate_hz, int num_channels) {
  if (!m_processor) {
    ::syslog(LOG_ERR, "ExternalProcessing: #Initialize; Processor not initialized");
    return;
  }
  ::syslog(LOG_INFO,
           "ExternalProcessing: #Initialize; sample_rate_hz: %i, "
           "num_channels: %i",
           sample_rate_hz, num_channels);
  m_processor->Init(sample_rate_hz, num_channels);
}

void ExternalProcessing::Process(webrtc::AudioBuffer* audio) {
  float* const* channels = audio->channels();
  size_t num_frames = audio->num_frames();
  size_t num_bands = audio->num_bands();
  size_t num_channels = audio->num_channels();
  if (!m_processor) {
    ::syslog(LOG_ERR, "ExternalProcessing: #Process; Processor not initialized");
    return;
  }
  ::syslog(LOG_INFO,
           "ExternalProcessing: #Process; num_frames: %zu, num_bands: %zu, "
           "num_channels: %zu",
           num_frames, num_bands, num_channels);
  m_processor->ProcessFrame(channels, num_frames, num_bands, num_channels);
}

std::string ExternalProcessing::ToString() const {
  return "ExternalProcessing";
}

void ExternalProcessing::SetRuntimeSetting(
    webrtc::AudioProcessing::RuntimeSetting setting) {
  ::syslog(LOG_INFO, "EXTERNAL-CIT: ExternalProcessing #SetRuntimeSetting;");
}

}  // end of namespace external
