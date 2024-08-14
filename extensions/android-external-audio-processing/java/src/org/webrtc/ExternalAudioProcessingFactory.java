package org.webrtc;

import org.webrtc.AudioProcessingFactory;

public class ExternalAudioProcessingFactory implements AudioProcessingFactory {
	
  @Override
  public long createNative() {
    return nativeGetAudioProcessingModule();
  }

  private static native long nativeGetAudioProcessingModule();
}


