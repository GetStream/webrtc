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

#import "RTCAudioDeviceModule+Private.h"
#import "RTCAudioDeviceModule.h"
#import "RTCIODevice+Private.h"
#import "base/RTCLogging.h"

#import "modules/audio_device/audio_engine_device.h"
#import "sdk/objc/native/api/audio_device_module.h"

NSString *const RTC_CONSTANT_TYPE(RTCAudioEngineInputMixerNodeKey) =
    webrtc::kAudioEngineInputMixerNodeKey;

inline webrtc::AudioEngineDevice::MuteMode MuteModeToRTC(RTC_OBJC_TYPE(RTCAudioEngineMuteMode)
                                                             mode) {
  return static_cast<webrtc::AudioEngineDevice::MuteMode>(mode);
}

inline RTC_OBJC_TYPE(RTCAudioEngineMuteMode)
    MuteModeToObjC(webrtc::AudioEngineDevice::MuteMode mode) {
  return static_cast<RTC_OBJC_TYPE(RTCAudioEngineMuteMode)>(mode);
}

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
  webrtc::scoped_refptr<webrtc::AudioDeviceModule> native = _native;
  webrtc::Thread *workerThread = _workerThread;
  AudioDeviceObserver *observer = _observer;

  if (observer == nullptr) {
    _workerThread = nullptr;
    return;
  }

  if (native == nullptr) {
    observer->delegate_ = nil;
    delete observer;
    _observer = nullptr;
    _workerThread = nullptr;
    return;
  }

  if (workerThread && !workerThread->IsQuitting()) {
    workerThread->BlockingCall([native, observer] {
      native->SetObserver(nullptr);
      observer->delegate_ = nil;
    });
    delete observer;
    _observer = nullptr;
  } else {
    observer->delegate_ = nil;
  }

  _workerThread = nullptr;
}

- (NSArray<RTC_OBJC_TYPE(RTCIODevice) *> *)outputDevices {
  return _workerThread->BlockingCall([self] { return [self _outputDevices]; });
}

- (NSArray<RTC_OBJC_TYPE(RTCIODevice) *> *)inputDevices {
  return _workerThread->BlockingCall([self] { return [self _inputDevices]; });
}

- (RTC_OBJC_TYPE(RTCIODevice) *)outputDevice {
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
  return _workerThread->BlockingCall([self] { return _native->Playing(); });
}

- (BOOL)recording {
  return _workerThread->BlockingCall([self] { return _native->Recording(); });
}

#pragma mark - Low-level access

- (NSInteger)reset {
  if (![self isNativeModuleReady] || ![self isWorkerThreadReady]) {
    return -1;
  }
  return _workerThread->BlockingCall([self] { return _native->Reset(); });
}

- (NSInteger)startPlayout {
  return _workerThread->BlockingCall([self] { return _native->StartPlayout(); });
}

- (NSInteger)stopPlayout {
  return _workerThread->BlockingCall([self] { return _native->StopPlayout(); });
}

- (NSInteger)initPlayout {
  return _workerThread->BlockingCall([self] { return _native->InitPlayout(); });
}

- (NSInteger)startRecording {
  return _workerThread->BlockingCall([self] { return _native->StartRecording(); });
}

- (NSInteger)stopRecording {
  return _workerThread->BlockingCall([self] { return _native->StopRecording(); });
}

- (NSInteger)initRecording {
  return _workerThread->BlockingCall([self] { return _native->InitRecording(); });
}

- (NSInteger)initAndStartRecording {
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
}

- (BOOL)isPlayoutInitialized {
  return _workerThread->BlockingCall([self] { return _native->PlayoutIsInitialized(); });
}

- (BOOL)isRecordingInitialized {
  return _workerThread->BlockingCall([self] { return _native->RecordingIsInitialized(); });
}

- (BOOL)isPlaying {
  return _workerThread->BlockingCall([self] { return _native->Playing(); });
}

- (BOOL)isRecording {
  return _workerThread->BlockingCall([self] { return _native->Recording(); });
}

- (BOOL)isEngineRunning {
  if (![self isNativeModuleReady] || ![self isWorkerThreadReady] || ![self isAudioEngineModule]) {
    return false;
  }
  webrtc::AudioEngineDevice *module = static_cast<webrtc::AudioEngineDevice *>(_native.get());
  if (module == nullptr) {
    return false;
  }

  return _workerThread->BlockingCall([module] { return module->IsEngineRunning(); });
}

- (BOOL)isMicrophoneMuted {
  return _workerThread->BlockingCall([self] {
    bool value = false;
    return _native->MicrophoneMute(&value) == 0 ? value : NO;
  });
}

- (NSInteger)setMicrophoneMuted:(BOOL)muted {
  return _workerThread->BlockingCall([self, muted] { return _native->SetMicrophoneMute(muted); });
}

- (RTC_OBJC_TYPE(RTCAudioEngineState))engineState {
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
}

- (void)setEngineState:(RTC_OBJC_TYPE(RTCAudioEngineState))state {
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
}

#pragma mark - Unique to AudioEngineDevice

- (BOOL)isRecordingAlwaysPreparedMode {
  if (![self isNativeModuleReady] || ![self isWorkerThreadReady] || ![self isAudioEngineModule]) {
    return NO;
  }
  webrtc::AudioEngineDevice *module = static_cast<webrtc::AudioEngineDevice *>(_native.get());
  if (module == nullptr) return NO;

  return _workerThread->BlockingCall([module] {
    bool value = false;
    return module->InitRecordingPersistentMode(&value) == 0 ? value : NO;
  });
}

- (NSInteger)setRecordingAlwaysPreparedMode:(BOOL)enabled {
  if (![self isNativeModuleReady] || ![self isWorkerThreadReady] || ![self isAudioEngineModule]) {
    return -1;
  }
  webrtc::AudioEngineDevice *module = static_cast<webrtc::AudioEngineDevice *>(_native.get());
  if (module == nullptr) return -1;

  return _workerThread->BlockingCall(
      [module, enabled] { return module->SetInitRecordingPersistentMode(enabled); });
}

- (BOOL)isManualRenderingMode {
  if (![self isNativeModuleReady] || ![self isWorkerThreadReady] || ![self isAudioEngineModule]) {
    return NO;
  }
  webrtc::AudioEngineDevice *module = static_cast<webrtc::AudioEngineDevice *>(_native.get());
  if (module == nullptr) return NO;

  return _workerThread->BlockingCall([module] {
    bool value = false;
    return module->ManualRenderingMode(&value) == 0 ? value : NO;
  });
}

- (NSInteger)setManualRenderingMode:(BOOL)enabled {
  if (![self isNativeModuleReady] || ![self isWorkerThreadReady] || ![self isAudioEngineModule]) {
    return -1;
  }
  webrtc::AudioEngineDevice *module = static_cast<webrtc::AudioEngineDevice *>(_native.get());
  if (module == nullptr) return -1;

  return _workerThread->BlockingCall(
      [module, enabled] { return module->SetManualRenderingMode(enabled); });
}

- (BOOL)isAdvancedDuckingEnabled {
  if (![self isNativeModuleReady] || ![self isWorkerThreadReady] || ![self isAudioEngineModule]) {
    return NO;
  }
  webrtc::AudioEngineDevice *module = static_cast<webrtc::AudioEngineDevice *>(_native.get());
  if (module == nullptr) return NO;

  return _workerThread->BlockingCall([module] {
    bool value = false;
    return module->AdvancedDucking(&value) == 0 ? value : NO;
  });
}

- (void)setAdvancedDuckingEnabled:(BOOL)enabled {
  if (![self isNativeModuleReady] || ![self isWorkerThreadReady] || ![self isAudioEngineModule]) {
    return;
  }
  webrtc::AudioEngineDevice *module = static_cast<webrtc::AudioEngineDevice *>(_native.get());
  if (module == nullptr) return;

  _workerThread->BlockingCall(
      [module, enabled] { return module->SetAdvancedDucking(enabled) == 0; });
}

- (NSInteger)duckingLevel {
  if (![self isNativeModuleReady] || ![self isWorkerThreadReady] || ![self isAudioEngineModule]) {
    return 0;
  }
  webrtc::AudioEngineDevice *module = static_cast<webrtc::AudioEngineDevice *>(_native.get());
  if (module == nullptr) return 0;

  return _workerThread->BlockingCall([module] {
    long value = false;
    return module->DuckingLevel(&value) == 0 ? value : 0;
  });
}

- (void)setDuckingLevel:(NSInteger)value {
  if (![self isNativeModuleReady] || ![self isWorkerThreadReady] || ![self isAudioEngineModule]) {
    return;
  }
  webrtc::AudioEngineDevice *module = static_cast<webrtc::AudioEngineDevice *>(_native.get());
  if (module == nullptr) return;

  _workerThread->BlockingCall([module, value] { return module->SetDuckingLevel(value) == 0; });
}

- (RTC_OBJC_TYPE(RTCAudioEngineMuteMode))muteMode {
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
}

- (NSInteger)setMuteMode:(RTC_OBJC_TYPE(RTCAudioEngineMuteMode))mode {
  if (![self isNativeModuleReady] || ![self isWorkerThreadReady] || ![self isAudioEngineModule]) {
    return -1;
  }
  webrtc::AudioEngineDevice *module = static_cast<webrtc::AudioEngineDevice *>(_native.get());
  if (module == nullptr) return -1;

  return _workerThread->BlockingCall(
      [module, mode] { return module->SetMuteMode(MuteModeToRTC(mode)); });
}

- (BOOL)isVoiceProcessingEnabled {
  if (![self isNativeModuleReady] || ![self isWorkerThreadReady] || ![self isAudioEngineModule]) {
    return NO;
  }
  webrtc::AudioEngineDevice *module = static_cast<webrtc::AudioEngineDevice *>(_native.get());
  if (module == nullptr) return NO;

  return _workerThread->BlockingCall([module] {
    bool value = false;
    return module->VoiceProcessingEnabled(&value) == 0 ? value : NO;
  });
}

- (NSInteger)setVoiceProcessingEnabled:(BOOL)enabled {
  if (![self isNativeModuleReady] || ![self isWorkerThreadReady] || ![self isAudioEngineModule]) {
    return -1;
  }
  webrtc::AudioEngineDevice *module = static_cast<webrtc::AudioEngineDevice *>(_native.get());
  if (module == nullptr) return -1;

  return _workerThread->BlockingCall(
      [module, enabled] { return module->SetVoiceProcessingEnabled(enabled); });
}

- (BOOL)isVoiceProcessingBypassed {
  if (![self isNativeModuleReady] || ![self isWorkerThreadReady] || ![self isAudioEngineModule]) {
    return NO;
  }
  webrtc::AudioEngineDevice *module = static_cast<webrtc::AudioEngineDevice *>(_native.get());
  if (module == nullptr) return NO;

  return _workerThread->BlockingCall([module] {
    bool value = false;
    return module->VoiceProcessingBypassed(&value) == 0 ? value : NO;
  });
}

- (void)setVoiceProcessingBypassed:(BOOL)enabled {
  if (![self isNativeModuleReady] || ![self isWorkerThreadReady] || ![self isAudioEngineModule]) {
    return;
  }
  webrtc::AudioEngineDevice *module = static_cast<webrtc::AudioEngineDevice *>(_native.get());
  if (module == nullptr) return;

  _workerThread->BlockingCall(
      [module, enabled] { return module->SetVoiceProcessingBypassed(enabled) == 0; });
}

- (BOOL)isVoiceProcessingAGCEnabled {
  if (![self isNativeModuleReady] || ![self isWorkerThreadReady] || ![self isAudioEngineModule]) {
    return NO;
  }
  webrtc::AudioEngineDevice *module = static_cast<webrtc::AudioEngineDevice *>(_native.get());
  if (module == nullptr) return NO;

  return _workerThread->BlockingCall([module] {
    bool value = false;
    return module->VoiceProcessingAGCEnabled(&value) == 0 ? value : NO;
  });
}

- (void)setVoiceProcessingAGCEnabled:(BOOL)enabled {
  if (![self isNativeModuleReady] || ![self isWorkerThreadReady] || ![self isAudioEngineModule]) {
    return;
  }
  webrtc::AudioEngineDevice *module = static_cast<webrtc::AudioEngineDevice *>(_native.get());
  if (module == nullptr) return;

  _workerThread->BlockingCall(
      [module, enabled] { return module->SetVoiceProcessingAGCEnabled(enabled) == 0; });
}

- (BOOL)isStereoPlayoutAvailable {
  if (![self isNativeModuleReady] || ![self isWorkerThreadReady] || ![self isAudioEngineModule]) {
    return NO;
  }
  webrtc::AudioEngineDevice *module = static_cast<webrtc::AudioEngineDevice *>(_native.get());
  if (module == nullptr) return NO;

  return _workerThread->BlockingCall([module] {
    bool value = false;
    return module->StereoPlayoutIsAvailable(&value) == 0 ? value : NO;
  });
}

- (BOOL)isStereoPlayoutEnabled {
  if (![self isNativeModuleReady] || ![self isWorkerThreadReady] || ![self isAudioEngineModule]) {
    return NO;
  }
  webrtc::AudioEngineDevice *module = static_cast<webrtc::AudioEngineDevice *>(_native.get());
  if (module == nullptr) return NO;

  return _workerThread->BlockingCall([module] {
    bool value = false;
    return module->StereoPlayout(&value) == 0 ? value : NO;
  });
}

- (BOOL)prefersStereoPlayout {
  webrtc::AudioEngineDevice *module = static_cast<webrtc::AudioEngineDevice *>(_native.get());
  if (module == nullptr) return NO;

  return _workerThread->BlockingCall([module] {
    webrtc::AudioEngineDevice::EngineState state;
    if (module->GetEngineState(&state) != 0) {
      return false;
    }
    return state.prefers_stereo_playout;
  });
}

- (void)setPrefersStereoPlayout:(BOOL)enabled {
  if (![self isNativeModuleReady] || ![self isWorkerThreadReady] || ![self isAudioEngineModule]) {
    return;
  }
  webrtc::AudioEngineDevice *module = static_cast<webrtc::AudioEngineDevice *>(_native.get());
  if (module == nullptr) return;

  _workerThread->BlockingCall([module, enabled] { module->SetStereoPlayout(enabled); });
}

- (void)refreshStereoPlayoutState {
  if (![self isNativeModuleReady] || ![self isWorkerThreadReady] || ![self isAudioEngineModule]) {
    return;
  }
  webrtc::AudioEngineDevice *module = static_cast<webrtc::AudioEngineDevice *>(_native.get());
  if (module == nullptr) return;

  _workerThread->BlockingCall([module] { module->RefreshStereoPlayoutState(); });
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
