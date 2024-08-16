package org.webrtc;

import org.webrtc.AudioProcessingFactory;

public class ExternalAudioProcessingFactory implements AudioProcessingFactory {

  private ExternalAudioProcessorFactory delegate;

  public ExternalAudioProcessingFactory(ExternalAudioProcessorFactory delegate) {
    if (delegate == null) {
      throw new NullPointerException("delegate must not be null.");
    }
    this.delegate = delegate;
  }

  @Override
  public long createNative() {
    return nativeGetAudioProcessingModule(delegate.createNative());
  }

  private static native long nativeGetAudioProcessingModule(long processor);

  /* private final ExternalAudioProcessorFactory externalProcessorFactory;

  private ExternalAudioProcessingFactory(ExternalAudioProcessorFactory externalProcessorFactory) {
    if (externalProcessorFactory == null) {
      throw new NullPointerException("externalProcessorFactory must not be null.");
    }
    this.externalProcessorFactory = externalProcessorFactory;
  }
	
  @Override
  public long createNative() {
    return nativeGetAudioProcessingModule(externalProcessorFactory.createNative());
  }

  private static native long nativeGetAudioProcessingModule(long nativeExternalProcessor);

  public static Builder builder() {
    return new Builder();
  }

  public static class Builder {

    Builder() {
    }

    private ExternalAudioProcessorFactory externalProcessorFactory;

    public Builder setExternalAudioProcessorFactory(ExternalAudioProcessorFactory externalProcessorFactory) {
      if (externalProcessorFactory == null) {
        throw new NullPointerException(
                    "ExternalAudioProcessingFactory.Builder does not accept a null ExternalAudioProcessorFactory.");
      }
      this.externalProcessorFactory = externalProcessorFactory;
      return this;
    }

    public ExternalAudioProcessingFactory build() {
      if (externalProcessorFactory == null) {
        throw new NullPointerException("externalProcessorFactory must not be null.");
      }
      return new ExternalAudioProcessingFactory(externalProcessorFactory);
    }
  } */
}


