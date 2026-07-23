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

#include <os/lock.h>
#include <utility>

#import "RTCAudioDeviceModule+Private.h"
#import "RTCAudioDeviceModule.h"
#import "RTCIODevice+Private.h"
#import "base/RTCLogging.h"

#if defined(WEBRTC_INCLUDE_INTERNAL_AUDIO_DEVICE)
#import "modules/audio_device/audio_engine_device.h"
#endif
#import "sdk/objc/native/api/audio_device_module.h"

#if defined(WEBRTC_INCLUDE_INTERNAL_AUDIO_DEVICE)
NSString *const RTC_CONSTANT_TYPE(RTCAudioEngineInputMixerNodeKey) =
    webrtc::kAudioEngineInputMixerNodeKey;
#else
NSString *const RTC_CONSTANT_TYPE(RTCAudioEngineInputMixerNodeKey) =
    @"_audio_engine_input_mixer_node_key";
#endif

#if defined(WEBRTC_INCLUDE_INTERNAL_AUDIO_DEVICE)
inline webrtc::AudioEngineDevice::MuteMode MuteModeToRTC(RTC_OBJC_TYPE(RTCAudioEngineMuteMode)
                                                             mode) {
  return static_cast<webrtc::AudioEngineDevice::MuteMode>(mode);
}

inline RTC_OBJC_TYPE(RTCAudioEngineMuteMode)
    MuteModeToObjC(webrtc::AudioEngineDevice::MuteMode mode) {
  return static_cast<RTC_OBJC_TYPE(RTCAudioEngineMuteMode)>(mode);
}
#endif

class AudioDeviceObserver : public webrtc::AudioDeviceObserver {
 public:
  AudioDeviceObserver(RTC_OBJC_TYPE(RTCAudioDeviceModule) * adm) { adm_ = adm; }

  void OnDevicesUpdated() override { [delegate_ audioDeviceModuleDidUpdateDevices:adm_]; }

  void OnSpeechActivityEvent(webrtc::AudioDeviceModule::SpeechActivityEvent event) override {
    [delegate_ audioDeviceModule:adm_
        didReceiveSpeechActivityEvent:ConvertSpeechActivityEvent(event)];
  }

  int32_t OnEngineDidCreate(AVAudioEngine *engine) override {
    if (delegate_ == nil) return 0;
    return [delegate_ audioDeviceModule:adm_ didCreateEngine:engine];
  }

  int32_t OnEngineWillEnable(AVAudioEngine *engine, bool playout_enabled,
                             bool recording_enabled) override {
    if (delegate_ == nil) return 0;
    return [delegate_ audioDeviceModule:adm_
                       willEnableEngine:engine
                       isPlayoutEnabled:playout_enabled
                     isRecordingEnabled:recording_enabled];
  }

  int32_t OnEngineWillStart(AVAudioEngine *engine, bool playout_enabled,
                            bool recording_enabled) override {
    if (delegate_ == nil) return 0;
    return [delegate_ audioDeviceModule:adm_
                        willStartEngine:engine
                       isPlayoutEnabled:playout_enabled
                     isRecordingEnabled:recording_enabled];
  }

  int32_t OnEngineDidStop(AVAudioEngine *engine, bool playout_enabled,
                          bool recording_enabled) override {
    if (delegate_ == nil) return 0;
    return [delegate_ audioDeviceModule:adm_
                          didStopEngine:engine
                       isPlayoutEnabled:playout_enabled
                     isRecordingEnabled:recording_enabled];
  }

  int32_t OnEngineDidDisable(AVAudioEngine *engine, bool playout_enabled,
                             bool recording_enabled) override {
    if (delegate_ == nil) return 0;
    return [delegate_ audioDeviceModule:adm_
                       didDisableEngine:engine
                       isPlayoutEnabled:playout_enabled
                     isRecordingEnabled:recording_enabled];
  }

  int32_t OnEngineWillRelease(AVAudioEngine *engine) override {
    if (delegate_ == nil) return 0;
    return [delegate_ audioDeviceModule:adm_ willReleaseEngine:engine];
  }

  int32_t OnEngineWillConnectInput(AVAudioEngine *engine, AVAudioNode *src, AVAudioNode *dst,
                                   AVAudioFormat *format, NSDictionary *context) override {
    if (delegate_ == nil) return 0;
    return [delegate_ audioDeviceModule:adm_
                                 engine:engine
               configureInputFromSource:src
                          toDestination:dst
                             withFormat:format
                                context:context];
  }

  int32_t OnEngineWillConnectOutput(AVAudioEngine *engine, AVAudioNode *src, AVAudioNode *dst,
                                    AVAudioFormat *format, NSDictionary *context) override {
    if (delegate_ == nil) return 0;
    return [delegate_ audioDeviceModule:adm_
                                 engine:engine
              configureOutputFromSource:src
                          toDestination:dst
                             withFormat:format
                                context:context];
  }

  void OnAudioProcessingStateChanged(const webrtc::AudioProcessingState& state) override {
    if (delegate_ == nil) return;
    RTCAudioProcessingState objcState;
    objcState.voiceProcessingEnabled = state.voice_processing_enabled ? YES : NO;
    objcState.voiceProcessingBypassed = state.voice_processing_bypassed ? YES : NO;
    objcState.voiceProcessingAGCEnabled = state.voice_processing_agc_enabled ? YES : NO;
    objcState.stereoPlayoutEnabled = state.stereo_playout_enabled ? YES : NO;
    [delegate_ audioDeviceModule:adm_ didUpdateAudioProcessingState:objcState];
  }

  __weak id<RTC_OBJC_TYPE(RTCAudioDeviceModuleDelegate)> delegate_;

 private:
  __weak RTC_OBJC_TYPE(RTCAudioDeviceModule) * adm_;

  RTC_OBJC_TYPE(RTCSpeechActivityEvent)
  ConvertSpeechActivityEvent(webrtc::AudioDeviceModule::SpeechActivityEvent event) {
    switch (event) {
      case webrtc::AudioDeviceModule::SpeechActivityEvent::kStarted:
        return RTC_OBJC_TYPE(RTCSpeechActivityEvent)::RTC_OBJC_TYPE(RTCSpeechActivityEventStarted);
      case webrtc::AudioDeviceModule::SpeechActivityEvent::kEnded:
        return RTC_OBJC_TYPE(RTCSpeechActivityEvent)::RTC_OBJC_TYPE(RTCSpeechActivityEventEnded);
      default:
        return RTC_OBJC_TYPE(RTCSpeechActivityEvent)::RTC_OBJC_TYPE(RTCSpeechActivityEventEnded);
    }
  }
};

@implementation RTC_OBJC_TYPE (RTCAudioDeviceModule) {
  webrtc::Thread *_workerThread;
  webrtc::scoped_refptr<webrtc::AudioDeviceModule> _native;
  AudioDeviceObserver *_observer;
}

- (id<RTC_OBJC_TYPE(RTCAudioDeviceModuleDelegate)>)observer {
  if (![self isWorkerThreadReady] || _observer == nullptr) {
    return nil;
  }
  return _workerThread->BlockingCall([self] { return _observer->delegate_; });
}

- (BOOL)isWorkerThreadReady {
  return _workerThread != nullptr && !_workerThread->IsQuitting();
}

- (BOOL)isNativeModuleReady {
  return _native.get() != nullptr;
}

- (BOOL)isModuleReady {
  return [self isNativeModuleReady] && [self isWorkerThreadReady];
}

- (BOOL)isAudioEngineModule {
  return _native && _native->IsAudioEngineDevice();
}

- (void)setObserver:(id<RTC_OBJC_TYPE(RTCAudioDeviceModuleDelegate)>)observer {
  if (![self isNativeModuleReady] || ![self isWorkerThreadReady]) {
    return;
  }

  _workerThread->BlockingCall([self, observer] {
    if (_native) {
      _observer->delegate_ = observer;
      _native->SetObserver(observer != nil ? _observer : nullptr);
    }
  });
}

- (instancetype)initWithNativeModule:(webrtc::scoped_refptr<webrtc::AudioDeviceModule>)module
                        workerThread:(webrtc::Thread *)workerThread {
  RTCLogInfo(@"RTCAudioDeviceModule initWithNativeModule:workerThread:");

  self = [super init];
  _native = module;
  _workerThread = workerThread;

  _observer = new AudioDeviceObserver(self);

  return self;
}

- (void)dealloc {
  [self invalidateWorkerThread];

  _native = nullptr;
  _workerThread = nullptr;
}

- (void)invalidateWorkerThread {
  webrtc::Thread *workerThread = _workerThread;
  AudioDeviceObserver *observer = _observer;

  if (observer == nullptr) {
    _workerThread = nullptr;
    return;
  }

  if (_native == nullptr) {
    observer->delegate_ = nil;
    delete observer;
    _observer = nullptr;
    _workerThread = nullptr;
    return;
  }

  if (workerThread && !workerThread->IsQuitting()) {
    // Drop the wrapper's native ADM ref on the worker thread so teardown runs
    // while the thread stored inside the ADM is still valid.
    webrtc::scoped_refptr<webrtc::AudioDeviceModule> native = std::move(_native);
    workerThread->BlockingCall([&native, observer] {
      native->SetObserver(nullptr);
      observer->delegate_ = nil;
      native = nullptr;
    });
    delete observer;
    _observer = nullptr;
  } else {
    observer->delegate_ = nil;
  }

  _workerThread = nullptr;
}

- (NSArray<RTC_OBJC_TYPE(RTCIODevice) *> *)outputDevices {
  if (![self isModuleReady]) {
    return @[];
  }
  return _workerThread->BlockingCall([self] { return [self _outputDevices]; });
}

- (NSArray<RTC_OBJC_TYPE(RTCIODevice) *> *)inputDevices {
  if (![self isModuleReady]) {
    return @[];
  }
  return _workerThread->BlockingCall([self] { return [self _inputDevices]; });
}

- (RTC_OBJC_TYPE(RTCIODevice) *)outputDevice {
  if (![self isModuleReady]) {
    return nil;
  }
  return _workerThread->BlockingCall([self] {
    NSArray<RTC_OBJC_TYPE(RTCIODevice) *> *devices = [self _outputDevices];
    int16_t devicesCount = (int16_t)([devices count]);
    int16_t index = _native->GetPlayoutDevice();

    if (devicesCount == 0 || index <= -1 || index > (devicesCount - 1)) {
      return (RTC_OBJC_TYPE(RTCIODevice) *)nil;
    }

    return (RTC_OBJC_TYPE(RTCIODevice) *)[devices objectAtIndex:index];
  });
}

- (void)setOutputDevice:(RTC_OBJC_TYPE(RTCIODevice) *)device {
  [self trySetOutputDevice:device];
}

- (BOOL)trySetOutputDevice:(RTC_OBJC_TYPE(RTCIODevice) *)device {
  if (![self isModuleReady]) {
    return NO;
  }
  return _workerThread->BlockingCall([self, device] {
    NSUInteger index = 0;
    NSArray *devices = [self _outputDevices];

    if ([devices count] == 0) {
      return NO;
    }

    if (device != nil) {
      index = [devices indexOfObjectPassingTest:^BOOL(RTC_OBJC_TYPE(RTCIODevice) * e, NSUInteger i,
                                                      BOOL * stop) {
        return (*stop = [e.deviceId isEqualToString:device.deviceId]);
      }];
      if (index == NSNotFound) {
        return NO;
      }
    }

    if (_native->SetPlayoutDevice(index)) {
      return YES;
    }

    return NO;
  });
}

- (RTC_OBJC_TYPE(RTCIODevice) *)inputDevice {
  if (![self isModuleReady]) {
    return nil;
  }
  return _workerThread->BlockingCall([self] {
    NSArray<RTC_OBJC_TYPE(RTCIODevice) *> *devices = [self _inputDevices];
    int16_t devicesCount = (int16_t)([devices count]);
    int16_t index = _native->GetRecordingDevice();

    if (devicesCount == 0 || index <= -1 || index > (devicesCount - 1)) {
      return (RTC_OBJC_TYPE(RTCIODevice) *)nil;
    }

    return (RTC_OBJC_TYPE(RTCIODevice) *)[devices objectAtIndex:index];
  });
}

- (void)setInputDevice:(RTC_OBJC_TYPE(RTCIODevice) *)device {
  [self trySetInputDevice:device];
}

- (BOOL)trySetInputDevice:(RTC_OBJC_TYPE(RTCIODevice) *)device {
  if (![self isModuleReady]) {
    return NO;
  }
  return _workerThread->BlockingCall([self, device] {
    NSUInteger index = 0;
    NSArray *devices = [self _inputDevices];

    if ([devices count] == 0) {
      return NO;
    }

    if (device != nil) {
      index = [devices indexOfObjectPassingTest:^BOOL(RTC_OBJC_TYPE(RTCIODevice) * e, NSUInteger i,
                                                      BOOL * stop) {
        return (*stop = [e.deviceId isEqualToString:device.deviceId]);
      }];
      if (index == NSNotFound) {
        return NO;
      }
    }

    if (_native->SetRecordingDevice(index)) {
      return YES;
    }

    return NO;
  });
}

- (BOOL)playing {
  if (![self isModuleReady]) {
    return NO;
  }
  return _workerThread->BlockingCall([self] { return _native->Playing(); });
}

- (BOOL)recording {
  if (![self isModuleReady]) {
    return NO;
  }
  return _workerThread->BlockingCall([self] { return _native->Recording(); });
}

#pragma mark - Low-level access

- (NSInteger)reset {
  if (![self isModuleReady]) {
    return -1;
  }
  return _workerThread->BlockingCall([self] { return _native->Reset(); });
}

- (NSInteger)startPlayout {
  if (![self isModuleReady]) {
    return -1;
  }
  return _workerThread->BlockingCall([self] { return _native->StartPlayout(); });
}

- (NSInteger)stopPlayout {
  if (![self isModuleReady]) {
    return -1;
  }
  return _workerThread->BlockingCall([self] { return _native->StopPlayout(); });
}

- (NSInteger)initPlayout {
  if (![self isModuleReady]) {
    return -1;
  }
  return _workerThread->BlockingCall([self] { return _native->InitPlayout(); });
}

- (NSInteger)startRecording {
  if (![self isModuleReady]) {
    return -1;
  }
  return _workerThread->BlockingCall([self] { return _native->StartRecording(); });
}

- (NSInteger)stopRecording {
  if (![self isModuleReady]) {
    return -1;
  }
  return _workerThread->BlockingCall([self] { return _native->StopRecording(); });
}

- (NSInteger)initRecording {
  if (![self isModuleReady]) {
    return -1;
  }
  return _workerThread->BlockingCall([self] { return _native->InitRecording(); });
}

- (NSInteger)initAndStartRecording {
  if (![self isModuleReady]) {
    return -1;
  }
#if defined(WEBRTC_INCLUDE_INTERNAL_AUDIO_DEVICE)
  return _workerThread->BlockingCall([self] {
    webrtc::AudioEngineDevice *engine_device =
        static_cast<webrtc::AudioEngineDevice *>(_native.get());
    if (engine_device != nullptr) {
      return engine_device->InitAndStartRecording();
    } else {
      _native->InitRecording();
      return _native->StartRecording();
    }
  });
#else
  NSInteger result = [self initRecording];
  return result == 0 ? [self startRecording] : result;
#endif
}

- (BOOL)isPlayoutInitialized {
  if (![self isModuleReady]) {
    return NO;
  }
  return _workerThread->BlockingCall([self] { return _native->PlayoutIsInitialized(); });
}

- (BOOL)isRecordingInitialized {
  if (![self isModuleReady]) {
    return NO;
  }
  return _workerThread->BlockingCall([self] { return _native->RecordingIsInitialized(); });
}

- (BOOL)isPlaying {
  if (![self isModuleReady]) {
    return NO;
  }
  return _workerThread->BlockingCall([self] { return _native->Playing(); });
}

- (BOOL)isRecording {
  if (![self isModuleReady]) {
    return NO;
  }
  return _workerThread->BlockingCall([self] { return _native->Recording(); });
}

- (BOOL)isEngineRunning {
#if !defined(WEBRTC_INCLUDE_INTERNAL_AUDIO_DEVICE)
  return NO;
#else
  if (![self isNativeModuleReady] || ![self isWorkerThreadReady] || ![self isAudioEngineModule]) {
    return false;
  }
  webrtc::AudioEngineDevice *module = static_cast<webrtc::AudioEngineDevice *>(_native.get());
  if (module == nullptr) {
    return false;
  }

  return _workerThread->BlockingCall([module] { return module->IsEngineRunning(); });
#endif
}

- (BOOL)isMicrophoneMuted {
  if (![self isModuleReady]) {
    return NO;
  }
  return _workerThread->BlockingCall([self] {
    bool value = false;
    return _native->MicrophoneMute(&value) == 0 ? value : NO;
  });
}

- (NSInteger)setMicrophoneMuted:(BOOL)muted {
  if (![self isModuleReady]) {
    return -1;
  }
  return _workerThread->BlockingCall([self, muted] { return _native->SetMicrophoneMute(muted); });
}

- (RTC_OBJC_TYPE(RTCAudioEngineState))engineState {
#if !defined(WEBRTC_INCLUDE_INTERNAL_AUDIO_DEVICE)
  return RTC_OBJC_TYPE(RTCAudioEngineState)();
#else
  if (![self isNativeModuleReady] || ![self isWorkerThreadReady] || ![self isAudioEngineModule]) {
    return RTC_OBJC_TYPE(RTCAudioEngineState)();
  }
  webrtc::AudioEngineDevice *module = static_cast<webrtc::AudioEngineDevice *>(_native.get());
  if (module == nullptr) return RTC_OBJC_TYPE(RTCAudioEngineState)();

  return _workerThread->BlockingCall([module] {
    webrtc::AudioEngineDevice::EngineState state;
    if (module->GetEngineState(&state) != 0) return RTC_OBJC_TYPE(RTCAudioEngineState)();

    RTC_OBJC_TYPE(RTCAudioEngineState) result;
    result.outputEnabled = state.output_enabled;
    result.outputRunning = state.output_running;
    result.inputEnabled = state.input_enabled;
    result.inputRunning = state.input_running;
    result.inputMuted = state.input_muted;
    result.muteMode = MuteModeToObjC(state.mute_mode);
    return result;
  });
#endif
}

- (void)setEngineState:(RTC_OBJC_TYPE(RTCAudioEngineState))state {
#if !defined(WEBRTC_INCLUDE_INTERNAL_AUDIO_DEVICE)
  return;
#else
  if (![self isNativeModuleReady] || ![self isWorkerThreadReady] || ![self isAudioEngineModule]) {
    return;
  }
  webrtc::AudioEngineDevice *module = static_cast<webrtc::AudioEngineDevice *>(_native.get());
  if (module == nullptr) return;

  _workerThread->BlockingCall([module, state] {
    webrtc::AudioEngineDevice::EngineState result;
    result.output_enabled = state.outputEnabled;
    result.output_running = state.outputRunning;
    result.input_enabled = state.inputEnabled;
    result.input_running = state.inputRunning;
    result.input_muted = state.inputMuted;
    result.mute_mode = MuteModeToRTC(state.muteMode);

    module->SetEngineState(result);
  });
#endif
}

#pragma mark - Unique to AudioEngineDevice

- (NSInteger)setEngineAvailability:(RTC_OBJC_TYPE(RTCAudioEngineAvailability))availability {
#if !defined(WEBRTC_INCLUDE_INTERNAL_AUDIO_DEVICE)
  return -1;
#else
  if (![self isNativeModuleReady] || ![self isWorkerThreadReady] || ![self isAudioEngineModule]) {
    return -1;
  }
  webrtc::AudioEngineDevice *module = static_cast<webrtc::AudioEngineDevice *>(_native.get());
  if (module == nullptr) return -1;

  return _workerThread->BlockingCall([module, availability] {
    return module->SetEngineAvailability(availability.isInputAvailable,
                                         availability.isOutputAvailable);
  });
#endif
}

- (RTC_OBJC_TYPE(RTCAudioEngineAvailability))engineAvailability {
#if !defined(WEBRTC_INCLUDE_INTERNAL_AUDIO_DEVICE)
  return RTC_OBJC_TYPE(RTCAudioEngineAvailability)(NO, NO);
#else
  if (![self isNativeModuleReady] || ![self isWorkerThreadReady] || ![self isAudioEngineModule]) {
    return RTC_OBJC_TYPE(RTCAudioEngineAvailability)(NO, NO);
  }
  webrtc::AudioEngineDevice *module = static_cast<webrtc::AudioEngineDevice *>(_native.get());
  if (module == nullptr) return RTC_OBJC_TYPE(RTCAudioEngineAvailability)(NO, NO);

  return _workerThread->BlockingCall([module] {
    bool input_available = false;
    bool output_available = false;
    int32_t result = module->EngineAvailability(&input_available, &output_available);
    if (result != 0) return RTC_OBJC_TYPE(RTCAudioEngineAvailability)(NO, NO);

    return RTC_OBJC_TYPE(RTCAudioEngineAvailability)(input_available, output_available);
  });
#endif
}

- (BOOL)isRecordingAlwaysPreparedMode {
#if !defined(WEBRTC_INCLUDE_INTERNAL_AUDIO_DEVICE)
  return NO;
#else
  if (![self isNativeModuleReady] || ![self isWorkerThreadReady] || ![self isAudioEngineModule]) {
    return NO;
  }
  webrtc::AudioEngineDevice *module = static_cast<webrtc::AudioEngineDevice *>(_native.get());
  if (module == nullptr) return NO;

  return _workerThread->BlockingCall([module] {
    bool value = false;
    return module->InitRecordingPersistentMode(&value) == 0 ? value : NO;
  });
#endif
}

- (NSInteger)setRecordingAlwaysPreparedMode:(BOOL)enabled {
#if !defined(WEBRTC_INCLUDE_INTERNAL_AUDIO_DEVICE)
  return -1;
#else
  if (![self isNativeModuleReady] || ![self isWorkerThreadReady] || ![self isAudioEngineModule]) {
    return -1;
  }
  webrtc::AudioEngineDevice *module = static_cast<webrtc::AudioEngineDevice *>(_native.get());
  if (module == nullptr) return -1;

  return _workerThread->BlockingCall(
      [module, enabled] { return module->SetInitRecordingPersistentMode(enabled); });
#endif
}

- (BOOL)isManualRenderingMode {
#if !defined(WEBRTC_INCLUDE_INTERNAL_AUDIO_DEVICE)
  return NO;
#else
  if (![self isNativeModuleReady] || ![self isWorkerThreadReady] || ![self isAudioEngineModule]) {
    return NO;
  }
  webrtc::AudioEngineDevice *module = static_cast<webrtc::AudioEngineDevice *>(_native.get());
  if (module == nullptr) return NO;

  return _workerThread->BlockingCall([module] {
    bool value = false;
    return module->ManualRenderingMode(&value) == 0 ? value : NO;
  });
#endif
}

- (NSInteger)setManualRenderingMode:(BOOL)enabled {
#if !defined(WEBRTC_INCLUDE_INTERNAL_AUDIO_DEVICE)
  return -1;
#else
  if (![self isNativeModuleReady] || ![self isWorkerThreadReady] || ![self isAudioEngineModule]) {
    return -1;
  }
  webrtc::AudioEngineDevice *module = static_cast<webrtc::AudioEngineDevice *>(_native.get());
  if (module == nullptr) return -1;

  return _workerThread->BlockingCall(
      [module, enabled] { return module->SetManualRenderingMode(enabled); });
#endif
}

- (BOOL)isAdvancedDuckingEnabled {
#if !defined(WEBRTC_INCLUDE_INTERNAL_AUDIO_DEVICE)
  return NO;
#else
  if (![self isNativeModuleReady] || ![self isWorkerThreadReady] || ![self isAudioEngineModule]) {
    return NO;
  }
  webrtc::AudioEngineDevice *module = static_cast<webrtc::AudioEngineDevice *>(_native.get());
  if (module == nullptr) return NO;

  return _workerThread->BlockingCall([module] {
    bool value = false;
    return module->AdvancedDucking(&value) == 0 ? value : NO;
  });
#endif
}

- (void)setAdvancedDuckingEnabled:(BOOL)enabled {
#if !defined(WEBRTC_INCLUDE_INTERNAL_AUDIO_DEVICE)
  return;
#else
  if (![self isNativeModuleReady] || ![self isWorkerThreadReady] || ![self isAudioEngineModule]) {
    return;
  }
  webrtc::AudioEngineDevice *module = static_cast<webrtc::AudioEngineDevice *>(_native.get());
  if (module == nullptr) return;

  _workerThread->BlockingCall(
      [module, enabled] { return module->SetAdvancedDucking(enabled) == 0; });
#endif
}

- (NSInteger)duckingLevel {
#if !defined(WEBRTC_INCLUDE_INTERNAL_AUDIO_DEVICE)
  return 0;
#else
  if (![self isNativeModuleReady] || ![self isWorkerThreadReady] || ![self isAudioEngineModule]) {
    return 0;
  }
  webrtc::AudioEngineDevice *module = static_cast<webrtc::AudioEngineDevice *>(_native.get());
  if (module == nullptr) return 0;

  return _workerThread->BlockingCall([module] {
    long value = false;
    return module->DuckingLevel(&value) == 0 ? value : 0;
  });
#endif
}

- (void)setDuckingLevel:(NSInteger)value {
#if !defined(WEBRTC_INCLUDE_INTERNAL_AUDIO_DEVICE)
  return;
#else
  if (![self isNativeModuleReady] || ![self isWorkerThreadReady] || ![self isAudioEngineModule]) {
    return;
  }
  webrtc::AudioEngineDevice *module = static_cast<webrtc::AudioEngineDevice *>(_native.get());
  if (module == nullptr) return;

  _workerThread->BlockingCall([module, value] { return module->SetDuckingLevel(value) == 0; });
#endif
}

- (RTC_OBJC_TYPE(RTCAudioEngineMuteMode))muteMode {
#if !defined(WEBRTC_INCLUDE_INTERNAL_AUDIO_DEVICE)
  return RTC_OBJC_TYPE(RTCAudioEngineMuteModeUnknown);
#else
  if (![self isNativeModuleReady] || ![self isWorkerThreadReady] || ![self isAudioEngineModule]) {
    return RTC_OBJC_TYPE(RTCAudioEngineMuteModeUnknown);
  }
  webrtc::AudioEngineDevice *module = static_cast<webrtc::AudioEngineDevice *>(_native.get());
  if (module == nullptr) return RTC_OBJC_TYPE(RTCAudioEngineMuteModeUnknown);

  return _workerThread->BlockingCall([module] {
    webrtc::AudioEngineDevice::MuteMode mode;
    return module->GetMuteMode(&mode) == 0 ? MuteModeToObjC(mode)
                                           : RTC_OBJC_TYPE(RTCAudioEngineMuteModeUnknown);
  });
#endif
}

- (NSInteger)setMuteMode:(RTC_OBJC_TYPE(RTCAudioEngineMuteMode))mode {
#if !defined(WEBRTC_INCLUDE_INTERNAL_AUDIO_DEVICE)
  return -1;
#else
  if (![self isNativeModuleReady] || ![self isWorkerThreadReady] || ![self isAudioEngineModule]) {
    return -1;
  }
  webrtc::AudioEngineDevice *module = static_cast<webrtc::AudioEngineDevice *>(_native.get());
  if (module == nullptr) return -1;

  return _workerThread->BlockingCall(
      [module, mode] { return module->SetMuteMode(MuteModeToRTC(mode)); });
#endif
}

- (BOOL)isVoiceProcessingEnabled {
#if !defined(WEBRTC_INCLUDE_INTERNAL_AUDIO_DEVICE)
  return NO;
#else
  if (![self isNativeModuleReady] || ![self isWorkerThreadReady] || ![self isAudioEngineModule]) {
    return NO;
  }
  webrtc::AudioEngineDevice *module = static_cast<webrtc::AudioEngineDevice *>(_native.get());
  if (module == nullptr) return NO;

  return _workerThread->BlockingCall([module] {
    bool value = false;
    return module->VoiceProcessingEnabled(&value) == 0 ? value : NO;
  });
#endif
}

- (NSInteger)setVoiceProcessingEnabled:(BOOL)enabled {
#if !defined(WEBRTC_INCLUDE_INTERNAL_AUDIO_DEVICE)
  return -1;
#else
  if (![self isNativeModuleReady] || ![self isWorkerThreadReady] || ![self isAudioEngineModule]) {
    return -1;
  }
  webrtc::AudioEngineDevice *module = static_cast<webrtc::AudioEngineDevice *>(_native.get());
  if (module == nullptr) return -1;

  return _workerThread->BlockingCall(
      [module, enabled] { return module->SetVoiceProcessingEnabled(enabled); });
#endif
}

- (BOOL)isVoiceProcessingBypassed {
#if !defined(WEBRTC_INCLUDE_INTERNAL_AUDIO_DEVICE)
  return NO;
#else
  if (![self isNativeModuleReady] || ![self isWorkerThreadReady] || ![self isAudioEngineModule]) {
    return NO;
  }
  webrtc::AudioEngineDevice *module = static_cast<webrtc::AudioEngineDevice *>(_native.get());
  if (module == nullptr) return NO;

  return _workerThread->BlockingCall([module] {
    bool value = false;
    return module->VoiceProcessingBypassed(&value) == 0 ? value : NO;
  });
#endif
}

- (void)setVoiceProcessingBypassed:(BOOL)enabled {
#if !defined(WEBRTC_INCLUDE_INTERNAL_AUDIO_DEVICE)
  return;
#else
  if (![self isNativeModuleReady] || ![self isWorkerThreadReady] || ![self isAudioEngineModule]) {
    return;
  }
  webrtc::AudioEngineDevice *module = static_cast<webrtc::AudioEngineDevice *>(_native.get());
  if (module == nullptr) return;

  _workerThread->BlockingCall(
      [module, enabled] { return module->SetVoiceProcessingBypassed(enabled) == 0; });
#endif
}

- (BOOL)isVoiceProcessingAGCEnabled {
#if !defined(WEBRTC_INCLUDE_INTERNAL_AUDIO_DEVICE)
  return NO;
#else
  if (![self isNativeModuleReady] || ![self isWorkerThreadReady] || ![self isAudioEngineModule]) {
    return NO;
  }
  webrtc::AudioEngineDevice *module = static_cast<webrtc::AudioEngineDevice *>(_native.get());
  if (module == nullptr) return NO;

  return _workerThread->BlockingCall([module] {
    bool value = false;
    return module->VoiceProcessingAGCEnabled(&value) == 0 ? value : NO;
  });
#endif
}

- (void)setVoiceProcessingAGCEnabled:(BOOL)enabled {
#if !defined(WEBRTC_INCLUDE_INTERNAL_AUDIO_DEVICE)
  return;
#else
  if (![self isNativeModuleReady] || ![self isWorkerThreadReady] || ![self isAudioEngineModule]) {
    return;
  }
  webrtc::AudioEngineDevice *module = static_cast<webrtc::AudioEngineDevice *>(_native.get());
  if (module == nullptr) return;

  _workerThread->BlockingCall(
      [module, enabled] { return module->SetVoiceProcessingAGCEnabled(enabled) == 0; });
#endif
}

- (BOOL)isStereoPlayoutAvailable {
#if !defined(WEBRTC_INCLUDE_INTERNAL_AUDIO_DEVICE)
  return NO;
#else
  if (![self isNativeModuleReady] || ![self isWorkerThreadReady] || ![self isAudioEngineModule]) {
    return NO;
  }
  webrtc::AudioEngineDevice *module = static_cast<webrtc::AudioEngineDevice *>(_native.get());
  if (module == nullptr) return NO;

  return _workerThread->BlockingCall([module] {
    bool value = false;
    return module->StereoPlayoutIsAvailable(&value) == 0 ? value : NO;
  });
#endif
}

- (BOOL)isStereoPlayoutEnabled {
#if !defined(WEBRTC_INCLUDE_INTERNAL_AUDIO_DEVICE)
  return NO;
#else
  if (![self isNativeModuleReady] || ![self isWorkerThreadReady] || ![self isAudioEngineModule]) {
    return NO;
  }
  webrtc::AudioEngineDevice *module = static_cast<webrtc::AudioEngineDevice *>(_native.get());
  if (module == nullptr) return NO;

  return _workerThread->BlockingCall([module] {
    bool value = false;
    return module->StereoPlayout(&value) == 0 ? value : NO;
  });
#endif
}

- (BOOL)prefersStereoPlayout {
#if !defined(WEBRTC_INCLUDE_INTERNAL_AUDIO_DEVICE)
  return NO;
#else
  if (![self isNativeModuleReady] || ![self isWorkerThreadReady] || ![self isAudioEngineModule]) {
    return NO;
  }
  webrtc::AudioEngineDevice *module = static_cast<webrtc::AudioEngineDevice *>(_native.get());
  if (module == nullptr) return NO;

  return _workerThread->BlockingCall([module] {
    webrtc::AudioEngineDevice::EngineState state;
    if (module->GetEngineState(&state) != 0) {
      return false;
    }
    return state.prefers_stereo_playout;
  });
#endif
}

- (void)setPrefersStereoPlayout:(BOOL)enabled {
#if !defined(WEBRTC_INCLUDE_INTERNAL_AUDIO_DEVICE)
  return;
#else
  if (![self isNativeModuleReady] || ![self isWorkerThreadReady] || ![self isAudioEngineModule]) {
    return;
  }
  webrtc::AudioEngineDevice *module = static_cast<webrtc::AudioEngineDevice *>(_native.get());
  if (module == nullptr) return;

  _workerThread->BlockingCall([module, enabled] { module->SetStereoPlayout(enabled); });
#endif
}

- (void)refreshStereoPlayoutState {
#if !defined(WEBRTC_INCLUDE_INTERNAL_AUDIO_DEVICE)
  return;
#else
  if (![self isNativeModuleReady] || ![self isWorkerThreadReady] || ![self isAudioEngineModule]) {
    return;
  }
  webrtc::AudioEngineDevice *module = static_cast<webrtc::AudioEngineDevice *>(_native.get());
  if (module == nullptr) return;

  _workerThread->BlockingCall([module] { module->RefreshStereoPlayoutState(); });
#endif
}

#pragma mark - Private

- (NSArray<RTC_OBJC_TYPE(RTCIODevice) *> *)_outputDevices {
  char guid[webrtc::kAdmMaxGuidSize + 1] = {0};
  char name[webrtc::kAdmMaxDeviceNameSize + 1] = {0};

  NSMutableArray *result = [NSMutableArray array];

  int16_t count = _native->PlayoutDevices();

  if (count > 0) {
    for (int i = 0; i < count; i++) {
      _native->PlayoutDeviceName(i, name, guid);
      NSString *strGUID = [[NSString alloc] initWithCString:guid encoding:NSUTF8StringEncoding];
      NSString *strName = [[NSString alloc] initWithCString:name encoding:NSUTF8StringEncoding];
      RTC_OBJC_TYPE(RTCIODevice) *device =
          [[RTC_OBJC_TYPE(RTCIODevice) alloc] initWithType:RTC_OBJC_TYPE(RTCIODeviceTypeOutput)
                                                  deviceId:strGUID
                                                      name:strName];
      [result addObject:device];
    }
  }

  return result;
}

- (NSArray<RTC_OBJC_TYPE(RTCIODevice) *> *)_inputDevices {
  char guid[webrtc::kAdmMaxGuidSize + 1] = {0};
  char name[webrtc::kAdmMaxDeviceNameSize + 1] = {0};

  NSMutableArray *result = [NSMutableArray array];

  int16_t count = _native->RecordingDevices();

  if (count > 0) {
    for (int i = 0; i < count; i++) {
      _native->RecordingDeviceName(i, name, guid);
      NSString *strGUID = [[NSString alloc] initWithCString:guid encoding:NSUTF8StringEncoding];
      NSString *strName = [[NSString alloc] initWithCString:name encoding:NSUTF8StringEncoding];
      RTC_OBJC_TYPE(RTCIODevice) *device =
          [[RTC_OBJC_TYPE(RTCIODevice) alloc] initWithType:RTC_OBJC_TYPE(RTCIODeviceTypeInput)
                                                  deviceId:strGUID
                                                      name:strName];
      [result addObject:device];
    }
  }

  return result;
}

@end
