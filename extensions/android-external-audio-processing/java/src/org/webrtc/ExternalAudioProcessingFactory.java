package org.webrtc;

import androidx.annotation.NonNull;
import org.webrtc.AudioProcessingFactory;

public final class ExternalAudioProcessingFactory implements AudioProcessingFactory {

  @NonNull
  private final ExternalAudioProcessorFactory externalProcessorFactory;

  private final ExternalAudioProcessingFactory(@NonNull ExternalAudioProcessorFactory externalProcessorFactory) {
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
  }
}


