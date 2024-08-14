/*
 *  Copyright 2017 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

package org.webrtc;

/** Factory for creating webrtc::ExternalAudioProcessing instances. */
public class ExternalAudioProcessingFactory implements AudioProcessingFactory {

  private ExternalAudioProcessorFactory processorFactory;

  public ExternalAudioProcessingFactory(ExternalAudioProcessorFactory processorFactory) {
    this.processorFactory = processorFactory;
  }

  /**
   * Dynamically allocates a webrtc::ExternalAudioProcessing instance and returns a pointer to it.
   * The caller takes ownership of the object.
   */
  public long createNative() {
    return nativeCreateExternalProcessing(processorFactory.createNative());
  }


  private static native long nativeCreateExternalProcessing(long processor);
}
