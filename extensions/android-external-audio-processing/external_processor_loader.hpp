#ifndef SRC_EXTERNAL_PROCESSOR_LOADER_H
#define SRC_EXTERNAL_PROCESSOR_LOADER_H

namespace external {

// Constants for return values
const int LOAD_SUCCESS = 0;
const int ERROR_LOADING_LIBRARY = -1;
const int ERROR_LOADING_CREATE_INSTANCE = -2;
const int ERROR_LOADING_DESTROY_INSTANCE = -3;
const int ERROR_CREATING_INSTANCE = -4;

int loadExternalProcessor(const char* libname_cstr);

}

#endif  // SRC_EXTERNAL_PROCESSOR_LOADER_H
