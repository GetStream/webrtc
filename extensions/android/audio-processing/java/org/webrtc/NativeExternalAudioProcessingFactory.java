package org.webrtc;

import org.jni_zero.NativeMethods;
import org.webrtc.AudioProcessingFactory;

public class NativeExternalAudioProcessingFactory implements AudioProcessingFactory {

  private final String libname;

  public NativeExternalAudioProcessingFactory(String libname) {
    if (libname == null) {
      throw new NullPointerException("libname must not be null.");
    }
    if (libname.isEmpty()) {
      throw new IllegalArgumentException("libname must not be empty.");
    }
    this.libname = libname;
  }

  @Override
  public long createNative(long webrtcEnvRef) {
    return NativeExternalAudioProcessingFactoryJni.get().createAudioProcessingModule(libname);
  }

  public void destroyNative() {
    NativeExternalAudioProcessingFactoryJni.get().destroyAudioProcessingModule();
  }

  @NativeMethods
  interface Natives {
    long createAudioProcessingModule(String libname);

    void destroyAudioProcessingModule();
  }
}
