/*
 * Copyright 2022 LiveKit
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package org.webrtc;

import java.nio.ByteBuffer;

import androidx.annotation.Nullable;
import org.webrtc.AudioProcessingFactory;


public class ExternalAudioProcessingFactory implements AudioProcessingFactory {

  /**
   * Interface for external audio processing.
   */
  public static interface AudioProcessing {
    /**
     * Called when the processor should be initialized with a new sample rate and
     * number of channels.
     */
    @CalledByNative("AudioProcessing")
    void initialize(int sampleRateHz, int numChannels);
    /** Called when the processor should be reset with a new sample rate. */  
    @CalledByNative("AudioProcessing")
    void reset(int newRate);
    /**  
     * Processes the given capture or render signal. NOTE: `buffer.data` will be  
     * freed once this function returns so callers who want to use the data  
     * asynchronously must make sure to copy it first.  
     */
    @CalledByNative("AudioProcessing")
    void process(int numBands, int numFrames, ByteBuffer buffer);
  }

  private long apmPtr;
  private long capturePostProcessingPtr;
  private long renderPreProcessingPtr;

  public ExternalAudioProcessingFactory() {
    apmPtr = nativeGetDefaultApm();
    capturePostProcessingPtr = 0;
    renderPreProcessingPtr = 0;
  }

  @Override
  public long createNative(long webrtcEnvRef) {
    if(apmPtr == 0) {
      apmPtr = nativeGetDefaultApm();
    }
    return apmPtr;
  }

  /**
   * Sets the capture post processing module. 
   * This module is applied to the audio signal after capture and before sending 
   * to the audio encoder.
   */
  public void setCapturePostProcessing(@Nullable AudioProcessing processing) {
    checkExternalAudioProcessorExists();
    long newPtr = nativeSetCapturePostProcessing(processing);
    if (capturePostProcessingPtr != 0) {
      JniCommon.nativeReleaseRef(capturePostProcessingPtr);
      capturePostProcessingPtr = 0;
    }
    capturePostProcessingPtr = newPtr;
  }

  /**
   * Runtime sets the compressionGainDb for the capture audio processing module.
   * ranging [0, 90].
   */
  public void setCaptureCompressionGain(int compressionGainDb) {
    checkExternalAudioProcessorExists();
    nativeSetCaptureCompressionGain(compressionGainDb);
  }

  /**
   * Sets the compressionGainDb for the capture audio processing module.
   * targetLevelDbfs: default(3)
   * compressionGainDb: ranging [0, 90].
   */
  public void enableGainController1(Agc1Mode mode, int targetLevelDbfs, int compressionGainDb, boolean enableLimiter) {
    checkExternalAudioProcessorExists();
    nativeEnableGainController1(mode.ordinal(), targetLevelDbfs, compressionGainDb, enableLimiter);
  }

  /**
   * Sets the render pre processing module.
   * This module is applied to the audio signal after receiving from the audio
   * decoder and before rendering.
   */
  public void setRenderPreProcessing(@Nullable AudioProcessing processing) {
    checkExternalAudioProcessorExists();
    long newPtr = nativeSetRenderPreProcessing(processing);
    if (renderPreProcessingPtr != 0) {
      JniCommon.nativeReleaseRef(renderPreProcessingPtr);
      renderPreProcessingPtr = 0;
    }
    renderPreProcessingPtr = newPtr;
  }
  
  /**
   * Sets the bypass flag for the capture post processing module.
   * If true, the registered audio processing will be bypassed.
   */
  public void setBypassFlagForCapturePost( boolean bypass) {
    checkExternalAudioProcessorExists();
    nativeSetBypassFlagForCapturePost(bypass);
  }

  /**
   * Sets the bypass flag for the render pre processing module.
   * If true, the registered audio processing will be bypassed.
   */
  public void setBypassFlagForRenderPre( boolean bypass) {
    checkExternalAudioProcessorExists();
    nativeSetBypassFlagForRenderPre(bypass);
  }

  /**
   * Destroys the ExternalAudioProcessor.
   */
  public void destroy() {
    checkExternalAudioProcessorExists();
    if (renderPreProcessingPtr != 0) {
      JniCommon.nativeReleaseRef(renderPreProcessingPtr);
      renderPreProcessingPtr = 0;
    }
    if (capturePostProcessingPtr != 0) {
      JniCommon.nativeReleaseRef(capturePostProcessingPtr);
      capturePostProcessingPtr = 0;
    }
    nativeDestroy();
    apmPtr = 0;
  }

  private void checkExternalAudioProcessorExists() {
    if (apmPtr == 0) {
      throw new IllegalStateException("ExternalAudioProcessor has been disposed.");
    }
  }

  public enum Agc1Mode {
    // Adaptive mode intended for use if an analog volume control is
    // available on the capture device. It will require the user to provide
    // coupling between the OS mixer controls and AGC through the
    // stream_analog_level() functions.
    // It consists of an analog gain prescription for the audio device and a
    // digital compression stage.
    ADAPTIVE_ANALOG,
    // Adaptive mode intended for situations in which an analog volume
    // control is unavailable. It operates in a similar fashion to the
    // adaptive analog mode, but with scaling instead applied in the digital
    // domain. As with the analog mode, it additionally uses a digital
    // compression stage.
    ADAPTIVE_DIGITAL,
    // Fixed mode which enables only the digital compression stage also used
    // by the two adaptive modes.
    // It is distinguished from the adaptive modes by considering only a
    // short time-window of the input signal. It applies a fixed gain
    // through most of the input level range, and compresses (gradually
    // reduces gain with increasing level) the input signal at higher
    // levels. This mode is preferred on embedded devices where the capture
    // signal level is predictable, so that a known gain can be applied.
    FIXED_DIGITAL
  }

  private static native void nativeSetCaptureCompressionGain(int compressionGainDb);
  private static native void nativeEnableGainController1(int mode, int targetLevelDbfs, int compressionGainDb, boolean enableLimiter);
  private static native long nativeGetDefaultApm();
  private static native long nativeSetCapturePostProcessing(AudioProcessing processing);
  private static native long nativeSetRenderPreProcessing(AudioProcessing processing);
  private static native void nativeSetBypassFlagForCapturePost(boolean bypass);
  private static native void nativeSetBypassFlagForRenderPre(boolean bypass);
  private static native void nativeDestroy();
}
