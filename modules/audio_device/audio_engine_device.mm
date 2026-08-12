/*
 * Copyright 2024 LiveKit
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

#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

#include "audio_engine_device.h"

#include <mach/mach_time.h>
#include <cmath>

#include "api/array_view.h"
#include "api/environment/environment_factory.h"
#include "api/task_queue/default_task_queue_factory.h"
#include "api/task_queue/pending_task_safety_flag.h"
#include "modules/audio_device/fine_audio_buffer.h"
#include "rtc_base/checks.h"
#include "rtc_base/logging.h"
#include "rtc_base/thread.h"
#include "rtc_base/thread_annotations.h"
#include "rtc_base/time_utils.h"

#if defined(WEBRTC_IOS)
#import "components/audio/RTCAudioSession+Private.h"
#import "components/audio/RTCAudioSession.h"
#import "components/audio/RTCAudioSessionConfiguration.h"
#import "components/audio/RTCNativeAudioSessionDelegateAdapter.h"
#endif

#if TARGET_OS_OSX
#import "./mac/audio_device_utils_mac.h"
#endif

namespace webrtc {

NSString* const kAudioEngineInputMixerNodeKey = @"_audio_engine_input_mixer_node_key";

#define LOGI() RTC_LOG(LS_INFO) << "AudioEngineDevice::"
#define LOGE() RTC_LOG(LS_ERROR) << "AudioEngineDevice::"
#define LOGW() RTC_LOG(LS_WARNING) << "AudioEngineDevice::"

const UInt16 kFixedPlayoutDelayEstimate = 0;
const UInt16 kFixedRecordDelayEstimate = 0;
const UInt16 kStartEngineMaxRetries = 10;  // Maximum blocking 1sec.
const useconds_t kStartEngineRetryDelayMs = 100;
// Bound VP recovery so a persistent AVAudioEngine failure cannot hang setup.
const UInt16 kVoiceProcessingMaxRetries = 3;
// Give the released I/O unit time to stop before building the next graph.
const useconds_t kVoiceProcessingRetryDelayMs = 100;

const size_t kMaximumFramesPerBuffer = 3072;
const size_t kAudioSampleSize = 2;  // Signed 16-bit integer

AudioEngineInputRenderContext::AudioEngineInputRenderContext(
    AVAudioFormat* engine_format,
    AVAudioFormat* rtc_format,
    std::shared_ptr<AudioDeviceBuffer> audio_device_buffer,
    double mach_tick_units_to_nanoseconds)
    // Observe the device-owned buffer without extending its destruction
    // sequence to the AVAudioEngine callback thread.
    : audio_device_buffer_(audio_device_buffer),
      // FineAudioBuffer caches a raw buffer pointer, so invalidation must
      // destroy it before the device owner can disappear.
      fine_audio_buffer_(
          std::make_unique<FineAudioBuffer>(audio_device_buffer.get())),
      // Copy the scalar timing ratio instead of capturing AudioEngineDevice.
      mach_tick_units_to_nanoseconds_(mach_tick_units_to_nanoseconds) {
  // Move the converter beside the sink callback so its lifetime follows every
  // copied block invocation rather than the releasing engine object.
  OSStatus err = AudioConverterNew(engine_format.streamDescription,
                                   rtc_format.streamDescription, &converter_ref_);
  // Preserve the original construction invariant: rendering requires a valid
  // converter and cannot recover inside the real-time callback.
  RTC_DCHECK(err == noErr);
  // Keep the converter's destination memory alive for the same guarded
  // lifetime as the converter itself.
  converter_buffer_ = [[AVAudioPCMBuffer alloc] initWithPCMFormat:rtc_format
                                                    frameCapacity:kMaximumFramesPerBuffer];
  // Reject partial native allocation in release builds because Render cannot
  // safely recover from missing conversion resources on the audio thread.
  if (err != noErr || converter_ref_ == nullptr || converter_buffer_ == nil) {
    // Close the callback gate while leaving Invalidate to release any resource
    // that was created before the other allocation failed.
    is_valid_ = false;
  }
}

AudioEngineInputRenderContext::~AudioEngineInputRenderContext() {
  // Normal teardown invalidates on the device thread; this fallback prevents a
  // missed path from leaking callback-local conversion resources.
  Invalidate();
}

void AudioEngineInputRenderContext::Invalidate() {
  // Taking the render lock drains a callback that already entered conversion
  // and prevents any later callback from observing partially released state.
  MutexLock lock(&mutex_);
  // Close the callback gate before dropping any resource it may access.
  is_valid_ = false;
  // Remove FineAudioBuffer's raw AudioDeviceBuffer link while the device still
  // owns the underlying sequence-affine object.
  fine_audio_buffer_.reset();
  // Dispose the converter on the device-control sequence after in-flight
  // conversion has completed under the same lock.
  if (converter_ref_ != nullptr) {
    OSStatus err = AudioConverterDispose(converter_ref_);
    // Match creation's invariant while ensuring repeated invalidation cannot
    // dispose the converter twice.
    RTC_DCHECK(err == noErr);
    converter_ref_ = nullptr;
  }
  // Release the Objective-C sample storage with the converter it backs.
  converter_buffer_ = nil;
}

OSStatus AudioEngineInputRenderContext::Render(const AudioTimeStamp* timestamp,
                                               AVAudioFrameCount frame_count,
                                               const AudioBufferList* input_data) {
  // Never make AVAudioEngine's real-time callback wait for another render or
  // teardown user of the shared conversion resources.
  if (!mutex_.TryLock()) {
    return noErr;
  }
  // AVAudioEngine may invoke its copied block after detach; that callback must
  // succeed as a no-op without touching released input pointers.
  if (!is_valid_) {
    // Release the non-blocking gate before returning from the ignored callback.
    mutex_.Unlock();
    return noErr;
  }

  // Promote weak access only for this render so the callback never owns the
  // buffer beyond active work, and keep it mutable so it can be dropped before
  // teardown reacquires the gate.
  auto audio_device_buffer = audio_device_buffer_.lock();
  // Device destruction can win the race before callback entry; no delivery is
  // possible once the owner is gone.
  if (audio_device_buffer == nullptr) {
    // A failed weak promotion owns no device state, so release the gate now.
    mutex_.Unlock();
    return noErr;
  }

  // The configured mono sink and converter must agree on one input buffer.
  RTC_DCHECK(input_data->mNumberBuffers == 1);

  // AVAudioPCMBuffer owns the writable list; AudioConverter's C API requires
  // the non-const view used only during this guarded conversion.
  AudioBufferList* converter_buffer_abl =
      const_cast<AudioBufferList*>(converter_buffer_.audioBufferList);
  // Reject an engine format change that would violate the prepared converter.
  RTC_DCHECK(converter_buffer_abl->mNumberBuffers == input_data->mNumberBuffers);

  // Fails for conversions where there is a variation between the input and output data
  // buffer sizes.
  converter_buffer_abl->mBuffers[0].mDataByteSize = input_data->mBuffers[0].mDataByteSize;

  // Keep the prepared output view aligned with the engine input before the C
  // converter reads either list.
  RTC_DCHECK(converter_buffer_abl->mBuffers[0].mDataByteSize ==
             input_data->mBuffers[0].mDataByteSize);

  // Convert while teardown is excluded so AudioConverterDispose cannot race
  // this call.
  OSStatus err = AudioConverterConvertComplexBuffer(converter_ref_, frame_count, input_data,
                                                    converter_buffer_abl);
  // The render path cannot substitute valid recorded data after conversion
  // failure, matching the previous callback behavior.
  RTC_DCHECK(err == noErr);

  // Reuse the converter's Int16 storage without copying on the audio thread.
  const int16_t* rtc_buffer =
      static_cast<int16_t*>(converter_buffer_abl->mBuffers[0].mData);
  // Preserve AVAudioEngine's host timestamp after removing the device capture.
  const int64_t capture_time_ns =
      timestamp->mHostTime * mach_tick_units_to_nanoseconds_;

  // Deliver while the temporary strong buffer reference and teardown lock are
  // both held, then release that reference back on this callback invocation.
  fine_audio_buffer_->DeliverRecordedData(
      webrtc::ArrayView<const int16_t>(rtc_buffer, frame_count), kFixedRecordDelayEstimate,
      capture_time_ns);

  // Drop render-scoped ownership before teardown can release the device's
  // strong owner, preserving AudioDeviceBuffer destruction on its sequence.
  audio_device_buffer.reset();
  // Release conversion resources to teardown only after render is fully done.
  mutex_.Unlock();
  // A completed or intentionally ignored sink callback is successful to
  // AVAudioEngine, so teardown does not provoke a second error path.
  return noErr;
}

AudioEngineDevice::AudioEngineDevice(bool voice_processing_bypassed)
    : task_queue_factory_(CreateDefaultTaskQueueFactory()), initialized_(false) {
  LOGI() << "voice_processing_bypassed " << voice_processing_bypassed;

  thread_ = webrtc::Thread::Current();
  // Keep the device as the long-lived owner while callback contexts obtain
  // only weak, render-scoped access.
  audio_device_buffer_ = std::make_shared<webrtc::AudioDeviceBuffer>(
      webrtc::CreateEnvironment(task_queue_factory_.get()));

#if defined(WEBRTC_IOS)
  audio_session_observer_ =
      [[RTC_OBJC_TYPE(RTCNativeAudioSessionDelegateAdapter) alloc] initWithObserver:this];
  // Subscribe to audio session events.
  RTC_OBJC_TYPE(RTCAudioSession)* session = [RTC_OBJC_TYPE(RTCAudioSession) sharedInstance];
  [session addDelegate:audio_session_observer_];
#endif

  mach_timebase_info_data_t tinfo;
  mach_timebase_info(&tinfo);
  machTickUnitsToNanoseconds_ = (double)tinfo.numer / tinfo.denom;

  // Manual rendering formats are fixed to 48k for now.
  manual_render_rtc_format_ = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16
                                                               sampleRate:48000
                                                                 channels:1
                                                              interleaved:YES];

  // Initial engine state
  engine_state_.voice_processing_bypassed = voice_processing_bypassed;
}

AudioEngineDevice::~AudioEngineDevice() {
  RTC_DCHECK_RUN_ON(thread_);

  safety_->SetNotAlive();
#if TARGET_OS_OSX
  default_device_update_safety_->SetNotAlive();
#endif

  Terminate();

#if defined(WEBRTC_IOS)
  RTC_OBJC_TYPE(RTCAudioSession)* session = [RTC_OBJC_TYPE(RTCAudioSession) sharedInstance];
  [session removeDelegate:audio_session_observer_];
  audio_session_observer_ = nil;
#endif
}

#if TARGET_OS_OSX
OSStatus AudioEngineDevice::objectListenerProc(AudioObjectID objectId, UInt32 numberAddresses,
                                               const AudioObjectPropertyAddress addresses[],
                                               void* clientData) {
  AudioEngineDevice* ptrThis = (AudioEngineDevice*)clientData;
  RTC_DCHECK(ptrThis != NULL);

  // ptrThis->implObjectListenerProc(objectId, numberAddresses, addresses);

  for (UInt32 i = 0; i < numberAddresses; i++) {
    ptrThis->HandleDeviceListenerEvent(addresses[i].mSelector);
  }

  return 0;
}

void AudioEngineDevice::HandleDeviceListenerEvent(AudioObjectPropertySelector selector) {
  thread_->PostTask(SafeTask(safety_, [this, selector] {
    RTC_DCHECK_RUN_ON(thread_);

    if (selector == kAudioHardwarePropertyDevices) {
      auto old_input_device_ids = input_device_ids_;
      auto old_output_device_ids = output_device_ids_;
      UpdateAllDeviceIDs();
      // Check if device ids updated
      if (old_output_device_ids != output_device_ids_ ||
          old_input_device_ids != input_device_ids_) {
        LOGI() << "Did update devices";

        // Current device
        if (engine_state_.output_device_id != kAudioObjectUnknown) {
          bool contains = std::binary_search(output_device_ids_.begin(), output_device_ids_.end(),
                                             engine_state_.output_device_id);
          if (!contains) {
            int32_t result = ModifyEngineState([](EngineState state) -> EngineState {
              state.output_device_id = kAudioObjectUnknown;
              return state;
            });
            if (result != 0) {
              LOGE() << "Failed to reset output device ID, error: " << result;
            }
          }
        }

        if (engine_state_.input_device_id != kAudioObjectUnknown) {
          bool contains = std::binary_search(input_device_ids_.begin(), input_device_ids_.end(),
                                             engine_state_.input_device_id);
          if (!contains) {
            int32_t result = ModifyEngineState([](EngineState state) -> EngineState {
              state.input_device_id = kAudioObjectUnknown;
              return state;
            });
            if (result != 0) {
              LOGE() << "Failed to reset input device ID, error: " << result;
            }
          }
        }

        if (observer_) {
          observer_->OnDevicesUpdated();
        }
      }
    } else if (selector == kAudioHardwarePropertyDefaultOutputDevice ||
               selector == kAudioHardwarePropertyDefaultInputDevice) {
      // Cancel any pending updates
      default_device_update_safety_->SetNotAlive();
      default_device_update_safety_ = PendingTaskSafetyFlag::Create();

      // Schedule a new debounced update
      thread_->PostDelayedTask(
          SafeTask(default_device_update_safety_,
                   [this, selector] {
                     RTC_DCHECK_RUN_ON(thread_);
                     LOGI() << "Processing debounced default device update for selector: "
                            << selector;

                     if (selector == kAudioHardwarePropertyDefaultOutputDevice) {
                       LOGI() << "Did update default output device";
                       int32_t result = ModifyEngineState([](EngineState state) -> EngineState {
                         state.default_output_device_update_count++;
                         return state;
                       });
                       if (result != 0) {
                         LOGE() << "Failed to update default output device update count, error: "
                                << result;
                       }
                     } else if (selector == kAudioHardwarePropertyDefaultInputDevice) {
                       LOGI() << "Did update default input device";
                       int32_t result = ModifyEngineState([](EngineState state) -> EngineState {
                         state.default_input_device_update_count++;
                         return state;
                       });
                       if (result != 0) {
                         LOGE() << "Failed to update default input device update count, error: "
                                << result;
                       }
                     }
                   }),
          TimeDelta::Millis(kDefaultDeviceUpdateDebounceMs));
    }
  }));
}

#endif

// MARK: - Main life cycle

bool AudioEngineDevice::Initialized() const {
  LOGI() << "Initialized";
  RTC_DCHECK_RUN_ON(thread_);

  return initialized_;
}

int32_t AudioEngineDevice::Init() {
  LOGI() << "Init";
  RTC_DCHECK_RUN_ON(thread_);

  if (initialized_) {
    LOGW() << "Init: Already initialized";
    return 0;
  }

#if defined(WEBRTC_IOS)
  RTC_OBJC_TYPE(RTCAudioSessionConfiguration)* config =
      [RTC_OBJC_TYPE(RTCAudioSessionConfiguration) webRTCConfiguration];
  playout_parameters_.reset(config.sampleRate, config.outputNumberOfChannels);
  record_parameters_.reset(config.sampleRate, config.inputNumberOfChannels);
#endif

#if TARGET_OS_OSX
  // Setting RunLoop to NULL here instructs HAL to manage its own thread for
  // notifications. This was the default behaviour on OS X 10.5 and earlier,
  // but now must be explicitly specified. HAL would otherwise try to use the
  // main thread to issue notifications.
  AudioObjectPropertyAddress propertyAddress = {kAudioHardwarePropertyRunLoop,
                                                kAudioObjectPropertyScopeGlobal,
                                                kAudioObjectPropertyElementMain};

  CFRunLoopRef runLoop = NULL;
  UInt32 size = sizeof(CFRunLoopRef);
  OSStatus err = noErr;

  err = AudioObjectSetPropertyData(kAudioObjectSystemObject, &propertyAddress, 0, NULL, size,
                                   &runLoop);
  if (err != noErr) {
    LOGE() << "AudioObjectSetPropertyData failed with error: " << err;
    return -1;
  }

  // Listen for any device changes.
  propertyAddress.mSelector = kAudioHardwarePropertyDevices;
  err = AudioObjectAddPropertyListener(kAudioObjectSystemObject, &propertyAddress,
                                       &objectListenerProc, this);
  if (err != noErr) {
    LOGE() << "AudioObjectAddPropertyListener failed with error: " << err;
    return -1;
  }

  // Listen for default output device change.
  propertyAddress.mSelector = kAudioHardwarePropertyDefaultOutputDevice;
  err = AudioObjectAddPropertyListener(kAudioObjectSystemObject, &propertyAddress,
                                       &objectListenerProc, this);
  if (err != noErr) {
    LOGE() << "AudioObjectAddPropertyListener failed with error: " << err;
    return -1;
  }

  // Listen for default input device change.
  propertyAddress.mSelector = kAudioHardwarePropertyDefaultInputDevice;
  err = AudioObjectAddPropertyListener(kAudioObjectSystemObject, &propertyAddress,
                                       &objectListenerProc, this);
  if (err != noErr) {
    LOGE() << "AudioObjectAddPropertyListener failed with error: " << err;
    return -1;
  }

  UpdateAllDeviceIDs();
#endif

  initialized_ = true;
  return 0;
}

int32_t AudioEngineDevice::Terminate() {
  LOGI() << "Terminate";
  RTC_DCHECK_RUN_ON(thread_);
  if (!initialized_) {
    return 0;
  }

#if TARGET_OS_OSX
  // Remove listeners for global scope.
  AudioObjectPropertyAddress propertyAddress = {
      kAudioHardwarePropertyDevices,     // selector
      kAudioObjectPropertyScopeGlobal,   // scope
      kAudioObjectPropertyElementMain    // element
  };

  OSStatus err = noErr;
  err = AudioObjectRemovePropertyListener(kAudioObjectSystemObject, &propertyAddress,
                                          &objectListenerProc, this);
  if (err != noErr) {
    LOGE() << "AudioObjectRemovePropertyListener failed with error: " << err;
    return -1;
  }

  propertyAddress.mSelector = kAudioHardwarePropertyDefaultOutputDevice;
  err = AudioObjectRemovePropertyListener(kAudioObjectSystemObject, &propertyAddress,
                                          &objectListenerProc, this);
  if (err != noErr) {
    LOGE() << "AudioObjectRemovePropertyListener failed with error: " << err;
    return -1;
  }

  propertyAddress.mSelector = kAudioHardwarePropertyDefaultInputDevice;
  err = AudioObjectRemovePropertyListener(kAudioObjectSystemObject, &propertyAddress,
                                          &objectListenerProc, this);
  if (err != noErr) {
    LOGE() << "AudioObjectRemovePropertyListener failed with error: " << err;
    return -1;
  }
#endif

  StopPlayout();
  StopRecording();

  initialized_ = false;
  return 0;
}

int32_t AudioEngineDevice::Reset() {
  LOGI() << "Reset";
  RTC_DCHECK_RUN_ON(thread_);
  if (!initialized_) {
    return 0;
  }

  StopPlayout();
  StopRecording();
  ResetEngineState();

  return 0;
}

// ----------------------------------------------------------------------------------------------------
// Playout

bool AudioEngineDevice::PlayoutIsInitialized() const {
  LOGI() << "PlayoutIsInitialized";
  RTC_DCHECK_RUN_ON(thread_);

  return engine_state_.output_enabled;
}

bool AudioEngineDevice::Playing() const {
  LOGI() << "Playing";
  RTC_DCHECK_RUN_ON(thread_);

  return engine_state_.output_running;
}

int32_t AudioEngineDevice::InitPlayout() {
  LOGI() << "InitPlayout";
  RTC_DCHECK_RUN_ON(thread_);
  RTC_DCHECK(initialized_);

  int32_t result = ModifyEngineState([](EngineState state) -> EngineState {
    state.output_enabled = true;
    return state;
  });

  return result;
}

int32_t AudioEngineDevice::StartPlayout() {
  LOGI() << "StartPlayout";
  RTC_DCHECK_RUN_ON(thread_);

  int32_t result = ModifyEngineState([](EngineState state) -> EngineState {
    state.output_running = true;
    return state;
  });

  return result;
}

int32_t AudioEngineDevice::StopPlayout() {
  LOGI() << "StopPlayout";
  RTC_DCHECK_RUN_ON(thread_);

  int32_t result = ModifyEngineState([](EngineState state) -> EngineState {
    state.output_enabled = false;
    state.output_running = false;
    return state;
  });

  return result;
}

// ----------------------------------------------------------------------------------------------------
// Recording

bool AudioEngineDevice::RecordingIsInitialized() const {
  LOGI() << "RecordingIsInitialized";
  RTC_DCHECK_RUN_ON(thread_);

  return engine_state_.input_enabled;
}

bool AudioEngineDevice::Recording() const {
  LOGI() << "Recording";
  RTC_DCHECK_RUN_ON(thread_);

  return engine_state_.input_running;
}

int32_t AudioEngineDevice::InitRecording() {
  LOGI() << "InitRecording";
  RTC_DCHECK_RUN_ON(thread_);
  RTC_DCHECK(initialized_);

  int32_t result = ModifyEngineState([](EngineState state) -> EngineState {
    state.input_enabled = true;
    return state;
  });

  return result;
}

int32_t AudioEngineDevice::StartRecording() {
  LOGI() << "StartRecording";
  RTC_DCHECK_RUN_ON(thread_);

  int32_t result = ModifyEngineState([](EngineState state) -> EngineState {
    state.input_running = true;
    state.input_muted = false;  // Always unmute
    return state;
  });

  return result;
}

int32_t AudioEngineDevice::StopRecording() {
  LOGI() << "StopRecording";
  RTC_DCHECK_RUN_ON(thread_);

  int32_t result = ModifyEngineState([](EngineState state) -> EngineState {
    state.input_enabled = false;
    state.input_running = false;
    return state;
  });

  return result;
}

// ----------------------------------------------------------------------------------------------------
// AudioSessionObserver

void AudioEngineDevice::OnInterruptionBegin() {
  LOGI() << "OnInterruptionBegin";

  RTC_DCHECK(thread_);
  thread_->PostTask(SafeTask(safety_, [this] {
    int32_t result = this->ModifyEngineState([](EngineState state) -> EngineState {
      state.is_interrupted = true;
      return state;
    });
    if (result != 0) {
      LOGE() << "Failed to update engine state for interruption begin, error: " << result;
    }
  }));
}

void AudioEngineDevice::OnInterruptionEnd(bool should_resume) {
  LOGI() << "OnInterruptionEnd should_resume: " << should_resume;

  RTC_DCHECK(thread_);
  thread_->PostTask(SafeTask(safety_, [this, should_resume] {
    int32_t result = this->ModifyEngineState([](EngineState state) -> EngineState {
      state.is_interrupted = false;
      return state;
    });
    if (result != 0) {
      LOGE() << "Failed to update engine state for interruption end, error: " << result;
      return;
    }

    if (should_resume &&
        this->should_reconfigure_after_media_services_reset_.exchange(false)) {
      LOGI() << "Reconfiguring after media-services reset and audio-session "
                "reactivation";
      this->ReconfigureEngine(
          /*restore_media_services_recovery_on_failure=*/true);
    }
  }));
}

void AudioEngineDevice::OnValidRouteChange() {
  LOGI() << "OnValidRouteChange";
  RTC_DCHECK(thread_);

  thread_->PostTask(SafeTask(safety_, [this] {
    this->RefreshStereoPlayoutState();
  }));
}

void AudioEngineDevice::OnMediaServicesReset() {
  LOGI() << "OnMediaServicesReset";
  RTC_DCHECK(thread_);

  // A media-services reset invalidates AVAudioEngine and its nodes even though
  // WebRTC still considers playout and recording started. ReconfigureEngine
  // rebuilds the graph and restores their prior state.
  should_reconfigure_after_media_services_reset_.store(true);
  ReconfigureEngine();
}

void AudioEngineDevice::OnCanPlayOrRecordChange(bool can_play_or_record) {
  LOGI() << "OnCanPlayOrRecordChange";
  RTC_DCHECK(thread_);
}

void AudioEngineDevice::OnChangedOutputVolume() {
  LOGI() << "OnChangedOutputVolume";
  RTC_DCHECK(thread_);
}

// ----------------------------------------------------------------------------------------------------
// Not Implemented

bool AudioEngineDevice::IsInterrupted() {
  LOGI() << "IsInterrupted";
  RTC_DCHECK_RUN_ON(thread_);

  return engine_state_.is_interrupted;
}

int32_t AudioEngineDevice::ActiveAudioLayer(AudioDeviceModule::AudioLayer* audioLayer) const {
  LOGI() << "ActiveAudioLayer";
  if (audioLayer == nullptr) {
    return -1;
  }

  *audioLayer = AudioDeviceModule::kPlatformDefaultAudio;

  return 0;
}

int32_t AudioEngineDevice::InitSpeaker() {
  LOGI() << "InitSpeaker";

  return 0;
}

bool AudioEngineDevice::SpeakerIsInitialized() const {
  LOGI() << "SpeakerIsInitialized";

  return true;
}

int32_t AudioEngineDevice::SpeakerVolumeIsAvailable(bool* available) {
  LOGI() << "SpeakerVolumeIsAvailable";
  if (available == nullptr) {
    return -1;
  }

  *available = false;

  return 0;
}

int32_t AudioEngineDevice::SetSpeakerVolume(uint32_t volume) {
  LOGW() << "SetSpeakerVolume: Not implemented, value: " << volume;

  return -1;
}

int32_t AudioEngineDevice::SpeakerVolume(uint32_t* volume) const {
  LOGW() << "SpeakerVolume: Not implemented";

  return -1;
}

int32_t AudioEngineDevice::MaxSpeakerVolume(uint32_t* maxVolume) const {
  LOGW() << "MaxSpeakerVolume: Not implemented";

  return -1;
}

int32_t AudioEngineDevice::MinSpeakerVolume(uint32_t* minVolume) const {
  LOGW() << "MinSpeakerVolume: Not implemented";

  return -1;
}

int32_t AudioEngineDevice::SpeakerMuteIsAvailable(bool* available) {
  LOGI() << "SpeakerMuteIsAvailable";
  if (available == nullptr) {
    return -1;
  }

  *available = false;

  return 0;
}

int32_t AudioEngineDevice::SetSpeakerMute(bool enable) {
  LOGI() << "SetSpeakerMute: " << enable;

  return -1;
}

int32_t AudioEngineDevice::SpeakerMute(bool* enabled) const {
  LOGW() << "SpeakerMute: Not implemented";

  return -1;
}

int32_t AudioEngineDevice::InitMicrophone() {
  LOGI() << "InitMicrophone";
  RTC_DCHECK_RUN_ON(thread_);

  return 0;
}

bool AudioEngineDevice::MicrophoneIsInitialized() const {
  LOGI() << "MicrophoneIsInitialized";
  RTC_DCHECK_RUN_ON(thread_);

  return true;
}

// ----------------------------------------------------------------------------------------------------
// Microphone Muting

int32_t AudioEngineDevice::MicrophoneMuteIsAvailable(bool* available) {
  RTC_DCHECK_RUN_ON(thread_);
  LOGI() << "MicrophoneMuteIsAvailable";
  if (available == nullptr) {
    return -1;
  }

  *available = true;

  return 0;
}

int32_t AudioEngineDevice::SetMicrophoneMute(bool enable) {
  RTC_DCHECK_RUN_ON(thread_);
  LOGI() << "SetMicrophoneMute: " << enable;

  int32_t result = ModifyEngineState([enable](EngineState state) -> EngineState {
    state.input_muted = enable;
    return state;
  });

  return result;
}

int32_t AudioEngineDevice::MicrophoneMute(bool* enabled) const {
  RTC_DCHECK_RUN_ON(thread_);
  LOGI() << "MicrophoneMute";

  if (enabled == nullptr) {
    return -1;
  }

  *enabled = engine_state_.input_muted;

  return 0;
}

// ----------------------------------------------------------------------------------------------------
// Stereo Playout

int32_t AudioEngineDevice::StereoPlayoutIsAvailable(bool* available) const {
  RTC_DCHECK_RUN_ON(thread_);

  return ResolveStereoPlayoutAvailability(engine_state_, available);
}

int32_t AudioEngineDevice::SetStereoPlayout(bool enable) {
  RTC_DCHECK_RUN_ON(thread_);

  return ModifyEngineState([enable](EngineState state) {
    state.prefers_stereo_playout = enable;
    if (enable) {
      state.voice_processing_enabled = false;
      state.voice_processing_agc_enabled = false;
    }
    return state;
  });
}

int32_t AudioEngineDevice::StereoPlayout(bool* enabled) const {
  RTC_DCHECK_RUN_ON(thread_);
  
  bool stereo_playout_enabled = engine_state_.stereo_playout_enabled;
  LOGI() << "StereoPlayout: " << stereo_playout_enabled;

  if (enabled == nullptr) {
    return -1;
  }
  
  *enabled = stereo_playout_enabled;

  return 0;
}

int32_t AudioEngineDevice::ResolveStereoPlayoutAvailability(const EngineState& state,
                                                            bool* available) const {
  if (available == nullptr) {
    return -1;
  }

  *available = false;

  if (state.render_mode == RenderMode::Manual) {
    LOGI() << "ResolveStereoPlayoutAvailability: Manual rendering mode does not support stereo.";
    *available = false;
    return 0;
  }

#if defined(WEBRTC_IOS)
  AVAudioSession* session = [AVAudioSession sharedInstance];
  NSString* mode = session.mode;
  AVAudioSessionRouteDescription* current_route = session.currentRoute;
  NSString* route_description = current_route.description;

  LOGI() << "ResolveStereoPlayoutAvailability {"
         << "currentRoute: "<< (route_description ? route_description.UTF8String : "unknown")
         << "mode: " << (mode ? mode.UTF8String : "unknown")
         << " }";

  static NSSet<NSString*>* const kMonoModes = [NSSet setWithArray:@[
    AVAudioSessionModeVoiceChat,
    AVAudioSessionModeVideoChat,
    AVAudioSessionModeGameChat
  ]];

  if ([kMonoModes containsObject:mode]) {
    LOGI() << "ResolveStereoPlayoutAvailability: 0 (mode is mono)";
    *available = false;
    return 0;
  }

  NSInteger channel_count = session.outputNumberOfChannels;
  if (channel_count < 2) {
    AVAudioSessionRouteDescription* route = session.currentRoute;
    for (AVAudioSessionPortDescription* port in route.outputs) {
      channel_count = std::max(channel_count, (NSInteger)port.channels.count);
    }
  }

  if (channel_count < 2) {
    LOGI() << "ResolveStereoPlayoutAvailability: 0 (channel count is mono)";
    *available = false;
    return 0;
  }

  LOGI() << "ResolveStereoPlayoutAvailability {"
         << "currentRoute: "<< (route_description ? route_description.UTF8String : "unknown")
         << ", mode: " << (mode ? mode.UTF8String : "unknown")
         << ", channelCount: " << channel_count
         << " }";

  *available = true;
#else
  *available = true;
#endif

  return 0;
}

void AudioEngineDevice::RefreshStereoPlayoutState() {
  RTC_DCHECK_RUN_ON(thread_);
  if (!engine_state_.prefers_stereo_playout) {
    return;
  }

  int32_t result = ModifyEngineState([](EngineState state) -> EngineState {
    return state;
  });
  if (result != 0) {
    LOGE() << "Failed to refresh stereo playout & engine state, error: " << result;
  } else {
    LOGI() << "Refreshed stereo playout & engine state";
  }
}

// ----------------------------------------------------------------------------------------------------
// Stereo Recording

int32_t AudioEngineDevice::StereoRecordingIsAvailable(bool* available) const {
  LOGI() << "StereoRecordingIsAvailable";
  if (available == nullptr) {
    return -1;
  }

  *available = false;

  return 0;
}

int32_t AudioEngineDevice::SetStereoRecording(bool enable) {
  LOGW() << "SetStereoRecording: Not implemented, value: " << enable;

  audio_device_buffer_->SetRecordingChannels(1);

  return 0;
}

int32_t AudioEngineDevice::StereoRecording(bool* enabled) const {
  LOGI() << "StereoRecording";
  if (enabled == nullptr) {
    return -1;
  }

  *enabled = false;

  return 0;
}

// ----------------------------------------------------------------------------------------------------
// Microphone Volume

int32_t AudioEngineDevice::MicrophoneVolumeIsAvailable(bool* available) {
  LOGI() << "MicrophoneVolumeIsAvailable";
  if (available == nullptr) {
    return -1;
  }

  *available = false;

  return 0;
}

int32_t AudioEngineDevice::SetMicrophoneVolume(uint32_t volume) {
  LOGW() << "SetMicrophoneVolume: Not implemented, value: " << volume;

  return -1;
}

int32_t AudioEngineDevice::MicrophoneVolume(uint32_t* volume) const {
  LOGW() << "SetMicrophoneVolume: Not implemented";

  return -1;
}

int32_t AudioEngineDevice::MaxMicrophoneVolume(uint32_t* maxVolume) const {
  LOGW() << "SetMicrophoneVolume: Not implemented";

  return -1;
}

int32_t AudioEngineDevice::MinMicrophoneVolume(uint32_t* minVolume) const {
  LOGW() << "MinMicrophoneVolume: Not implemented";

  return -1;
}

// ----------------------------------------------------------------------------------------------------
// Playout Device

int32_t AudioEngineDevice::PlayoutIsAvailable(bool* available) {
  LOGI() << "PlayoutIsAvailable";
  if (available == nullptr) {
    return -1;
  }

  *available = true;

  return 0;
}

int32_t AudioEngineDevice::SetPlayoutDevice(uint16_t index) {
  LOGI() << "SetPlayoutDevice value: " << index;
  RTC_DCHECK_RUN_ON(thread_);

#if TARGET_OS_OSX
  if (index > (output_device_ids_.size())) {
    LOGE() << "Device index is out of range: " << index;
    return -1;
  }

  // Set as default device if index == 0
  AudioDeviceID output_device_id = index == 0 ? kAudioObjectUnknown : output_device_ids_[index - 1];

  int32_t result = ModifyEngineState([output_device_id](EngineState state) -> EngineState {
    state.output_device_id = output_device_id;
    return state;
  });
  return result;
#else
  return 0;
#endif
}

int32_t AudioEngineDevice::SetPlayoutDevice(AudioDeviceModule::WindowsDeviceType deviceType) {
  LOGW() << "SetPlayoutDevice: Not implemented, value: " << deviceType;

  return -1;
}
int32_t AudioEngineDevice::PlayoutDeviceName(uint16_t index, char name[kAdmMaxDeviceNameSize],
                                             char guid[kAdmMaxGuidSize]) {
  RTC_DCHECK_RUN_ON(thread_);

#if TARGET_OS_OSX
  RTC_DCHECK(output_device_ids_.size() == output_device_labels_.size());

  if ((index > (output_device_ids_.size())) || (name == NULL)) {
    LOGE() << "Device index is out of range: " << index;
    return -1;
  }

  memset(name, 0, kAdmMaxDeviceNameSize);
  memset(guid, 0, kAdmMaxGuidSize);

  // Default device
  if (index == 0) {
    std::optional<AudioDeviceID> default_device_id = mac_audio_utils::GetDefaultOutputDeviceID();
    if (!default_device_id) {
      return -1;
    }

    std::optional<std::string> label = mac_audio_utils::GetDeviceLabel(*default_device_id, false);
    std::optional<std::string> device_guid =
        std::string("default");  // mac_audio_utils::GetDeviceUniqueID(*default_device_id);
    if (!label || !device_guid) {
      return -1;
    }

    strncpy(name, (*label).c_str(), kAdmMaxDeviceNameSize - 1);
    strncpy(guid, (*device_guid).c_str(), kAdmMaxGuidSize - 1);

    return 0;
  }

  // Get device name
  strncpy(name, output_device_labels_[index - 1].c_str(), kAdmMaxDeviceNameSize - 1);

  std::optional<std::string> device_guid =
      mac_audio_utils::GetDeviceUniqueID(output_device_ids_[index - 1]);
  if (device_guid) {
    strncpy(guid, device_guid->c_str(), kAdmMaxGuidSize - 1);
  } else {
    LOGE() << "Failed to get device unique ID for device: " << output_device_ids_[index - 1];
    return -1;
  }

  return 0;
#else
  return -1;
#endif
}

int16_t AudioEngineDevice::PlayoutDevices() {
  RTC_DCHECK_RUN_ON(thread_);

#if TARGET_OS_OSX
  return output_device_ids_.size() + 1;
#else
  return (int16_t)1;
#endif
}

// ----------------------------------------------------------------------------------------------------
// Recording Device

int32_t AudioEngineDevice::RecordingDeviceName(uint16_t index, char name[kAdmMaxDeviceNameSize],
                                               char guid[kAdmMaxGuidSize]) {
#if TARGET_OS_OSX
  RTC_DCHECK(input_device_ids_.size() == input_device_labels_.size());

  if ((index > (input_device_ids_.size())) || (name == NULL)) {
    LOGE() << "Device index is out of range: " << index;
    return -1;
  }

  memset(name, 0, kAdmMaxDeviceNameSize);
  memset(guid, 0, kAdmMaxGuidSize);

  // Default device
  if (index == 0) {
    std::optional<AudioDeviceID> default_device_id = mac_audio_utils::GetDefaultInputDeviceID();
    if (!default_device_id) {
      return -1;
    }

    std::optional<std::string> label = mac_audio_utils::GetDeviceLabel(*default_device_id, true);
    std::optional<std::string> device_guid =
        std::string("default");  // mac_audio_utils::GetDeviceUniqueID(*default_device_id);
    if (!label || !device_guid) {
      return -1;
    }

    strncpy(name, (*label).c_str(), kAdmMaxDeviceNameSize - 1);
    strncpy(guid, (*device_guid).c_str(), kAdmMaxGuidSize - 1);

    return 0;
  }

  // Get device name
  strncpy(name, input_device_labels_[index - 1].c_str(), kAdmMaxDeviceNameSize - 1);

  std::optional<std::string> device_guid =
      mac_audio_utils::GetDeviceUniqueID(input_device_ids_[index - 1]);
  if (device_guid) {
    strncpy(guid, device_guid->c_str(), kAdmMaxGuidSize - 1);
  } else {
    LOGE() << "Failed to get device unique ID for device: " << input_device_ids_[index - 1];
    return -1;
  }

  return 0;
#else
  return -1;
#endif
}

int32_t AudioEngineDevice::SetRecordingDevice(uint16_t index) {
  LOGI() << "SetRecordingDevice, index: " << index;
  RTC_DCHECK_RUN_ON(thread_);

#if TARGET_OS_OSX
  if (index > (input_device_ids_.size())) {
    RTC_LOG(LS_ERROR) << "Device index is out of range";
    return -1;
  }

  // Set as default device if index == 0
  AudioDeviceID input_device_id = index == 0 ? kAudioObjectUnknown : input_device_ids_[index - 1];

  int32_t result = ModifyEngineState([input_device_id](EngineState state) -> EngineState {
    state.input_device_id = input_device_id;
    return state;
  });
  return result;
#else
  return 0;
#endif
}

int32_t AudioEngineDevice::SetRecordingDevice(AudioDeviceModule::WindowsDeviceType type) {
  LOGI() << "SetRecordingDevice, type: " << type;

  return -1;
}

int32_t AudioEngineDevice::RecordingIsAvailable(bool* available) {
  LOGI() << "RecordingIsAvailable";
  if (available == nullptr) {
    return -1;
  }

  *available = true;

  return 0;
}

int16_t AudioEngineDevice::RecordingDevices() {
  RTC_DCHECK_RUN_ON(thread_);

#if TARGET_OS_OSX
  return input_device_ids_.size() + 1;
#else
  return (int16_t)1;
#endif
}

//

int32_t AudioEngineDevice::RegisterAudioCallback(AudioTransport* audioCallback) {
  LOGI() << "RegisterAudioCallback";
  RTC_DCHECK_RUN_ON(thread_);
  RTC_DCHECK(audio_device_buffer_ != nullptr);

  const bool was_playing = audio_device_buffer_->IsPlaying();
  const bool was_recording = audio_device_buffer_->IsRecording();
  const bool needs_restart = was_playing || was_recording;
  const EngineState previous_state = engine_state_;

  // M145 registers the ADM audio transport after default audio options are
  // applied. Stream's custom ADM can already be running by then, while
  // AudioDeviceBuffer rejects callback changes during playout/recording.
  if (needs_restart) {
    LOGW() << "RegisterAudioCallback while active. Restarting audio buffer.";
    int32_t stop_result = ModifyEngineState([](EngineState state) -> EngineState {
      state.output_enabled = false;
      state.output_running = false;
      state.input_enabled = false;
      state.input_running = false;
      state.input_enabled_persistent_mode = false;
      return state;
    });
    if (stop_result != 0) {
      return stop_result;
    }
  }

  int32_t result = audio_device_buffer_->RegisterAudioCallback(audioCallback);

  if (needs_restart) {
    int32_t restart_result =
        ModifyEngineState([previous_state](EngineState /*state*/) -> EngineState {
          return previous_state;
        });
    if (restart_result != 0) {
      return restart_result;
    }
  }

  return result;
}

// ----------------------------------------------------------------------------------------------------
// Misc

bool AudioEngineDevice::BuiltInAECIsAvailable() const { return true; }

bool AudioEngineDevice::BuiltInAGCIsAvailable() const { return true; }

bool AudioEngineDevice::BuiltInNSIsAvailable() const { return false; }

int32_t AudioEngineDevice::EnableBuiltInAEC(bool enable) { return 0; }

int32_t AudioEngineDevice::EnableBuiltInAGC(bool enable) { return 0; }

int32_t AudioEngineDevice::EnableBuiltInNS(bool enable) { return -1; }

// ----------------------------------------------------------------------------------------------------
// Misc

#if defined(WEBRTC_IOS)
int AudioEngineDevice::GetPlayoutAudioParameters(AudioParameters* params) const { return -1; }
int AudioEngineDevice::GetRecordAudioParameters(AudioParameters* params) const { return -1; }
#endif

int32_t AudioEngineDevice::PlayoutDelay(uint16_t* delayMS) const {
  // LOGI() << "PlayoutDelay";
  if (delayMS == nullptr) {
    return -1;
  }

  *delayMS = kFixedPlayoutDelayEstimate;

  return 0;
}

bool AudioEngineDevice::IsEngineRunning() {
  LOGI() << "IsEngineRunning";
  RTC_DCHECK_RUN_ON(thread_);

  if (engine_device_ == nil) return false;
  return engine_device_.running;
}

int32_t AudioEngineDevice::SetEngineState(EngineState new_state) {
  LOGI() << "SetEngineState";
  RTC_DCHECK_RUN_ON(thread_);

  int32_t result =
      ModifyEngineState([new_state](EngineState state) -> EngineState { return new_state; });

  return result;
}

int32_t AudioEngineDevice::GetEngineState(EngineState* state) {
  RTC_DCHECK_RUN_ON(thread_);

  *state = engine_state_;

  return 0;
}

int32_t AudioEngineDevice::SetObserver(AudioDeviceObserver* observer) {
  LOGI() << "SetObserver";
  RTC_DCHECK_RUN_ON(thread_);

  observer_ = observer;

  return 0;
}

// ----------------------------------------------------------------------------------------------------
// Unique methods to AudioEngineDevice

int32_t AudioEngineDevice::VoiceProcessingBypassed(bool* enabled) {
  LOGI() << "VoiceProcessingBypassed";
  RTC_DCHECK_RUN_ON(thread_);

  if (enabled == nullptr) {
    return -1;
  }

  *enabled = engine_state_.voice_processing_bypassed;

  return 0;
}

int32_t AudioEngineDevice::SetVoiceProcessingEnabled(bool enable) {
  RTC_DCHECK_RUN_ON(thread_);
  LOGI() << "SetVoiceProcessingEnabled: " << enable;

  if (enable && engine_state_.prefers_stereo_playout) {
    LOGI() << "SetVoiceProcessingEnabled: Overriding to false due to stereo playout preference.";
    enable = false;
  }

  int32_t result = ModifyEngineState([enable](EngineState state) -> EngineState {
    state.voice_processing_enabled = enable;
    return state;
  });

  return result;
}

int32_t AudioEngineDevice::VoiceProcessingEnabled(bool* enabled) {
  LOGI() << "VoiceProcessingEnabled";
  RTC_DCHECK_RUN_ON(thread_);

  if (enabled == nullptr) {
    return -1;
  }

  *enabled = engine_state_.voice_processing_enabled;

  return 0;
}

int32_t AudioEngineDevice::SetVoiceProcessingBypassed(bool enable) {
  RTC_DCHECK_RUN_ON(thread_);
  LOGI() << "SetVoiceProcessingBypassed: " << enable;

  int32_t result = ModifyEngineState([enable](EngineState state) -> EngineState {
    state.voice_processing_bypassed = enable;
    return state;
  });

  return result;
}

int32_t AudioEngineDevice::VoiceProcessingAGCEnabled(bool* enabled) {
  LOGI() << "VoiceProcessingAGCEnabled";
  RTC_DCHECK_RUN_ON(thread_);

  if (enabled == nullptr) {
    return -1;
  }

  *enabled = engine_state_.voice_processing_agc_enabled;

  return 0;
}

int32_t AudioEngineDevice::SetVoiceProcessingAGCEnabled(bool enable) {
  RTC_DCHECK_RUN_ON(thread_);
  LOGI() << "SetVoiceProcessingAGCEnabled: " << enable;

  if (enable && engine_state_.prefers_stereo_playout) {
    LOGI() << "SetVoiceProcessingAGCEnabled: Overriding to false due to stereo playout preference.";
    enable = false;
  }

  int32_t result = ModifyEngineState([enable](EngineState state) -> EngineState {
    state.voice_processing_agc_enabled = enable;
    return state;
  });

  return result;
}

int32_t AudioEngineDevice::SetEngineAvailability(bool input_available, bool output_available) {
  RTC_DCHECK_RUN_ON(thread_);
  LOGI() << "SetEngineAvailability: " << input_available << " " << output_available;

  int32_t result =
      ModifyEngineState([input_available, output_available](EngineState state) -> EngineState {
        state.input_available = input_available;
        state.output_available = output_available;
        return state;
      });

  return result;
}

int32_t AudioEngineDevice::EngineAvailability(bool* input_available, bool* output_available) {
  RTC_DCHECK_RUN_ON(thread_);

  if (input_available == nullptr || output_available == nullptr) {
    return -1;
  }

  *input_available = engine_state_.input_available;
  *output_available = engine_state_.output_available;

  return 0;
}

int32_t AudioEngineDevice::ManualRenderingMode(bool* enabled) {
  LOGI() << "ManualRenderingMode";
  RTC_DCHECK_RUN_ON(thread_);

  if (enabled == nullptr) {
    return -1;
  }

  *enabled = engine_state_.render_mode == RenderMode::Manual;

  return 0;
}

int32_t AudioEngineDevice::SetManualRenderingMode(bool enable) {
  RTC_DCHECK_RUN_ON(thread_);
  LOGI() << "SetManualRenderingMode: " << enable;

  int32_t result = ModifyEngineState([enable](EngineState state) -> EngineState {
    state.render_mode = enable ? RenderMode::Manual : RenderMode::Device;
    return state;
  });

  return result;
}

int32_t AudioEngineDevice::GetMuteMode(MuteMode* mode) {
  LOGI() << "GetMuteMode";
  RTC_DCHECK_RUN_ON(thread_);

  if (mode == nullptr) {
    return -1;
  }

  *mode = engine_state_.mute_mode;

  return 0;
}

int32_t AudioEngineDevice::SetMuteMode(MuteMode mode) {
  RTC_DCHECK_RUN_ON(thread_);
  LOGI() << "SetMuteMode: " << mode;

  int32_t result = ModifyEngineState([mode](EngineState state) -> EngineState {
    state.mute_mode = mode;
    return state;
  });

  return result;
}

int32_t AudioEngineDevice::InitAndStartRecording() {
  RTC_DCHECK_RUN_ON(thread_);
  LOGI() << "InitAndStartRecording";

  int32_t result = ModifyEngineState([](EngineState state) -> EngineState {
    state.input_enabled = true;
    state.input_running = true;
    state.input_muted = false;  // Always unmute
    return state;
  });

  return result;
}

int32_t AudioEngineDevice::SetAdvancedDucking(bool enable) {
  RTC_DCHECK_RUN_ON(thread_);
  LOGI() << "SetAdvancedDucking: " << enable;

  int32_t result = ModifyEngineState([enable](EngineState state) -> EngineState {
    state.advanced_ducking = enable;
    return state;
  });

  return result;
}

int32_t AudioEngineDevice::AdvancedDucking(bool* enabled) {
  RTC_DCHECK_RUN_ON(thread_);

  if (enabled == nullptr) {
    return -1;
  }

  *enabled = engine_state_.advanced_ducking;
  LOGI() << "AdvancedDucking value: " << *enabled;

  return 0;
}

int32_t AudioEngineDevice::SetDuckingLevel(long level) {
  RTC_DCHECK_RUN_ON(thread_);
  LOGI() << "SetDuckingLevel: " << level;

  int32_t result = ModifyEngineState([level](EngineState state) -> EngineState {
    state.ducking_level = level;
    return state;
  });

  return result;
}

int32_t AudioEngineDevice::DuckingLevel(long* level) {
  LOGI() << "DuckingLevel";
  RTC_DCHECK_RUN_ON(thread_);

  if (level == nullptr) {
    return -1;
  }

  *level = engine_state_.ducking_level;
  LOGI() << "DuckingLevel value: " << *level;

  return 0;
}

int32_t AudioEngineDevice::SetInitRecordingPersistentMode(bool enable) {
  RTC_DCHECK_RUN_ON(thread_);
  LOGI() << "SetInitRecordingPersistentMode: " << enable;

  int32_t result = ModifyEngineState([enable](EngineState state) -> EngineState {
    state.input_enabled_persistent_mode = enable;
    return state;
  });

  return result;
}

int32_t AudioEngineDevice::InitRecordingPersistentMode(bool* enabled) {
  LOGI() << "InitRecordingPersistentMode";
  RTC_DCHECK_RUN_ON(thread_);

  if (enabled == nullptr) {
    return -1;
  }

  *enabled = engine_state_.input_enabled_persistent_mode;
  LOGI() << "InitRecordingPersistentMode value: " << *enabled;

  return 0;
}

// ----------------------------------------------------------------------------------------------------
// Private - Engine Related

void AudioEngineDevice::ReconfigureEngine(
    bool restore_media_services_recovery_on_failure) {
  LOGI() << "ReconfigureEngine";

  // TODO: More optimizations
  // We only need to re-attach the input / output nodes with updated sample rate etc.

  thread_->PostTask(
      SafeTask(safety_, [this, restore_media_services_recovery_on_failure] {
        RTC_DCHECK_RUN_ON(thread_);

        // Snapshot on the device thread so stop and availability updates are
        // ordered before or after the complete recovery transition.
        EngineState current_state = this->engine_state_;

        // Re-configure is only for device mode
        if (current_state.render_mode != RenderMode::Device) return;

        EngineState shutdown_state = this->engine_state_;
        shutdown_state.input_enabled = false;
        shutdown_state.input_running = false;
        shutdown_state.output_enabled = false;
        shutdown_state.output_running = false;

        int32_t shutdown_result = this->ModifyEngineState(
            [shutdown_state](EngineState state) -> EngineState {
              return shutdown_state;  // Shutdown engine
            });

        if (shutdown_result != 0) {
          LOGE() << "ReconfigureEngine: Failed to shutdown engine, error: "
                 << shutdown_result;
          if (restore_media_services_recovery_on_failure) {
            should_reconfigure_after_media_services_reset_.store(true);
          }
          return;
        }

        int32_t recover_result = this->ModifyEngineState(
            [current_state](EngineState state) -> EngineState {
              return current_state;  // Recover engine state
            });

        if (recover_result != 0) {
          LOGE() << "ReconfigureEngine: Failed to recover engine state, error: "
                 << recover_result;
          if (restore_media_services_recovery_on_failure) {
            should_reconfigure_after_media_services_reset_.store(true);
          }
          // We're in a bad state now, could consider more recovery options here
        }
      }));
}

bool AudioEngineDevice::IsMicrophonePermissionGranted() {
  AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
  return status == AVAuthorizationStatusAuthorized;
}

void AudioEngineDevice::ResetEngineState() {
  LOGI() << "ResetEngineState";
  RTC_DCHECK_RUN_ON(thread_);

  int32_t result =
      ModifyEngineState([](EngineState /*state*/) -> EngineState {
        EngineState reset;
        return reset;
      });
  if (result != 0) {
    LOGE() << "ResetEngineState: failed to reset engine state, error: " << result;
    return;
  }
}

int32_t AudioEngineDevice::ModifyEngineState(
    std::function<EngineState(EngineState)> state_transform) {
  RTC_DCHECK_RUN_ON(thread_);

  LOGI() << "ModifyEngineState [Begin] --------------------------------";
  
  EngineState old_state = engine_state_;
  EngineState new_state = state_transform(old_state);
  EngineStateUpdate state = {old_state, new_state};

  // Evaluate stereo playout availability for new state.
  bool stereo_available = false;
  if (ResolveStereoPlayoutAvailability(state.next, &stereo_available) == 0) {
    state.next.stereo_playout_available = state.next.prefers_stereo_playout && stereo_available;
  } else {
    LOGE() << "ModifyEngineState: Failed to resolve stereo playout availability";
    state.next.stereo_playout_available = false;
  }

  // --------------------------------------------------------------------------------------------
  // Step: Debugging Output
  //
  LOGI() << "ModifyEngineState: Plan {"
         << " HasNoChanges: " << state.HasNoChanges()
         << ", DidEnableOutput: " << state.DidEnableOutput()
         << ", DidEnableInput: " << state.DidEnableInput()
         << ", DidDisableOutput: " << state.DidDisableOutput()
         << ", DidDisableInput: " << state.DidDisableInput()
         << ", DidAnyEnable: " << state.DidAnyEnable()
         << ", DidAnyDisable: " << state.DidAnyDisable()
         << ", DidBeginInterruption: " << state.DidBeginInterruption()
         << ", DidEndInterruption: " << state.DidEndInterruption()
         << ", DidUpdateAudioGraph: " << state.DidUpdateAudioGraph()
         << ", DidUpdateVoiceProcessingEnabled: " << state.DidUpdateVoiceProcessingEnabled()
         << ", DidUpdateOutputDevice: " << state.DidUpdateOutputDevice()
         << ", DidUpdateInputDevice: " << state.DidUpdateInputDevice()
         << ", DidUpdateDefaultOutputDevice: " << state.DidUpdateDefaultOutputDevice()
         << ", DidUpdateDefaultInputDevice: " << state.DidUpdateDefaultInputDevice()
         << ", DidUpdateMuteMode: " << state.DidUpdateMuteMode()
         << ", IsEngineRestartRequired: " << state.IsEngineRestartRequired()
         << ", IsEngineRecreateRequired: " << state.IsEngineRecreateRequired()
         << ", DidEnableManualRenderingMode: " << state.DidEnableManualRenderingMode()
         << ", DidEnableDeviceRenderingMode: " << state.DidEnableDeviceRenderingMode()
         << ", DidUpdateDesiredOutputChannels: " << state.DidUpdateDesiredOutputChannels()
         << " }";
  DebugEngineState("ModifyEngineState: Previous State", state.prev);
  DebugEngineState("ModifyEngineState: Next State", state.next);

  // No changes, return immediately.
  if (state.HasNoChanges()) {
    LOGI() << "ModifyEngineState: No changes";
    LOGI() << "ModifyEngineState [End] --------------------------------";
    return 0;
  }

  // Check input should be enabled if running.
  if (state.next.input_running && !state.next.input_enabled) {
    LOGE() << "ModifyEngineState: Input must be enabled if running";
    LOGI() << "ModifyEngineState [End] --------------------------------";
    return -1;
  }

  // Check output should be enabled if running.
  if (state.next.output_running && !state.next.output_enabled) {
    LOGE() << "ModifyEngineState: Output must be enabled if running";
    LOGI() << "ModifyEngineState [End] --------------------------------";
    return -1;
  }

  int32_t shutdown_result = 0;
  int32_t startup_result = 0;

  // Did switch Device -> Manual rendering
  if (state.DidEnableManualRenderingMode()) {
    EngineStateUpdate shutdown_state = state;                  // Copy current state
    shutdown_state.next = {};                                  // Reset next state to default
    shutdown_result = ApplyDeviceEngineState(shutdown_state);  // Shutdown device rendering
    if (shutdown_result != 0) {
      LOGE() << "ModifyEngineState: Failed to shutdown device rendering, error: "
             << shutdown_result;
    }
    EngineStateUpdate startup_state = state;                 // Copy current state
    shutdown_state.prev = {};                                //
    startup_result = ApplyManualEngineState(startup_state);  // Start manual mode
    if (startup_result != 0) {
      LOGE() << "ModifyEngineState: Failed to start manual mode, error: " << startup_result;
    }
  } else if (state.DidEnableDeviceRenderingMode()) {
    EngineStateUpdate shutdown_state = state;
    shutdown_state.next = {};                                  // Reset next state to default
    shutdown_result = ApplyManualEngineState(shutdown_state);  // Shutdown manual rendering
    if (shutdown_result != 0) {
      LOGE() << "ModifyEngineState: Failed to shutdown manual rendering, error: "
             << shutdown_result;
    }
    EngineStateUpdate startup_state = state;                 // Copy current state
    shutdown_state.prev = {};                                //
    startup_result = ApplyDeviceEngineState(startup_state);  // Start device mode
    if (startup_result != 0) {
      LOGE() << "ModifyEngineState: Failed to start device mode, error: " << startup_result;
    }
  } else if (state.next.render_mode == RenderMode::Device) {
    shutdown_result = ApplyDeviceEngineState(state);
    if (shutdown_result != 0) {
      LOGE() << "ModifyEngineState: Failed to update state in device mode, error: "
             << shutdown_result;
    }
  } else if (state.next.render_mode == RenderMode::Manual) {
    startup_result = ApplyManualEngineState(state);
    if (startup_result != 0) {
      LOGE() << "ModifyEngineState: Failed to update state in manual mode, error: "
             << startup_result;
    }
  }

  int32_t return_result = shutdown_result != 0 ? shutdown_result : startup_result;

  // Additional checks for buffer state.
  if (return_result == 0) {
    // Buffer should be playing if output is running.
    if (state.next.IsOutputEnabled()) {
      RTC_DCHECK(audio_device_buffer_->IsPlaying());
      if (!audio_device_buffer_->IsPlaying()) {
        LOGE() << "ModifyEngineState: Buffer should be playing when output is enabled";
      }
    } else {
      RTC_DCHECK(!audio_device_buffer_->IsPlaying());
      if (audio_device_buffer_->IsPlaying()) {
        LOGE() << "ModifyEngineState: Buffer should not be playing when output is disabled";
      }
    }

    // Buffer should be recording if input is running.
    if (state.next.IsInputEnabled()) {
      RTC_DCHECK(audio_device_buffer_->IsRecording());
      if (!audio_device_buffer_->IsRecording()) {
        LOGE() << "ModifyEngineState: Buffer should be recording when input is enabled";
      }
    } else {
      RTC_DCHECK(!audio_device_buffer_->IsRecording());
      if (audio_device_buffer_->IsRecording()) {
        LOGE() << "ModifyEngineState: Buffer should not be recording when input is disabled";
      }
    }

    // Notify observer of processing state changes if any
    NotifyProcessingStateObserver(state);
    
    // Update engine state if no error
    engine_state_ = state.next;
    const char* update_state =
        state.IsEngineRecreateRequired()
            ? "Recreated"
            : (state.IsEngineRestartRequired() ? "Restarted" : "Updated");
    std::string prefix = std::string("ModifyEngineState: ") + update_state;
    DebugEngineState(prefix, state.next);
    LOGI() << "ModifyEngineState [End] --------------------------------";
  }

  return return_result;
}

void AudioEngineDevice::NotifyProcessingStateObserver(EngineStateUpdate state) {
  RTC_DCHECK_RUN_ON(thread_);

  AudioProcessingState proc_state;
  proc_state.voice_processing_enabled = state.next.voice_processing_enabled;
  proc_state.voice_processing_bypassed = state.next.voice_processing_bypassed;
  proc_state.voice_processing_agc_enabled = state.next.voice_processing_agc_enabled;
  proc_state.stereo_playout_enabled = state.next.stereo_playout_enabled;

  bool processing_state_updated = state.prev.voice_processing_enabled !=  state.next.voice_processing_enabled ||
                    state.prev.voice_processing_bypassed != state.next.voice_processing_bypassed ||
                    state.prev.voice_processing_agc_enabled != state.next.voice_processing_agc_enabled ||
                    state.prev.stereo_playout_enabled != state.next.stereo_playout_enabled;

  if (observer_ && processing_state_updated) {
    observer_->OnAudioProcessingStateChanged(proc_state);
  }
}

int32_t AudioEngineDevice::ApplyManualEngineState(EngineStateUpdate& state) {
  RTC_DCHECK_RUN_ON(thread_);
  RTC_DCHECK(engine_device_ == nullptr);

  auto outputNode = [this, state]() {
    RTC_DCHECK_RUN_ON(thread_);
    RTC_DCHECK(engine_manual_input_ != nil);
    RTC_DCHECK(state.prev.IsOutputEnabled() || state.next.IsOutputEnabled());
    return engine_manual_input_.outputNode;
  };

  if (state.prev.IsAnyRunning() && !state.next.IsAnyRunning()) {
    LOGI() << "Stopping AVAudioEngine...";
    RTC_DCHECK(engine_manual_input_ != nil);
    [engine_manual_input_ stop];

    LOGI() << "Stopping render thread...";
    RTC_DCHECK(render_thread_ != nullptr);
    render_thread_->Stop();
    render_thread_ = nullptr;

    LOGI() << "Releasing manual render buffer...";
    RTC_DCHECK(render_buffer_ != nullptr);
    render_buffer_ = nullptr;

    LOGI() << "Releasing manual read buffer...";
    RTC_DCHECK(read_buffer_ != nullptr);
    read_buffer_ = nullptr;

    if (observer_ != nullptr) {
      int32_t result = observer_->OnEngineDidStop(
          engine_manual_input_, state.next.IsOutputEnabled(), state.next.IsInputEnabled());
      if (result != 0) {
        LOGE() << "Call to OnEngineDidStop returned error: " << result;
        return result;
      }
    }
  }

  if (state.next.IsAnyEnabled() && !state.prev.IsAnyEnabled()) {
    LOGI() << "Creating AVAudioEngine (manual)...";
    RTC_DCHECK(engine_manual_input_ == nullptr);
    engine_manual_input_ = [[AVAudioEngine alloc] init];

    NSError* error = nil;
    BOOL result =
        [engine_manual_input_ enableManualRenderingMode:AVAudioEngineManualRenderingModeRealtime
                                                 format:manual_render_rtc_format_
                                      maximumFrameCount:kMaximumFramesPerBuffer
                                                  error:&error];
    if (!result) {
      LOGE() << "Failed to set manual rendering mode: " << error.localizedDescription.UTF8String;
    }

    if (observer_ != nullptr) {
      int32_t observer_result = observer_->OnEngineDidCreate(engine_manual_input_);
      if (observer_result != 0) {
        LOGE() << "Call to OnEngineDidCreate returned error: " << observer_result;
        return observer_result;
      }
    }
  }

  if (!state.next.IsOutputEnabled() && audio_device_buffer_->IsPlaying()) {
    LOGI() << "Stopping Playout buffer...";
    if (engine_device_ != nullptr) {
      // Rendering must be stopped first.
      RTC_DCHECK(!engine_device_.running);
    }
    audio_device_buffer_->StopPlayout();
  }

  if (!state.next.IsInputEnabled() && audio_device_buffer_->IsRecording()) {
    LOGI() << "Stopping Record buffer...";
    if (engine_device_ != nullptr) {
      // Rendering must be stopped first.
      RTC_DCHECK(!engine_device_.running);
    }
    audio_device_buffer_->StopRecording();
  }

  if (state.DidAnyEnable() && observer_ != nullptr) {
    // Invoke here before configuring nodes. In iOS, session configuration is required before
    // enabling AGC, muted talker etc.
    int32_t result = observer_->OnEngineWillEnable(
        engine_manual_input_, state.next.IsOutputEnabled(), state.next.IsInputEnabled());
    if (result != 0) {
      LOGE() << "Call to OnEngineWillEnable returned error: " << result;
      return result;
    }
  }

  if (state.next.IsOutputEnabled() && !state.prev.IsOutputEnabled()) {
    LOGI() << "Enabling output for AVAudioEngine...";
    RTC_DCHECK(!engine_manual_input_.running);

    const uint32_t desired_channels = state.next.DesiredOutputChannels();
    // Manual mode controls its own graph, so clamp only to ≥1.
    const uint32_t applied_channels = std::max<uint32_t>(1, desired_channels);
    state.next.stereo_playout_enabled = applied_channels >= 2;
    if (desired_channels >= 2 && !state.next.stereo_playout_enabled) {
      LOGW() << "Manual mode requested stereo but fell back to mono.";
    }

    manual_render_rtc_format_ = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16
                                                                 sampleRate:48000
                                                                   channels:applied_channels
                                                                interleaved:YES];

    audio_device_buffer_->SetPlayoutSampleRate(manual_render_rtc_format_.sampleRate);
    audio_device_buffer_->SetPlayoutChannels(manual_render_rtc_format_.channelCount);
    fine_audio_buffer_.reset(new FineAudioBuffer(audio_device_buffer_.get()));

    if (state.next.IsInputEnabled()) {
      // Capture the native result so manual mode honors the same VP guarantee.
      int32_t result =
          ConfigureVoiceProcessingNode(engine_manual_input_.inputNode, state);
      // Stop setup if the requested processing could not be applied.
      if (result != 0) {
        // Surface the error instead of recording with degraded call audio.
        return result;
      }
    }

  } else if (state.prev.IsOutputEnabled() && !state.next.IsOutputEnabled()) {
    LOGI() << "Disabling output for AVAudioEngine...";
    RTC_DCHECK(!engine_manual_input_.running);
  }

  if (state.next.IsInputEnabled() && !state.prev.IsInputEnabled()) {
    LOGI() << "Enabling input for AVAudioEngine...";
    RTC_DCHECK(!engine_manual_input_.running);

    audio_device_buffer_->SetRecordingSampleRate(manual_render_rtc_format_.sampleRate);
    audio_device_buffer_->SetRecordingChannels(1);  // Always mono for input
    RTC_DCHECK(audio_device_buffer_ != nullptr);
    fine_audio_buffer_.reset(new FineAudioBuffer(audio_device_buffer_.get()));

    if (this->observer_ != nullptr) {
      NSDictionary* context = @{};
      int32_t result = this->observer_->OnEngineWillConnectInput(
          engine_manual_input_, nil, engine_manual_input_.mainMixerNode, manual_render_rtc_format_,
          context);
      if (result != 0) {
        LOGE() << "Call to OnEngineWillConnectInput returned error: " << result;
        return result;
      }
    }

    @try {
      [engine_manual_input_ connect:engine_manual_input_.mainMixerNode
                                 to:outputNode()
                             format:manual_render_rtc_format_];
    } @catch (NSException* exception) {
      // Keep the connection failure diagnostic safe when NSException provides no reason.
      LOGE() << "Failed to connect manual input nodes: "
             << (exception.reason ? exception.reason.UTF8String : "Unknown");
      return kAudioEngineDeviceFormatError;
    }

  } else if (state.prev.IsInputEnabled() && !state.next.IsInputEnabled()) {
    LOGI() << "Disabling input for AVAudioEngine...";
    RTC_DCHECK(!engine_manual_input_.running);
  }

  if (state.DidAnyDisable() && observer_ != nullptr) {
    int32_t result = observer_->OnEngineDidDisable(
        engine_manual_input_, state.next.IsOutputEnabled(), state.next.IsInputEnabled());
    if (result != 0) {
      LOGE() << "Call to OnEngineDidDisable returned error: " << result;
      return result;
    }
  }

  // Start playout buffer if output is running
  if (state.next.IsOutputEnabled() && !audio_device_buffer_->IsPlaying()) {
    if (engine_device_ != nullptr) {
      // Rendering must be stopped first.
      RTC_DCHECK(!engine_device_.running);
    }
    LOGI() << "Starting Playout buffer...";
    audio_device_buffer_->StartPlayout();
    fine_audio_buffer_->ResetPlayout();
  }

  // Start recording buffer if input is running
  if (state.next.IsInputEnabled() && !audio_device_buffer_->IsRecording()) {
    if (engine_device_ != nullptr) {
      // Rendering must be stopped first.
      RTC_DCHECK(!engine_device_.running);
    }
    LOGI() << "Starting Record buffer...";
    audio_device_buffer_->StartRecording();
    fine_audio_buffer_->ResetRecord();
  }

  if (state.next.IsAnyRunning() && !state.prev.IsAnyRunning()) {
    if (observer_ != nullptr) {
      int32_t result = observer_->OnEngineWillStart(
          engine_manual_input_, state.next.IsOutputEnabled(), state.next.IsInputEnabled());
      if (result != 0) {
        LOGE() << "Call to OnEngineWillStart returned error: " << result;
        return result;
      }
    }

    LOGI() << "Allocating manual render buffer...";
    RTC_DCHECK(render_buffer_ == nullptr);
    render_buffer_ = [[AVAudioPCMBuffer alloc] initWithPCMFormat:manual_render_rtc_format_
                                                   frameCapacity:kMaximumFramesPerBuffer];

    LOGI() << "Allocating manual read buffer...";
    RTC_DCHECK(read_buffer_ == nullptr);
    read_buffer_ = [[AVAudioPCMBuffer alloc] initWithPCMFormat:manual_render_rtc_format_
                                                 frameCapacity:kMaximumFramesPerBuffer];

    LOGI() << "Starting AVAudioEngine...";
    NSError* error = nil;

    BOOL start_result = [engine_manual_input_ startAndReturnError:&error];
    if (!start_result) {
      LOGE() << "Failed to start engine after " << kStartEngineMaxRetries << " attempts";
      DebugAudioEngine();
    }

    // Assign manual rendering block
    render_block_ = engine_manual_input_.manualRenderingBlock;
    RTC_DCHECK(render_block_ != nullptr);

    // Create render thread
    LOGI() << "Starting render thread...";
    RTC_DCHECK(render_thread_ == nullptr);
    render_thread_ = webrtc::Thread::Create();
    render_thread_->SetName("render_thread", nullptr);
    render_thread_->Start();
    render_thread_->PostTask([this] { this->StartRenderLoop(); });
  }

  if (state.prev.IsAnyEnabled() && !state.next.IsAnyEnabled()) {
    if (observer_ != nullptr) {
      int32_t result = observer_->OnEngineWillRelease(engine_manual_input_);
      if (result != 0) {
        LOGE() << "Call to OnEngineWillRelease returned error: " << result;
        return result;
      }
    }
    LOGI() << "Releasing AVAudioEngine...";
    engine_manual_input_ = nil;
  }

  return 0;
}

int32_t AudioEngineDevice::ApplyDeviceEngineState(EngineStateUpdate& state) {
  RTC_DCHECK_RUN_ON(thread_);
  RTC_DCHECK(engine_manual_input_ == nullptr);

  std::vector<std::function<void()>> rollback_actions;

  auto rollback = [&](int32_t result) {
    for (auto& action : rollback_actions) {
      action();
    }

    return result;
  };

  auto inputNode = [this, state]() {
    RTC_DCHECK_RUN_ON(thread_);
    RTC_DCHECK(engine_device_ != nil);
    RTC_DCHECK(state.prev.IsInputEnabled() || state.next.IsInputEnabled());
    return engine_device_.inputNode;
  };

  auto outputNode = [this, state]() {
    RTC_DCHECK_RUN_ON(thread_);
    RTC_DCHECK(engine_device_ != nil);
    RTC_DCHECK(state.prev.IsOutputEnabled() || state.next.IsOutputEnabled());
    return engine_device_.outputNode;
  };

  // Keep every release and observer notification identical across retries,
  // normal recreation, and final shutdown.
  auto releaseEngine = [this]() {
    // AVAudioEngine ownership is confined to the device-control thread.
    RTC_DCHECK_RUN_ON(thread_);
    // Give the owner a chance to detach from the engine before destruction.
    if (observer_ != nullptr) {
      // Preserve the observer's error so lifecycle recovery remains atomic.
      int32_t result = observer_->OnEngineWillRelease(engine_device_);
      // Do not discard an engine the observer failed to release safely.
      if (result != 0) {
        // Record which lifecycle callback prevented the transition.
        LOGE() << "Call to OnEngineWillRelease returned error: " << result;
        // Propagate the exact callback failure to the state transition.
        return result;
      }
    }
    // Drain callbacks before graph release can free their converter resources.
    InvalidateInputRenderContext();
    // Drop the old graph only after all owners have released it.
    engine_device_ = nil;
    // Report that the engine is fully released and safe to replace.
    return 0;
  };

  // Keep engine allocation and observer attachment identical for retries and
  // ordinary state transitions.
  auto createEngine = [this]() {
    // AVAudioEngine ownership is confined to the device-control thread.
    RTC_DCHECK_RUN_ON(thread_);
    // A fresh graph avoids reconnecting nodes on the stopped I/O unit.
    engine_device_ = [[AVAudioEngine alloc] init];
    // Let the owner attach its configuration to this exact engine instance.
    if (observer_ != nullptr) {
      // Preserve the observer's result so a partial create cannot continue.
      int32_t result = observer_->OnEngineDidCreate(engine_device_);
      // Stop before node configuration when owner setup failed.
      if (result != 0) {
        // Record which lifecycle callback prevented engine creation.
        LOGE() << "Call to OnEngineDidCreate returned error: " << result;
        // Propagate the callback failure to the transaction rollback.
        return result;
      }
    }
    // Report that a fresh engine and its observer state are ready.
    return 0;
  };

  // Reapply session-dependent owner configuration to every fresh retry engine.
  auto prepareEngine = [this, &state]() {
    // AVAudioEngine ownership is confined to the device-control thread.
    RTC_DCHECK_RUN_ON(thread_);
    // Notify only for transitions that enable media and have an observer.
    if (state.DidAnyEnable() && observer_ != nullptr) {
      // Configure the audio session before voice-processing touches the graph.
      int32_t result =
          observer_->OnEngineWillEnable(engine_device_,
                                        state.next.IsOutputEnabled(),
                                        state.next.IsInputEnabled());
      // Stop before node configuration when session preparation failed.
      if (result != 0) {
        // Record which lifecycle callback prevented engine preparation.
        LOGE() << "Call to OnEngineWillEnable returned error: " << result;
        // Propagate the callback failure to the transaction rollback.
        return result;
      }
    }
    // Report that node configuration may safely proceed.
    return 0;
  };

  // --------------------------------------------------------------------------------------------
  // Step: Stop AVAudioEngine
  //
  if (state.prev.IsAnyRunning() &&
      (!state.next.IsAnyRunning() || state.IsEngineRestartRequired() ||
       state.DidBeginInterruption() || state.IsEngineRecreateRequired())) {
    LOGI() << "Stopping AVAudioEngine...";
    RTC_DCHECK(engine_device_ != nil);

    if (configuration_observer_ != nullptr) {
      NSNotificationCenter* center = [NSNotificationCenter defaultCenter];
      [center removeObserver:(__bridge_transfer id)configuration_observer_
                        name:AVAudioEngineConfigurationChangeNotification
                      object:engine_device_];
      configuration_observer_ = nil;
    }

    [engine_device_ stop];

    if (observer_ != nullptr) {
      int32_t result = observer_->OnEngineDidStop(engine_device_, state.next.IsOutputEnabled(),
                                                  state.next.IsInputEnabled());
      if (result != 0) {
        LOGE() << "Call to OnEngineDidStop returned error: " << result;
        return rollback(result);
      }
    }
  }

  // --------------------------------------------------------------------------------------------
  // Step: Recreate AVAudioEngine
  //
  if (state.IsEngineRecreateRequired()) {
    LOGI() << "Recreate required, releasing AVAudioEngine...";
    // Use the shared release path so observer ordering matches retry recovery.
    int32_t result = releaseEngine();
    // Preserve the existing rollback semantics when release fails.
    if (result != 0) {
      // Undo earlier transition work and return the release error.
      return rollback(result);
    }
  }

  // --------------------------------------------------------------------------------------------
  // Step: Create AVAudioEngine
  //
  if (state.next.IsAnyEnabled() &&
      (!state.prev.IsAnyEnabled() || state.IsEngineRecreateRequired())) {
    LOGI() << "Creating AVAudioEngine (device)...";
    RTC_DCHECK(engine_device_ == nil);

    rollback_actions.push_back([=, this]() {
      RTC_DCHECK_RUN_ON(thread_);
      LOGI() << "Rolling back create AVAudioEngine (device)...";
      engine_device_ = nil;
    });

    // Use the shared creation path so initial and retry engines are equivalent.
    int32_t result = createEngine();
    // Preserve the existing rollback semantics when creation fails.
    if (result != 0) {
      // Undo earlier transition work and return the creation error.
      return rollback(result);
    }
  }

  // --------------------------------------------------------------------------------------------
  // Step: Stop playout buffer
  //
  if (!state.next.IsOutputEnabled() && audio_device_buffer_->IsPlaying()) {
    LOGI() << "Stopping Playout buffer...";
    if (engine_device_ != nullptr) {
      // Rendering must be stopped first.
      RTC_DCHECK(!engine_device_.running);
    }
    audio_device_buffer_->StopPlayout();
  }

  // --------------------------------------------------------------------------------------------
  // Step: Stop recording buffer
  //
  if (!state.next.IsInputEnabled() && audio_device_buffer_->IsRecording()) {
    LOGI() << "Stopping Record buffer...";
    if (engine_device_ != nullptr) {
      // Rendering must be stopped first.
      RTC_DCHECK(!engine_device_.running);
    }
    audio_device_buffer_->StopRecording();
  }

  // --------------------------------------------------------------------------------------------
  // Step: Trigger "engine will enable" event
  //
  // Invoke here before configuring nodes. In iOS, session configuration is
  // required before enabling AGC, muted talker etc.
  // Use the shared preparation path so retries preserve lifecycle ordering.
  int32_t prepare_result = prepareEngine();
  // Do not touch nodes when the owner could not prepare the audio session.
  if (prepare_result != 0) {
    // Roll back the transition and return the preparation failure.
    return rollback(prepare_result);
  }

  // --------------------------------------------------------------------------------------------
  // Step: Configure Voice-Processing I/O
  //
  // - Note: We configure input VP before output to avoid artifacts playout during configuration.
  //
  if (state.next.IsInputEnabled()) {
    // Attempt VP before output setup so unprocessed input is never started.
    int32_t voice_processing_result =
        ConfigureVoiceProcessingNode(inputNode(), state);
    // Count the first attempt so the retry bound includes all engine graphs.
    UInt16 attempt = 1;

    // Retry only native VP failures and stop at the fixed recovery bound.
    while (voice_processing_result != 0 &&
           attempt < kVoiceProcessingMaxRetries) {
      // Make retry progress visible without exposing raw audio data.
      LOGW() << "Retrying voice processing on a fresh engine (attempt "
             << (attempt + 1) << "/" << kVoiceProcessingMaxRetries << ")";

      // Fully release the failed graph before allocating its replacement.
      int32_t release_result = releaseEngine();
      // Stop recovery if the failed graph cannot be released safely.
      if (release_result != 0) {
        // Roll back earlier work and return the release failure.
        return rollback(release_result);
      }

      // Avoid racing AVAudioEngine's asynchronous I/O-unit shutdown.
      usleep(kVoiceProcessingRetryDelayMs * 1000);

      // Allocate a new graph rather than reconnecting the failed one.
      int32_t create_result = createEngine();
      // Stop recovery if a replacement graph cannot be created.
      if (create_result != 0) {
        // Roll back earlier work and return the creation failure.
        return rollback(create_result);
      }

      // Reapply session preparation to the replacement engine.
      prepare_result = prepareEngine();
      // Stop recovery if the replacement cannot be prepared.
      if (prepare_result != 0) {
        // Roll back earlier work and return the preparation failure.
        return rollback(prepare_result);
      }

      // Retry VP only after the replacement graph is fully prepared.
      voice_processing_result =
          ConfigureVoiceProcessingNode(inputNode(), state);
      // Advance the bounded attempt count after each complete retry.
      attempt++;
    }

    // Recover the previous stable media state when every VP attempt fails.
    if (voice_processing_result != 0) {
      // Record the bounded failure for production crash diagnostics.
      LOGE() << "Failed to configure voice processing after " << attempt
             << " attempts";
      // Release the last failed graph before rebuilding the prior state.
      int32_t release_result = releaseEngine();
      // The explicit prior-state recovery supersedes generic rollback actions.
      rollback_actions.clear();
      // Avoid recovery on top of an engine that failed to release.
      if (release_result != 0) {
        // Surface the release failure because no stable state was restored.
        return release_result;
      }

      // Preserve the effective output state even when it was linked to input.
      EngineState recovery_next = state.prev;
      // Materialize linked output so speaker-only recovery keeps playout alive.
      recovery_next.output_enabled = state.prev.IsOutputEnabled();
      // Preserve active playout while discarding the failed input transition.
      recovery_next.output_running = state.prev.IsOutputRunning();
      // Disable regular input so recovery cannot configure voice processing.
      recovery_next.input_enabled = false;
      // Stop input with the graph so recording cannot outlive its failed VP.
      recovery_next.input_running = false;
      // Disable persistent input because it also contributes to IsInputEnabled.
      recovery_next.input_enabled_persistent_mode = false;
      // Rebuild the speaker-only state from a guaranteed blank graph.
      EngineStateUpdate recovery_state = {{}, recovery_next};
      // Use the normal transition machinery to restore observer and node state.
      int32_t recovery_result = ApplyDeviceEngineState(recovery_state);
      // Prefer a recovery error; otherwise preserve the original VP failure.
      return recovery_result != 0 ? recovery_result : voice_processing_result;
    }
  }

  // --------------------------------------------------------------------------------------------
  // Step: Enable output
  //
  if (state.next.IsOutputEnabled() &&
      (!state.prev.IsOutputEnabled() || state.IsEngineRecreateRequired())) {
    LOGI() << "Enabling output for AVAudioEngine...";
    RTC_DCHECK(!engine_device_.running);

    AVAudioFormat* output_node_format = [outputNode() outputFormatForBus:0];

    // Duplicate from the Configure StereoPlayout step above to get correct format after engine recreate.
    const uint32_t desired_channels = state.next.DesiredOutputChannels();
    const uint32_t hardware_channels =
        static_cast<uint32_t>(std::max<NSInteger>(1, output_node_format.channelCount));
    const uint32_t applied_channels = std::min(desired_channels, hardware_channels);
    const bool applied_stereo = desired_channels >= 2;
    state.next.stereo_playout_enabled = applied_stereo;
    LOGI() << "Stereo playout optimistic update: " << applied_stereo;

    LOGI() << "Output format sampleRate: " << output_node_format.sampleRate
           << " channels: " << output_node_format.channelCount
           << " formatID: " << output_node_format.streamDescription->mFormatID
           << " formatFlags: " << output_node_format.streamDescription->mFormatFlags
           << " bytesPerPacket: " << output_node_format.streamDescription->mBytesPerPacket
           << " framesPerPacket: " << output_node_format.streamDescription->mFramesPerPacket
           << " bytesPerFrame: " << output_node_format.streamDescription->mBytesPerFrame
           << " channelsPerFrame: " << output_node_format.streamDescription->mChannelsPerFrame
           << " bitsPerChannel: " << output_node_format.streamDescription->mBitsPerChannel;

    if (output_node_format.sampleRate == 0 || output_node_format.channelCount == 0) {
      LOGE() << "Output device not available, sampleRate=" << output_node_format.sampleRate
             << ", channelCount=" << output_node_format.channelCount;
      return rollback(kAudioEnginePlayoutDeviceNotAvailableError);
    }

    AVAudioFormat* engine_output_format = [[AVAudioFormat alloc]
        initWithCommonFormat:output_node_format.commonFormat  // Usually float32
                  sampleRate:output_node_format.sampleRate
                    channels:applied_channels
                 interleaved:output_node_format.interleaved];

    LOGI() << "New engine output format sampleRate: " << engine_output_format.sampleRate
           << " channels: " << engine_output_format.channelCount
           << " formatID: " << engine_output_format.streamDescription->mFormatID
           << " formatFlags: " << engine_output_format.streamDescription->mFormatFlags
           << " bytesPerPacket: " << engine_output_format.streamDescription->mBytesPerPacket
           << " framesPerPacket: " << engine_output_format.streamDescription->mFramesPerPacket
           << " bytesPerFrame: " << engine_output_format.streamDescription->mBytesPerFrame
           << " channelsPerFrame: " << engine_output_format.streamDescription->mChannelsPerFrame
           << " bitsPerChannel: " << engine_output_format.streamDescription->mBitsPerChannel;

    audio_device_buffer_->SetPlayoutSampleRate(engine_output_format.sampleRate);
    audio_device_buffer_->SetPlayoutChannels(engine_output_format.channelCount);
    RTC_DCHECK(audio_device_buffer_ != nullptr);
    fine_audio_buffer_.reset(new FineAudioBuffer(audio_device_buffer_.get()));

    AVAudioFormat* rtc_output_format =
        [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16
                                         sampleRate:engine_output_format.sampleRate
                                           channels:engine_output_format.channelCount
                                        interleaved:YES];

    LOGI() << "New RTC output format sampleRate: " << rtc_output_format.sampleRate
           << " channels: " << rtc_output_format.channelCount
           << " formatID: " << rtc_output_format.streamDescription->mFormatID
           << " formatFlags: " << rtc_output_format.streamDescription->mFormatFlags
           << " bytesPerPacket: " << rtc_output_format.streamDescription->mBytesPerPacket
           << " framesPerPacket: " << rtc_output_format.streamDescription->mFramesPerPacket
           << " bytesPerFrame: " << rtc_output_format.streamDescription->mBytesPerFrame
           << " channelsPerFrame: " << rtc_output_format.streamDescription->mChannelsPerFrame
           << " bitsPerChannel: " << rtc_output_format.streamDescription->mBitsPerChannel;

    AVAudioSourceNodeRenderBlock source_block =
        ^OSStatus(BOOL* isSilence, const AudioTimeStamp* timestamp, AVAudioFrameCount frameCount,
                  AudioBufferList* outputData) {
          RTC_DCHECK(outputData->mNumberBuffers == 1);

          int16_t* dest_buffer = (int16_t*)outputData->mBuffers[0].mData;

          const size_t samples = frameCount * applied_channels;
          fine_audio_buffer_->GetPlayoutData(
              webrtc::ArrayView<int16_t>(static_cast<int16_t*>(dest_buffer), samples),
              kFixedPlayoutDelayEstimate);

          return noErr;
        };

    source_node_ = [[AVAudioSourceNode alloc] initWithFormat:rtc_output_format
                                                 renderBlock:source_block];
    [engine_device_ attachNode:source_node_];

    @try {
      [engine_device_ connect:source_node_
                           to:engine_device_.mainMixerNode
                       format:engine_output_format];

      // mainMixerNode -> outputNode is connected by default by AVAudioEngine, but we connect anyways
      // with format.
      [engine_device_ connect:engine_device_.mainMixerNode
                           to:outputNode()
                       format:engine_output_format];
    } @catch (NSException* exception) {
      // Keep the connection failure diagnostic safe when NSException provides no reason.
      LOGE() << "Failed to connect output nodes: "
             << (exception.reason ? exception.reason.UTF8String : "Unknown");
      return rollback(kAudioEngineDeviceFormatError);
    }

    // Confirm the mixer honored our channel count
    AVAudioFormat* mixer_format = [engine_device_.mainMixerNode outputFormatForBus:0];
    if (mixer_format.channelCount < applied_channels) {
      LOGW() << "Mixer forced channel count to " << mixer_format.channelCount;
      state.next.stereo_playout_enabled = mixer_format.channelCount >= 2;
    } else {
      LOGI() << "Mixer accepted channel count to " << mixer_format.channelCount;
    }

    if (this->observer_ != nullptr) {
      NSDictionary* context = @{};
      int32_t result =
          this->observer_->OnEngineWillConnectOutput(engine_device_, engine_device_.mainMixerNode,
                                                     outputNode(), engine_output_format, context);
      if (result != 0) {
        LOGE() << "Call to OnEngineWillConnectOutput returned error: " << result;
        return rollback(result);
      }
    }

  } else if ((state.prev.IsOutputEnabled() && !state.next.IsOutputEnabled()) &&
             !state.IsEngineRecreateRequired()) {
    LOGI() << "Disabling output for AVAudioEngine...";
    RTC_DCHECK(!engine_device_.running);

    // Detach source node
    if (source_node_ != nil) {
      if (![engine_device_.attachedNodes containsObject:source_node_]) {
        LOGW() << "Attempted to detach a node that wasn't attached to the engine";
      } else {
        @try {
          [engine_device_ detachNode:source_node_];
        } @catch (NSException* exception) {
          LOGW() << "Failed to detach node: " << exception.reason.UTF8String;
        }
      }
      source_node_ = nil;
    }
  }

  // --------------------------------------------------------------------------------------------
  // Step: Enable input
  //
  if (state.next.IsInputEnabled() &&
      (!state.prev.IsInputEnabled() || state.IsEngineRecreateRequired())) {
    LOGI() << "Enabling input for AVAudioEngine...";
    RTC_DCHECK(!engine_device_.running);

    // Apple: When the engine renders to and from an audio device, the AVAudioSession category and
    // the availability of hardware determines whether an app performs input (for example, input
    // hardware isn’t available in tvOS). Check the input node’s input format (specifically, the
    // hardware format) for a nonzero sample rate and channel count to see if input is in an enabled
    // state. Trying to perform input through the input node when it isn’t available or in an
    // enabled state causes the engine to throw an error (when possible) or an exception.
    AVAudioFormat* input_node_format = [inputNode() outputFormatForBus:0];
    // Example formats:
    // Airpods: 1 ch,  24000 Hz, Float32
    // Mac: 9 ch,  48000 Hz, Float32
    LOGI() << "Input format sampleRate: " << input_node_format.sampleRate
           << " channels: " << input_node_format.channelCount
           << " formatID: " << input_node_format.streamDescription->mFormatID
           << " formatFlags: " << input_node_format.streamDescription->mFormatFlags
           << " bytesPerPacket: " << input_node_format.streamDescription->mBytesPerPacket
           << " framesPerPacket: " << input_node_format.streamDescription->mFramesPerPacket
           << " bytesPerFrame: " << input_node_format.streamDescription->mBytesPerFrame
           << " channelsPerFrame: " << input_node_format.streamDescription->mChannelsPerFrame
           << " bitsPerChannel: " << input_node_format.streamDescription->mBitsPerChannel;

    // Check if the input node format is valid (has non-zero sample rate and channel count)
    if (input_node_format.sampleRate == 0 || input_node_format.channelCount == 0) {
      LOGE() << "Input device not available, sampleRate=" << input_node_format.sampleRate
             << ", channelCount=" << input_node_format.channelCount;
      return rollback(kAudioEngineRecordingDeviceNotAvailableError);
    }

    input_mixer_node_ = [[AVAudioMixerNode alloc] init];
    [engine_device_ attachNode:input_mixer_node_];

    // When VoiceProcessingIO is enabled, channels must be reduced from Mac's default 9 channels
    // to 2 or lower.
    AVAudioFormat* engine_input_format = [[AVAudioFormat alloc]
        initWithCommonFormat:input_node_format.commonFormat  // Usually float32
                  sampleRate:input_node_format.sampleRate
                    channels:1
                 interleaved:input_node_format.interleaved];

    AVAudioFormat* rtc_input_format =
        [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16
                                         sampleRate:engine_input_format.sampleRate
                                           channels:1
                                        interleaved:YES];

    audio_device_buffer_->SetRecordingSampleRate(rtc_input_format.sampleRate);
    audio_device_buffer_->SetRecordingChannels(rtc_input_format.channelCount);
    RTC_DCHECK(audio_device_buffer_ != nullptr);
    fine_audio_buffer_.reset(new FineAudioBuffer(audio_device_buffer_.get()));

    // Give copied sink blocks their own guarded converter lifetime without
    // capturing AudioEngineDevice.
    input_render_context_ = std::make_shared<AudioEngineInputRenderContext>(
        engine_input_format, rtc_input_format, audio_device_buffer_,
        machTickUnitsToNanoseconds_);
    // Tear down partially configured input through the same callback gate.
    rollback_actions.push_back([this] { InvalidateInputRenderContext(); });
    // Capture the context by value because AVAudioEngine owns a copied block
    // that can outlive the device's reference during graph release.
    const auto input_render_context = input_render_context_;

    // Convert to Int16 buffers within the sink block.
    AVAudioSinkNodeReceiverBlock sink_block =
        ^OSStatus(const AudioTimeStamp* timestamp, AVAudioFrameCount frameCount,
                  const AudioBufferList* inputData) {
          // Route every invocation through the guarded lifetime boundary.
          return input_render_context->Render(timestamp, frameCount, inputData);
        };

    NSMutableArray<AVAudioConnectionPoint*>* input_mixer_connections = [NSMutableArray array];

    if (observer_ != nullptr) {
      NSDictionary* context = @{
        kAudioEngineInputMixerNodeKey : input_mixer_node_,
      };
      int32_t result = observer_->OnEngineWillConnectInput(
          engine_device_, inputNode(), input_mixer_node_, engine_input_format, context);
      if (result != 0) {
        LOGE() << "Call to OnEngineWillConnectInput returned error: " << result;
        return rollback(result);
      }
    }

    for (AVAudioNodeBus bus = 0; bus < input_mixer_node_.numberOfInputs; bus++) {
      AVAudioConnectionPoint* cp = [engine_device_ inputConnectionPointForNode:input_mixer_node_
                                                                      inputBus:bus];
      if (cp) {
        [input_mixer_connections addObject:cp];
      }
    }

    LOGI() << "input mixer connection count: " << input_mixer_connections.count;
    @try {
      if (input_mixer_connections.count == 0) {
        LOGI() << "Nothing connected to input mixer, connecting input node...";
        // Default implementation.
        [engine_device_ connect:inputNode() to:input_mixer_node_ format:engine_input_format];
      }
    } @catch (NSException* exception) {
      // Keep the connection failure diagnostic safe when NSException provides no reason.
      LOGE() << "Failed to connect input nodes: "
             << (exception.reason ? exception.reason.UTF8String : "Unknown");
      return rollback(kAudioEngineDeviceFormatError);
    }

    sink_node_ = [[AVAudioSinkNode alloc] initWithReceiverBlock:sink_block];
    [engine_device_ attachNode:sink_node_];

    @try {
      [engine_device_ connect:input_mixer_node_ to:sink_node_ format:engine_input_format];
    } @catch (NSException* exception) {
      // Keep the connection failure diagnostic safe when NSException provides no reason.
      LOGE() << "Failed to connect input mixer to sink node: "
             << (exception.reason ? exception.reason.UTF8String : "Unknown");
      return rollback(kAudioEngineDeviceFormatError);
    }

  } else if ((state.prev.IsInputEnabled() && !state.next.IsInputEnabled()) &&
             !state.IsEngineRecreateRequired()) {
    LOGI() << "Disabling input for AVAudioEngine...";
    RTC_DCHECK(!engine_device_.running);
    // Close and drain the callback before detaching either input node.
    InvalidateInputRenderContext();

    // If disabling input, always unmute the voice-processing input mute.
    if (inputNode().voiceProcessingEnabled && inputNode().voiceProcessingInputMuted) {
      LOGI() << "Update mute (voice processing) unmuting vp for stop-recording";
      inputNode().voiceProcessingInputMuted = false;
    }

    // Detach input mixer node
    if (input_mixer_node_ != nil) {
      if (![engine_device_.attachedNodes containsObject:input_mixer_node_]) {
        LOGW() << "Attempted to detach a node that wasn't attached to the engine";
      } else {
        @try {
          [engine_device_ detachNode:input_mixer_node_];
        } @catch (NSException* exception) {
          LOGW() << "Failed to detach node: " << exception.reason.UTF8String;
        }
        input_mixer_node_ = nil;
      }
    }

    // Detach sink node
    if (sink_node_ != nil) {
      if (![engine_device_.attachedNodes containsObject:sink_node_]) {
        LOGW() << "Attempted to detach a node that wasn't attached to the engine";
      } else {
        @try {
          [engine_device_ detachNode:sink_node_];
        } @catch (NSException* exception) {
          LOGW() << "Failed to detach node: " << exception.reason.UTF8String;
        }
        sink_node_ = nil;
      }
    }

  }

  // --------------------------------------------------------------------------------------------
  // Step: Trigger "engine did disable" event
  //
  if (state.DidAnyDisable() && observer_ != nullptr) {
    int32_t result = observer_->OnEngineDidDisable(engine_device_, state.next.IsOutputEnabled(),
                                                   state.next.IsInputEnabled());
    if (result != 0) {
      LOGE() << "Call to OnEngineDidDisable returned error: " << result;
      return rollback(result);
    }
  }

  // --------------------------------------------------------------------------------------------
  // Step: Run-time mute toggling if vp mode.
  //
  if (state.next.mute_mode == MuteMode::VoiceProcessing && state.next.IsInputEnabled() &&
      inputNode().voiceProcessingEnabled &&
      inputNode().voiceProcessingInputMuted != state.next.input_muted) {
    LOGI() << "Update mute (voice processing) runtime update: " << state.next.input_muted;
    inputNode().voiceProcessingInputMuted = state.next.input_muted;
  }

  // --------------------------------------------------------------------------------------------
  // Step: Run-time mute toggling if mixer mute mode.
  //
  if (state.next.mute_mode == MuteMode::InputMixer && state.next.IsInputEnabled() &&
      input_mixer_node_ != nil) {
    // Only update if the volume has changed.
    float mixer_volume = state.next.input_muted ? 0.0f : 1.0f;
    if (input_mixer_node_.outputVolume != mixer_volume) {
      LOGI() << "Update mute (input mixer) runtime update: " << state.next.input_muted;
      input_mixer_node_.outputVolume = mixer_volume;
    }
  }

  // --------------------------------------------------------------------------------------------
  // Step: Configure other audio ducking
  //
#if !TARGET_OS_TV
  if (state.next.IsInputEnabled() && inputNode().voiceProcessingEnabled &&
      (!state.prev.IsInputEnabled() ||
       (state.prev.advanced_ducking != state.next.advanced_ducking ||
        state.prev.ducking_level != state.next.ducking_level))) {
    // Other audio ducking.
    // iOS 17.0+, iPadOS 17.0+, Mac Catalyst 17.0+, macOS 14.0+, visionOS 1.0+
    if (@available(iOS 17.0, macCatalyst 17.0, macOS 14.0, visionOS 1.0, *)) {
      AVAudioVoiceProcessingOtherAudioDuckingConfiguration ducking_config;
      ducking_config.enableAdvancedDucking = state.next.advanced_ducking;
      ducking_config.duckingLevel =
          (AVAudioVoiceProcessingOtherAudioDuckingLevel)state.next.ducking_level;

      LOGI() << "setVoiceProcessingOtherAudioDuckingConfiguration";
      inputNode().voiceProcessingOtherAudioDuckingConfiguration = ducking_config;
    }
  }
#endif

  // --------------------------------------------------------------------------------------------
  // Step: Bypass voice processing
  //
  if (state.next.IsInputEnabled() && inputNode().voiceProcessingEnabled &&
      inputNode().voiceProcessingBypassed != state.next.voice_processing_bypassed) {
    LOGI() << "setting voiceProcessingBypassed: " << state.next.voice_processing_bypassed;
    inputNode().voiceProcessingBypassed = state.next.voice_processing_bypassed;
  }

  // --------------------------------------------------------------------------------------------
  // Step: Configure AGC
  //
  if (state.next.IsInputEnabled() && inputNode().voiceProcessingEnabled &&
      inputNode().voiceProcessingAGCEnabled != state.next.voice_processing_agc_enabled) {
    LOGI() << "setting voiceProcessingAGCEnabled: " << state.next.voice_processing_agc_enabled;
    inputNode().voiceProcessingAGCEnabled = state.next.voice_processing_agc_enabled;
  }

  // --------------------------------------------------------------------------------------------
  // Step: Configure device (macOS only)
  //
#if TARGET_OS_OSX
  if (state.next.IsAnyEnabled() &&
      (!state.prev.IsAnyEnabled() || state.IsEngineRecreateRequired())) {
    if (state.next.IsInputEnabled()) {
      uint32_t input_device_id = state.next.input_device_id;
      if (input_device_id == kAudioObjectUnknown) {
        LOGI() << "Using default input device";
      } else {
        auto input_device_name = mac_audio_utils::GetDeviceName(input_device_id);
        LOGI() << "Setting input device: " << input_device_name.value_or("Unknown") << " ("
               << input_device_id << ")";
        AudioUnit inputUnit = inputNode().audioUnit;
        OSStatus err = AudioUnitSetProperty(inputUnit, kAudioOutputUnitProperty_CurrentDevice,
                                            kAudioUnitScope_Global, 1, &input_device_id,
                                            sizeof(input_device_id));
        if (err != noErr) {
          LOGE() << "Failed to set input device: " << input_device_id;
        }
      }
    }

    if (state.next.IsOutputEnabled()) {
      uint32_t output_deviceId = state.next.output_device_id;
      if (output_deviceId == kAudioObjectUnknown) {
        LOGI() << "Using default output device";
      } else {
        auto output_device_name = mac_audio_utils::GetDeviceName(output_deviceId);
        LOGI() << "Setting output device: " << output_device_name.value_or("Unknown") << " ("
               << output_deviceId << ")";
        AudioUnit outputUnit = outputNode().audioUnit;
        OSStatus err = AudioUnitSetProperty(outputUnit, kAudioOutputUnitProperty_CurrentDevice,
                                            kAudioUnitScope_Global, 0, &output_deviceId,
                                            sizeof(output_deviceId));
        if (err != noErr) {
          LOGE() << "Failed to set output device: " << output_deviceId;
        }
      }
    }
  }
#endif

  // --------------------------------------------------------------------------------------------
  // Step: Start playout buffer
  //
  if (state.next.IsOutputEnabled() && !audio_device_buffer_->IsPlaying()) {
    if (engine_device_ != nullptr) {
      // Rendering must be stopped first.
      RTC_DCHECK(!engine_device_.running);
    }
    LOGI() << "Starting Playout buffer...";
    audio_device_buffer_->StartPlayout();
    fine_audio_buffer_->ResetPlayout();
  }

  // --------------------------------------------------------------------------------------------
  // Step: Start recording buffer
  //
  if (state.next.IsInputEnabled() && !audio_device_buffer_->IsRecording()) {
    if (engine_device_ != nullptr) {
      // Rendering must be stopped first.
      RTC_DCHECK(!engine_device_.running);
    }
    LOGI() << "Starting Record buffer...";
    audio_device_buffer_->StartRecording();
    fine_audio_buffer_->ResetRecord();
  }

  // --------------------------------------------------------------------------------------------
  // Step: Start engine
  //
  if (state.next.IsAnyRunning()) {
    if (!state.prev.IsAnyRunning() || state.DidEndInterruption() ||
        state.IsEngineRestartRequired() || state.IsEngineRecreateRequired()) {
      if (observer_ != nullptr) {
        int32_t result = observer_->OnEngineWillStart(engine_device_, state.next.IsOutputEnabled(),
                                                      state.next.IsInputEnabled());
        if (result != 0) {
          LOGE() << "Call to OnEngineWillStart returned error: " << result;
          return rollback(result);
        }
      }

      LOGI() << "Starting AVAudioEngine...";
      BOOL start_result = false;
      int start_retry_count = 0;

      // Workaround for error -66637, when recovering from interruptions with categoryMode:
      // .mixWithOthers.
      while (!start_result && start_retry_count < kStartEngineMaxRetries) {
        if (start_retry_count > 0) {
          LOGW() << "Retrying engine start (attempt " << (start_retry_count + 1) << "/"
                 << kStartEngineMaxRetries << ")";
          usleep(kStartEngineRetryDelayMs * 1000);
        }

        NSString* error_string = nil;

        @try {
#if TARGET_OS_OSX
          // Workaround for engine not starting in some cases when other apps are using voice
          // processing already.
          // TODO: Find a better workaround, or a cleaner way to wait the vp config is complete.
          [engine_device_ prepare];

          LOGI() << "Sleeping for 0.1 seconds...";
          usleep(100000);  // 0.1 seconds
#endif

          NSError* error = nil;
          start_result = [engine_device_ startAndReturnError:&error];
          if (!start_result && error != nil) {
            error_string = error.localizedDescription;
          }
        } @catch (NSException* exception) {
          start_result = false;
          error_string = exception.reason ?: @"Unknown exception";
        }

        if (!start_result) {
          if (error_string != nil) {
            LOGE() << "Failed to start engine: " << error_string.UTF8String;
          }
          start_retry_count++;
        }
      }

      if (start_result) {
        RTC_DCHECK(configuration_observer_ == nullptr);
        // Add observer for configuration changes
        NSNotificationCenter* center = [NSNotificationCenter defaultCenter];
        configuration_observer_ = (__bridge_retained void*)[center
            addObserverForName:AVAudioEngineConfigurationChangeNotification
                        object:engine_device_
                         queue:nil
                    usingBlock:^(NSNotification* notification) {
                      LOGI() << "AVAudioEngineConfigurationChangeNotification engineIsRunning: "
                             << engine_device_.running;
                      // Only re-configure if engine stopped.
                      if (!engine_device_.running) {
                        ReconfigureEngine();
                      }
                    }];

        // engine.start() drops the muted-talker listener; re-arm it on the live input node.
        if (state.next.IsInputEnabled() && inputNode().voiceProcessingEnabled) {
          ConfigureMutedSpeechActivityEventListener(inputNode(), state);
        }
      } else {
        LOGE() << "Failed to start engine after " << kStartEngineMaxRetries << " attempts";
        DebugAudioEngine();
      }
    }
  }

  // --------------------------------------------------------------------------------------------
  // Step: Release AVAudioEngine
  //
  if (state.prev.IsAnyEnabled() && !state.next.IsAnyEnabled()) {
    RTC_DCHECK(engine_device_ != nullptr);

    // Use the shared release path so final shutdown matches recreation.
    int32_t result = releaseEngine();
    // Preserve the existing rollback semantics when release fails.
    if (result != 0) {
      // Undo earlier transition work and return the release error.
      return rollback(result);
    }

    LOGI() << "Releasing AVAudioEngine...";
  }

  return 0;
}

void AudioEngineDevice::InvalidateInputRenderContext() {
  // Context ownership is confined to the device-control thread so graph and
  // callback teardown keep the same sequence ordering.
  RTC_DCHECK_RUN_ON(thread_);
  // A missing context means input setup never completed or teardown already
  // consumed the device's reference.
  if (input_render_context_ != nullptr) {
    // Release callback-local raw links and converter state on the owning
    // device-control sequence after any active render exits.
    input_render_context_->Invalidate();
    // The sink block may retain the inert context, but it no longer retains or
    // accesses sequence-affine production resources.
    input_render_context_.reset();
  }
}

// ----------------------------------------------------------------------------------------------------
// Private - EngineState

// Return an error instead of continuing with input whose requested processing
// could not be applied.
int32_t AudioEngineDevice::ConfigureVoiceProcessingNode(
    AVAudioInputNode* input_node, EngineStateUpdate state) {
  // Skip native graph mutation when input is off or VP already matches.
  if (!state.next.IsInputEnabled() ||
      input_node.voiceProcessingEnabled ==
          state.next.voice_processing_enabled) {
    // Report success because no voice-processing transition is required.
    return 0;
  }

#if TARGET_OS_SIMULATOR
  // The simulator lacks the device I/O path, so retain its existing no-op.
  LOGI() << "setVoiceProcessingEnabled (input): "
         << (state.next.voice_processing_enabled ? "YES" : "NO")
         << " (Ignored on Simulator)";
#else
  // Record the requested transition before entering the throwing Apple API.
  LOGI() << "setVoiceProcessingEnabled (input): "
         << (state.next.voice_processing_enabled ? "YES" : "NO");

  // Capture NSError failures from the documented API contract.
  NSError* error = nil;
  // Default to failure so only an explicit native success may continue.
  BOOL set_vp_result = NO;
  // Convert Objective-C graph exceptions into the existing ADM error path.
  @try {
    // Apply VP on the prepared fresh graph and capture NSError details.
    set_vp_result = [input_node
        setVoiceProcessingEnabled:state.next.voice_processing_enabled
                            error:&error];
  } @catch (NSException* exception) {
    // Preserve exception context without allowing it to terminate the process.
    LOGE() << "setVoiceProcessingEnabled exception: "
           << (exception.reason ? exception.reason.UTF8String :
                                  "Unknown exception");
    // Trigger bounded fresh-engine recovery through the caller.
    return kAudioEngineVoiceProcessingError;
  }

  // Treat a reported native failure as equivalent to the caught exception.
  if (!set_vp_result) {
    // Preserve the NSError context for crash and device diagnostics.
    LOGE() << "setVoiceProcessingEnabled error: "
           << (error.localizedDescription ?
                   error.localizedDescription.UTF8String :
                   "Unknown error");
    // Trigger bounded fresh-engine recovery through the caller.
    return kAudioEngineVoiceProcessingError;
  }

  // Record that the requested processing state was applied successfully.
  LOGI() << "setVoiceProcessingEnabled (input) result: YES";
#endif

  // Configure VP-dependent features only when the input node confirms VP.
  if (input_node.voiceProcessingEnabled) {
    // Always unmute vp if restart mute mode.
    if (state.next.mute_mode == MuteMode::RestartEngine &&
        input_node.voiceProcessingInputMuted) {
      LOGI() << "Update mute (voice processing) unmuting vp for restart engine "
                "mode";
      // Clear the VP mute left by the previous restart-based mute strategy.
      input_node.voiceProcessingInputMuted = false;
    }

    // Restore muted-speech callbacks after the VP audio unit is recreated.
    ConfigureMutedSpeechActivityEventListener(input_node, state);
  }

  // Report success only after all VP-dependent configuration is complete.
  return 0;
}

void AudioEngineDevice::ConfigureMutedSpeechActivityEventListener(AVAudioInputNode* input_node, 
                                                                  EngineStateUpdate state) {
  const bool input_active =
      state.prev.IsInputEnabled() || state.next.IsInputEnabled();
  if (!input_active || input_node == nil) {
    LOGW() << "ConfigureMutedSpeechActivityEventListener called with input disabled; skipping";
    return;
  }

#if TARGET_OS_IPHONE
  if (@available(iOS 17.0, macCatalyst 17.0, tvOS 17.0, visionOS 1.0, *)) {
    AVAudioSession* session = [AVAudioSession sharedInstance];
    NSString* mode = session.mode;
    static NSSet<NSString*>* const kMonoModes = [NSSet setWithArray:@[
      AVAudioSessionModeVoiceChat,
      AVAudioSessionModeVideoChat
    ]];

    if ([kMonoModes containsObject:mode]) {
      LOGI() << "Setting muted speech activity listener for mode: " << mode.UTF8String;

      auto listener_block = ^(AVAudioVoiceProcessingSpeechActivityEvent event) {
        LOGI() << "AVAudioVoiceProcessingSpeechActivityEvent: " << event;
        RTC_DCHECK(event == AVAudioVoiceProcessingSpeechActivityStarted ||
                  event == AVAudioVoiceProcessingSpeechActivityEnded);
        AudioDeviceModule::SpeechActivityEvent rtc_event =
            (event == AVAudioVoiceProcessingSpeechActivityStarted
                ? AudioDeviceModule::SpeechActivityEvent::kStarted
                : AudioDeviceModule::SpeechActivityEvent::kEnded);

        thread_->PostTask(SafeTask(safety_, [this, rtc_event] {
          RTC_DCHECK_RUN_ON(thread_);  // Silence warning.
          if (this->observer_ != nullptr) {
            this->observer_->OnSpeechActivityEvent(rtc_event);
          }
        }));
      };

      BOOL set_listener_result = [input_node setMutedSpeechActivityEventListener:listener_block];
      if (set_listener_result) {
        LOGI() << "setMutedSpeechActivityEventListener: listener installed successfully";
      } else {
        LOGW() << "setMutedSpeechActivityEventListener failed, ensure AVAudioSession.Mode is videoChat or voiceChat.";
      }
    } else {
      BOOL set_listener_result = [input_node setMutedSpeechActivityEventListener:nil];
      if (set_listener_result) {
        LOGI() << "setMutedSpeechActivityEventListener: listener uninstalled successfully";
      } 
    }
  }
#endif
}

void AudioEngineDevice::StartRenderLoop() {
  RTC_DCHECK_RUN_ON(render_thread_.get());

  const uint32_t channels = manual_render_rtc_format_.channelCount;
  const double sample_rate = manual_render_rtc_format_.sampleRate;
  const size_t frames_per_buffer = static_cast<size_t>(sample_rate / 100);  // 10ms chunks
  // We update the sample number to match the frames per channel.
  const size_t samples = frames_per_buffer * channels;
  const size_t buffer_size = samples * kAudioSampleSize;
  const int chunk_ms =
      static_cast<int>(std::round(1000.0 * static_cast<double>(frames_per_buffer) / sample_rate));
  int64_t next_wakeup_ms = webrtc::TimeMillis();

  while (!render_thread_->IsQuitting()) {
    // Read (Output)
    RTC_DCHECK(read_buffer_ != nullptr);
    AudioBufferList* read_abl = const_cast<AudioBufferList*>(read_buffer_.audioBufferList);
    read_abl->mBuffers[0].mDataByteSize = buffer_size;

    RTC_DCHECK(read_abl->mNumberBuffers == 1);
    int16_t* const read_rtc_buffer =
        static_cast<int16_t*>(static_cast<void*>(read_abl->mBuffers[0].mData));

    // Call GetPlayoutData to pull frames into rtc audio stack even though we won't use it here.
    fine_audio_buffer_->GetPlayoutData(
        webrtc::ArrayView<int16_t>(read_rtc_buffer, samples), kFixedPlayoutDelayEstimate);

    // Render (Input)
    RTC_DCHECK(render_buffer_ != nullptr);
    AudioBufferList* render_abl = const_cast<AudioBufferList*>(render_buffer_.audioBufferList);
    render_abl->mBuffers[0].mDataByteSize = buffer_size;

    OSStatus err = noErr;
    AVAudioEngineManualRenderingStatus result = render_block_(frames_per_buffer, render_abl, &err);

    if (result == AVAudioEngineManualRenderingStatusSuccess) {
      RTC_DCHECK(render_abl->mNumberBuffers == 1);
      const int16_t* rtc_buffer =
          static_cast<const int16_t*>(static_cast<const void*>(render_abl->mBuffers[0].mData));

      const uint64_t capture_time = mach_absolute_time();
      const int64_t capture_time_ns = capture_time * machTickUnitsToNanoseconds_;

      fine_audio_buffer_->DeliverRecordedData(
          webrtc::ArrayView<const int16_t>(rtc_buffer, frames_per_buffer),
          kFixedRecordDelayEstimate, capture_time_ns);
    } else {
      LOGW() << "Render error: " << err << " frames: " << frames_per_buffer;
    }

    if (!render_thread_->IsQuitting()) {
      next_wakeup_ms += chunk_ms;
      const int64_t now_ms = webrtc::TimeMillis();
      const int64_t sleep_ms = next_wakeup_ms - now_ms;
      if (sleep_ms > 0) {
        render_thread_->SleepMs(static_cast<int>(sleep_ms));
      }
    }
  }
}

// ----------------------------------------------------------------------------------------------------
// Private - Device access

#if TARGET_OS_OSX

void AudioEngineDevice::UpdateAllDeviceIDs() {
  using namespace webrtc::mac_audio_utils;

  input_device_ids_.clear();
  output_device_ids_.clear();
  input_device_labels_.clear();
  output_device_labels_.clear();

  std::vector<AudioObjectID> all_device_ids = GetAllAudioDeviceIDs();

  for (AudioObjectID device_id : all_device_ids) {
    if (IsInputDevice(device_id)) {
      input_device_ids_.push_back(device_id);
      auto label = GetDeviceLabel(device_id, true);
      if (label) {
        input_device_labels_.push_back(*label);
      } else {
        input_device_labels_.push_back("Unknown Input Device");
      }
    }

    if (IsOutputDevice(device_id)) {
      output_device_ids_.push_back(device_id);
      auto label = GetDeviceLabel(device_id, false);
      if (label) {
        output_device_labels_.push_back(*label);
      } else {
        output_device_labels_.push_back("Unknown Output Device");
      }
    }
  }
}

#endif

// ----------------------------------------------------------------------------------------------------
// Private - Debug

void AudioEngineDevice::DebugEngineState(const std::string& prefix,
                                         EngineState state) {
  RTC_DCHECK_RUN_ON(thread_);

  LOGI() << prefix << " {"
         << "IsOutputEnabled: " << state.IsOutputEnabled()
         << ", IsInputEnabled: " << state.IsInputEnabled()
         << ", IsOutputInputLinked: " << state.IsOutputInputLinked()
         << ", IsOutputRunning: " << state.IsOutputRunning()
         << ", IsInputRunning: " << state.IsInputRunning()
         << ", IsAnyEnabled: " << state.IsAnyEnabled()
         << ", IsAnyRunning: " << state.IsAnyRunning()
         << ", IsAllEnabled: " << state.IsAllEnabled()
         << ", IsAllRunning: " << state.IsAllRunning()
         << ", InputAvailable: " << state.input_available
         << ", OutputAvailable: " << state.output_available
         << ", AdvancedDucking: " << state.advanced_ducking
         << ", DuckingLevel: " << state.ducking_level
         << ", MuteMode: " << static_cast<int>(state.mute_mode)
         << ", InputMuted: " << state.input_muted
         << ", InputDeviceID: " << state.input_device_id
         << ", OutputDeviceID: " << state.output_device_id
         << ", VoiceProcessingEnabled: " << state.voice_processing_enabled
         << ", VoiceProcessingBypassed: " << state.voice_processing_bypassed
         << ", VoiceProcessingAGCEnabled: " << state.voice_processing_agc_enabled
         << ", PrefersStereoPlayout: " << state.prefers_stereo_playout
         << ", StereoPlayoutAvailable: " << state.stereo_playout_available
         << ", StereoPlayoutEnabled: " << state.stereo_playout_enabled
         << ", DesiredOutputChannels: " << state.DesiredOutputChannels()
         << " }";
}

void AudioEngineDevice::DebugAudioEngine() {
  RTC_DCHECK_RUN_ON(thread_);

  auto padded_string = [](int pad) { return std::string(pad * 2, ' '); };

  auto audio_format = [](AVAudioFormat* format) {
    std::ostringstream result;

    // Get the underlying AudioStreamBasicDescription
    const AudioStreamBasicDescription& asbd = *format.streamDescription;

    result << "(";
    // Basic properties
    result << "sampleRate: " << format.sampleRate;
    result << ", channels: " << format.channelCount;
    result << ", bitsPerChannel: " << asbd.mBitsPerChannel;

    // Format ID (should be LinearPCM)
    result << ", formatID: ";
    char formatID[5] = {0};
    *(UInt32*)formatID = CFSwapInt32HostToBig(asbd.mFormatID);
    result << formatID;
    result << (asbd.mFormatID == kAudioFormatLinearPCM ? " (LinearPCM)" : " (Not LinearPCM)");

    // Format Flags
    result << std::hex << std::showbase;
    result << ", formatFlags: " << asbd.mFormatFlags;

    // Check specific flags
    bool isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat);
    bool isPacked = (asbd.mFormatFlags & kAudioFormatFlagIsPacked);
    bool isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved);
    bool isNativeEndian = (asbd.mFormatFlags & kAudioFormatFlagsNativeEndian);

    bool isAudioUnitCanonical = isNativeEndian && isFloat && isPacked && isNonInterleaved;

    result << std::dec;  // Switch back to decimal
    result << " [";
    result << "float:" << (isFloat ? "true" : "false") << ", ";
    result << "packed:" << (isPacked ? "true" : "false") << ", ";
    result << "non-interleaved:" << (isNonInterleaved ? "true" : "false") << ", ";
    result << "native-endian:" << (isNativeEndian ? "true" : "false") << ", ";
    result << "audio-unit-canonical:" << (isAudioUnitCanonical ? "true" : "false");
    result << "]";

    result << ")";
    return result.str();
  };

  std::function<void(AVAudioNode*, int)> print_node;
  print_node = [this, &padded_string, &audio_format](AVAudioNode* node, int base_depth = 0) {
    RTC_DCHECK_RUN_ON(thread_);
    LOGI() << padded_string(base_depth) << NSStringFromClass([node class]).UTF8String << "."
           << node.hash;

    // Inputs
    for (NSUInteger i = 0; i < node.numberOfInputs; i++) {
      AVAudioFormat* format = [node inputFormatForBus:i];
      LOGI() << padded_string(base_depth) << " <- #" << i << audio_format(format);

      AVAudioConnectionPoint* connection = [this->engine_device_ inputConnectionPointForNode:node
                                                                                    inputBus:i];
      if (connection != nil) {
        LOGI() << padded_string(base_depth + 1) << " <-> "
               << NSStringFromClass([connection.node class]).UTF8String << "."
               << connection.node.hash << " #" << connection.bus;
      }
    }

    // Outputs
    for (NSUInteger i = 0; i < node.numberOfOutputs; i++) {
      AVAudioFormat* format = [node outputFormatForBus:i];
      LOGI() << padded_string(base_depth) << " -> #" << i << audio_format(format);

      for (NSUInteger o = 0; o < node.numberOfOutputs; o++) {
        NSArray* points = [this->engine_device_ outputConnectionPointsForNode:node outputBus:o];
        for (AVAudioConnectionPoint* connection in points) {
          LOGI() << padded_string(base_depth + 1) << " <-> "
                 << NSStringFromClass([connection.node class]).UTF8String << "."
                 << connection.node.hash << " #" << connection.bus;
        }
      }
    }
  };

  NSArray<AVAudioNode*>* attachedNodes = [engine_device_.attachedNodes allObjects];
  LOGI() << "==================================================";
  LOGI() << "DebugAudioEngine attached nodes: " << attachedNodes.count;

  for (NSUInteger i = 0; i < attachedNodes.count; i++) {
    AVAudioNode* node = attachedNodes[i];
    print_node(node, 0);
  }

  LOGI() << "==================================================";
}

}  // namespace webrtc
