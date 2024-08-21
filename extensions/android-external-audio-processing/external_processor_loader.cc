#include <dlfcn.h>
#include <syslog.h>

#include "external_processor_loader.hpp"
#include "include/external_processor.hpp"

namespace external {

int loadExternalProcessor(const char* libname_cstr) {
  ::syslog(LOG_INFO, "EXTERNAL-CIT: #loadExternalProcessor; libname: %s", libname_cstr);

  // Load the shared library
  /*dlerror();  // Clear any existing errors
  void* handle = dlopen(libname_cstr, RTLD_LAZY);
  if (!handle) {
    syslog(LOG_ERR, "Failed to load library: %s", dlerror());
    return ERROR_LOADING_LIBRARY;
  }

  // Load the factory function for creating the ExternalProcessor instance
  auto createInstance = (external::ExternalProcessor* (*)())dlsym(handle, "CreateExternalProcessorInstance");
  const char* dlsymError = dlerror();
  if (dlsymError) {
    syslog(LOG_ERR, "Failed to load createInstance function: %s", dlsymError);
    dlclose(handle);
    return ERROR_LOADING_CREATE_INSTANCE;
  }

  // Load the function for destroying the ExternalProcessor instance
  auto destroyInstance = (void (*)(external::ExternalProcessor*))dlsym(handle, "DestroyExternalProcessorInstance");
  dlsymError = dlerror();
  if (dlsymError) {
    syslog(LOG_ERR, "Failed to load destroyInstance function: %s", dlsymError);
    dlclose(handle);
    return ERROR_LOADING_DESTROY_INSTANCE;
  }

  // Create an instance of ExternalProcessor
  external::ExternalProcessor* processor = createInstance();
  if (!processor) {
    syslog(LOG_ERR, "Failed to create ExternalProcessor instance");
    dlclose(handle);
    return ERROR_CREATING_INSTANCE;
  }*/

  return LOAD_SUCCESS;
}

}  // namespace external