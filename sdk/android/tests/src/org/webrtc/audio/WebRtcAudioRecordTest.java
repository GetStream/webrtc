/*
 *  Copyright 2026 The WebRTC Project Authors. All rights reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

package org.webrtc.audio;

import static com.google.common.truth.Truth.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import android.content.Context;
import android.content.pm.PackageManager;
import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioRecord;
import android.media.MediaRecorder.AudioSource;
import android.os.Build;
import androidx.annotation.Nullable;
import androidx.test.runner.AndroidJUnit4;
import java.nio.ByteBuffer;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.annotation.Config;

/**
 * Tests for changing the capture audio source of a {@link WebRtcAudioRecord} after construction.
 *
 * <p>Runs at SDK 21 so that the error reporting path stays off the AudioDeviceInfo and
 * AudioRecordingConfiguration APIs, which cannot be exercised against mocked framework objects.
 */
@RunWith(AndroidJUnit4.class)
@Config(manifest = Config.NONE, sdk = Build.VERSION_CODES.LOLLIPOP)
public class WebRtcAudioRecordTest {
  private static final int SAMPLE_RATE = 48000;
  private static final int CHANNEL_COUNT = 1;
  private static final int MIN_BUFFER_SIZE = 4096;

  /**
   * A WebRtcAudioRecord whose AudioRecord creation is stubbed, so that a source the device would
   * reject can be simulated and the sources actually used can be observed.
   */
  private static class TestWebRtcAudioRecord extends WebRtcAudioRecord {
    final Set<Integer> rejectedSources = new HashSet<>();
    /** Sources that construct fine but refuse to start, as when another app holds the mic. */
    final Set<Integer> unstartableSources = new HashSet<>();
    final List<Integer> createdSources = new ArrayList<>();
    final List<AudioRecord> createdRecords = new ArrayList<>();

    TestWebRtcAudioRecord(Context context, AudioManager audioManager) {
      super(context, newDefaultScheduler(), audioManager, AudioSource.VOICE_COMMUNICATION,
          AudioFormat.ENCODING_PCM_16BIT, /* errorCallback= */ null, /* stateCallback= */ null,
          /* audioSamplesReadyCallback= */ null, /* audioBufferCallback= */ null,
          /* isAcousticEchoCancelerSupported= */ false, /* isNoiseSuppressorSupported= */ false,
          SAMPLE_RATE, CHANNEL_COUNT);
    }

    @Override
    ByteBuffer allocateByteBuffer(int capacity) {
      // A host-JVM direct buffer has no backing array, which initRecordingImpl() rejects.
      return ByteBuffer.allocate(capacity);
    }

    @Override
    int getMinBufferSize(int sampleRate, int channelConfig, int audioFormat) {
      return MIN_BUFFER_SIZE;
    }

    @Override
    @Nullable
    AudioRecord createAudioRecord(int audioSource, int sampleRate, int channelConfig,
        int audioFormat, int bufferSizeInBytes) {
      if (rejectedSources.contains(audioSource)) {
        // Matches what the framework throws for a source the device will not open.
        throw new IllegalArgumentException("Cannot create AudioRecord for source " + audioSource);
      }
      createdSources.add(audioSource);
      AudioRecord audioRecord = mock(AudioRecord.class);
      when(audioRecord.getState()).thenReturn(AudioRecord.STATE_INITIALIZED);
      when(audioRecord.getRecordingState())
          .thenReturn(unstartableSources.contains(audioSource) ? AudioRecord.RECORDSTATE_STOPPED
                                                               : AudioRecord.RECORDSTATE_RECORDING);
      createdRecords.add(audioRecord);
      return audioRecord;
    }

    /** Drives the same open-and-start path the capture thread takes, without spawning it. */
    @Nullable
    AudioRecord openForCaptureThread() {
      return openAudioRecordWithFallback(/* startRecording= */ true);
    }

    int lastCreatedSource() {
      return createdSources.get(createdSources.size() - 1);
    }

    AudioRecord lastCreatedRecord() {
      return createdRecords.get(createdRecords.size() - 1);
    }
  }

  private TestWebRtcAudioRecord webRtcAudioRecord;

  @Before
  public void setUp() {
    Context context = mock(Context.class);
    when(context.getPackageManager()).thenReturn(mock(PackageManager.class));
    webRtcAudioRecord = new TestWebRtcAudioRecord(context, mock(AudioManager.class));
  }

  @Test
  public void initialAudioSourceComesFromTheConstructor() {
    assertThat(webRtcAudioRecord.getAudioSource()).isEqualTo(AudioSource.VOICE_COMMUNICATION);
  }

  @Test
  public void setAudioSourceBeforeInitIsAppliedOnFirstInit() {
    webRtcAudioRecord.setAudioSource(AudioSource.MIC);

    assertThat(webRtcAudioRecord.initRecordingIfNeeded()).isTrue();

    assertThat(webRtcAudioRecord.getAudioSource()).isEqualTo(AudioSource.MIC);
    assertThat(webRtcAudioRecord.lastCreatedSource()).isEqualTo(AudioSource.MIC);
  }

  @Test
  public void setAudioSourceRebuildsAudioRecordWithNewSource() {
    assertThat(webRtcAudioRecord.initRecordingIfNeeded()).isTrue();
    assertThat(webRtcAudioRecord.lastCreatedSource()).isEqualTo(AudioSource.VOICE_COMMUNICATION);

    webRtcAudioRecord.setAudioSource(AudioSource.MIC);

    assertThat(webRtcAudioRecord.getAudioSource()).isEqualTo(AudioSource.MIC);
    assertThat(webRtcAudioRecord.lastCreatedSource()).isEqualTo(AudioSource.MIC);
  }

  @Test
  public void setAudioSourceWithSameSourceDoesNotRebuild() {
    assertThat(webRtcAudioRecord.initRecordingIfNeeded()).isTrue();
    int createdBefore = webRtcAudioRecord.createdSources.size();

    webRtcAudioRecord.setAudioSource(AudioSource.VOICE_COMMUNICATION);

    assertThat(webRtcAudioRecord.createdSources).hasSize(createdBefore);
  }

  @Test
  public void rejectedAudioSourceRestoresLastWorkingSource() {
    assertThat(webRtcAudioRecord.initRecordingIfNeeded()).isTrue();
    webRtcAudioRecord.rejectedSources.add(AudioSource.MIC);

    webRtcAudioRecord.setAudioSource(AudioSource.MIC);

    // The rejected source must not stick, and capture must be left on a working AudioRecord.
    assertThat(webRtcAudioRecord.getAudioSource()).isEqualTo(AudioSource.VOICE_COMMUNICATION);
    assertThat(webRtcAudioRecord.lastCreatedSource()).isEqualTo(AudioSource.VOICE_COMMUNICATION);
  }

  /**
   * The fallback target must track the last source that actually opened, not the value the field
   * held before the failing call, otherwise a successful switch followed by a failing one would
   * rewind capture past a source that was working.
   */
  @Test
  public void fallbackUsesMostRecentWorkingSource() {
    assertThat(webRtcAudioRecord.initRecordingIfNeeded()).isTrue();
    webRtcAudioRecord.setAudioSource(AudioSource.MIC);
    assertThat(webRtcAudioRecord.lastCreatedSource()).isEqualTo(AudioSource.MIC);

    webRtcAudioRecord.rejectedSources.add(AudioSource.UNPROCESSED);
    webRtcAudioRecord.setAudioSource(AudioSource.UNPROCESSED);

    assertThat(webRtcAudioRecord.getAudioSource()).isEqualTo(AudioSource.MIC);
    assertThat(webRtcAudioRecord.lastCreatedSource()).isEqualTo(AudioSource.MIC);
  }

  /**
   * A source can construct successfully and still refuse to start, which is the usual symptom of
   * another app holding the microphone. That must still fall back rather than count as success,
   * otherwise the source nominates itself as the fallback target and capture is left dead.
   */
  @Test
  public void sourceThatFailsToStartFallsBackToLastWorkingSource() {
    assertThat(webRtcAudioRecord.initRecordingIfNeeded()).isTrue();
    // Put the instance in the state the capture thread reaches once it has dropped the previous
    // AudioRecord and is about to open the newly requested source.
    webRtcAudioRecord.releaseAudioResources();
    webRtcAudioRecord.setAudioSource(AudioSource.MIC);
    webRtcAudioRecord.unstartableSources.add(AudioSource.MIC);

    assertThat(webRtcAudioRecord.openForCaptureThread()).isNotNull();

    assertThat(webRtcAudioRecord.getAudioSource()).isEqualTo(AudioSource.VOICE_COMMUNICATION);
    assertThat(webRtcAudioRecord.lastCreatedSource()).isEqualTo(AudioSource.VOICE_COMMUNICATION);
  }

  /**
   * A rebuild while initialized but not started must leave the new AudioRecord un-started, so that
   * the later startRecordingImpl() is the one that starts it.
   */
  @Test
  public void rebuildWhileIdleDoesNotStartRecording() {
    assertThat(webRtcAudioRecord.initRecordingIfNeeded()).isTrue();

    webRtcAudioRecord.setAudioSource(AudioSource.MIC);

    verify(webRtcAudioRecord.lastCreatedRecord(), never()).startRecording();
  }

  @Test
  public void rejectedAudioSourceLeavesAudioRecordInitialized() {
    assertThat(webRtcAudioRecord.initRecordingIfNeeded()).isTrue();
    webRtcAudioRecord.rejectedSources.add(AudioSource.MIC);
    webRtcAudioRecord.setAudioSource(AudioSource.MIC);

    // A live AudioRecord must still be present, otherwise a later startRecordingImpl() would
    // assert on it being null. initRecordingIfNeeded() is then a no-op rather than a fresh init.
    int createdAfterFallback = webRtcAudioRecord.createdSources.size();
    assertThat(webRtcAudioRecord.initRecordingIfNeeded()).isTrue();
    assertThat(webRtcAudioRecord.createdSources).hasSize(createdAfterFallback);
  }

  @Test
  public void rejectedAudioSourceDoesNotBlockLaterChanges() {
    assertThat(webRtcAudioRecord.initRecordingIfNeeded()).isTrue();
    webRtcAudioRecord.rejectedSources.add(AudioSource.MIC);
    webRtcAudioRecord.setAudioSource(AudioSource.MIC);

    // The device now accepts the source, e.g. because audio routing changed.
    webRtcAudioRecord.rejectedSources.clear();
    webRtcAudioRecord.setAudioSource(AudioSource.MIC);

    assertThat(webRtcAudioRecord.getAudioSource()).isEqualTo(AudioSource.MIC);
    assertThat(webRtcAudioRecord.lastCreatedSource()).isEqualTo(AudioSource.MIC);
  }
}
