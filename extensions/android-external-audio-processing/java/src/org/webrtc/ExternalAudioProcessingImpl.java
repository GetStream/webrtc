package org.webrtc;

import org.webrtc.AudioProcessingFactory;

public class ExternalAudioProcessingImpl implements AudioProcessingFactory {
  private String m_model;
	
  @Override
  public long createNative() {
    return nativeExternalGetApm();
  }

  public void ExternalInit(String model) {
      nativeExternalInit(model);
  }

  public void ExternalInitBlob(byte[] data) {
      nativeExternalInitBlob(data);
  }

  public void ExternalDisable(boolean disable) {
      nativeExternalDisable(disable);
  }

  public boolean IsExternalDisabled() {
      return nativeIsExternalDisabled();
  }

  public void ExternalDestroy() {
      nativeExternalDestroy();
  }

  private static native void nativeExternalDisable(boolean disable);

  private static native boolean nativeIsExternalDisabled();

  private static native void nativeExternalInit(String model);

  private static native void nativeExternalInitBlob(byte[] data);

  private static native void nativeExternalDestroy();

  private static native long nativeExternalGetApm();
}


