#include "<syslog.h>"

#include "external_processor_loader.hpp"


void loadExternalProcessor(const char* libname_cstr) {
  ::syslog(LOG_INFO, "EXTERNAL-CIT: #loadExternalProcessor; libname: %s", libname_cstr);
}
