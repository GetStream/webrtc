package org.webrtc;

import org.webrtc.AudioProcessingFactory;

public class DynamicAudioProcessingFactory implements AudioProcessingFactory {

  private final String libname;

  public DynamicAudioProcessingFactory(String libname) {
    if (libname == null) {
      throw new NullPointerException("libname must not be null.");
    }
    if (libname.isEmpty()) {
      throw new IllegalArgumentException("libname must not be empty.");
    }
    this.libname = libname;
  }

  @Override
  public long createNative() {
    return nativeGetInstance(libname);
  }

  private static native long nativeGetInstance();

}


