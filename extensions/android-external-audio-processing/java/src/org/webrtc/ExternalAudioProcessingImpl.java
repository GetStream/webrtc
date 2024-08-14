package org.webrtc;

import org.webrtc.AudioProcessingFactory;

public class ExternalAudioProcessingImpl implements AudioProcessingFactory {
	
  @Override
  public long createNative() {
    return nativeExternalGetApm();
  }

  private static native long nativeExternalGetApm();
}


