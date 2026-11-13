/*
 *  Copyright 2013 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

package org.webrtc;

import java.util.IdentityHashMap;
import org.jni_zero.NativeMethods;

/** Java wrapper for a C++ AudioTrackInterface */
public class AudioTrack extends MediaStreamTrack {
  private final IdentityHashMap<AudioTrackSink, Long> sinks = new IdentityHashMap<AudioTrackSink, Long>();

  public AudioTrack(long nativeTrack) {
    super(nativeTrack);
  }

  /**
   * Sets the volume for the underlying MediaSource. Volume is a gain value in the range 0 to 10.
   */
  public void setVolume(double volume) {
    lifecycleLock.run(nativeTrack -> AudioTrackJni.get().setVolume(nativeTrack, volume));
  }

  /**
   * Adds an AudioTrackSink to the track. This callback is only
   * called for remote audio tracks.
   * 
   * Repeated addSink calls will not add the sink multiple times.
   */
  public void addSink(AudioTrackSink sink) {
    if (sink == null) {
      throw new IllegalArgumentException("The AudioTrackSink is not allowed to be null");
    }
    lifecycleLock.run(
        nativeTrack -> {
          synchronized (sinks) {
            if (!sinks.containsKey(sink)) {
              final long nativeSink = AudioTrackJni.get().wrapSink(sink);
              sinks.put(sink, nativeSink);
              AudioTrackJni.get().addSink(nativeTrack, nativeSink);
            }
          }
        });
  }

  /**
   * Removes an AudioTrackSink from the track.
   *
   * If the AudioTrackSink was not attached to the track, this is a no-op.
   */
  public void removeSink(AudioTrackSink sink) {
    lifecycleLock.runIfAlive(
        nativeTrack -> {
          synchronized (sinks) {
            final Long nativeSink = sinks.remove(sink);
            if (nativeSink != null) {
              AudioTrackJni.get().removeSink(nativeTrack, nativeSink);
              AudioTrackJni.get().freeSink(nativeSink);
            }
          }
        });
  }

  @Override
  public void dispose() {
    lifecycleLock.dispose(
        nativeTrack -> {
          synchronized (sinks) {
            for (long nativeSink : sinks.values()) {
              AudioTrackJni.get().removeSink(nativeTrack, nativeSink);
              AudioTrackJni.get().freeSink(nativeSink);
            }
            sinks.clear();
          }
          JniCommon.nativeReleaseRef(nativeTrack);
        });
  }

  /** Returns a pointer to webrtc::AudioTrackInterface. */
  long getNativeAudioTrack() {
    return getNativeMediaStreamTrack();
  }

  @NativeMethods
  interface Natives {
    void setVolume(long track, double volume);

    void addSink(long track, long nativeSink);

    void removeSink(long track, long nativeSink);

    long wrapSink(AudioTrackSink sink);

    void freeSink(long sink);
  }
}
