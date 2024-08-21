#include <dlfcn.h>
#include "<syslog.h>"

#include "external_processor_loader.hpp"
#include "include/external_processor.hpp"


int loadExternalProcessor(const char* libname_cstr) {
  ::syslog(LOG_INFO, "EXTERNAL-CIT: #loadExternalProcessor; libname: %s", libname_cstr);

  // Load the shared library
  /*dlerror();  // Clear any existing errors
  void* handle = dlopen(libname_cstr, RTLD_LAZY);
  if (!handle) {
    syslog(LOG_ERR, "Failed to load library: %s", dlerror());
    return -1;
  }

  // Load the factory function for creating the ExternalProcessor instance
  auto createInstance = (external::ExternalProcessor* (*)())dlsym(handle, "CreateExternalProcessorInstance");
  const char* dlsymError = dlerror();
  if (dlsymError) {
    syslog(LOG_ERR, "Failed to load createInstance function: %s", dlsymError);
    dlclose(handle);
    return env->NewStringUTF("Failed to load createInstance function");
  }*/
}
