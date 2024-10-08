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

#include <AudioUnit/AudioUnit.h>

#import "RTCAudioDeviceModule.h"
#import "RTCAudioDeviceModule+Private.h"
#import "RTCIODevice+Private.h"
#import "base/RTCLogging.h"

#import "sdk/objc/native/api/audio_device_module.h"

class AudioDeviceSink : public webrtc::AudioDeviceSink {
 public:
  AudioDeviceSink() {}

  void OnDevicesUpdated() override {

    RTCLogInfo(@"AudioDeviceSink OnDevicesUpdated");

    if (callback_handler_) {
      callback_handler_();
    }
  }

 // private:
  RTCOnAudioDevicesDidUpdate callback_handler_;
};

@implementation RTC_OBJC_TYPE (RTCAudioDeviceModule) {
  rtc::Thread *_workerThread;
  rtc::scoped_refptr<webrtc::AudioDeviceModule> _native;
  AudioDeviceSink *_sink;
}

- (instancetype)initWithNativeModule:(rtc::scoped_refptr<webrtc::AudioDeviceModule> )module
                        workerThread:(rtc::Thread * )workerThread {

  RTCLogInfo(@"RTCAudioDeviceModule initWithNativeModule:workerThread:");

  self = [super init];
  _native = module;
  _workerThread = workerThread;

  _sink = new AudioDeviceSink();

  _workerThread->BlockingCall([self] {
    _native->SetAudioDeviceSink(_sink);
  });

  return self;
}

- (NSArray<RTC_OBJC_TYPE(RTCIODevice) *> *)outputDevices {

  return _workerThread->BlockingCall([self] {
    return [self _outputDevices];
  });
}

- (NSArray<RTC_OBJC_TYPE(RTCIODevice) *> *)inputDevices {
  return _workerThread->BlockingCall([self] {
    return [self _inputDevices];
  });
}

- (RTCIODevice *)outputDevice {
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

- (void)setOutputDevice: (RTCIODevice *)device {
  [self trySetOutputDevice: device];
}

- (BOOL)trySetOutputDevice: (RTCIODevice *)device {

  return _workerThread->BlockingCall([self, device] {

    NSUInteger index = 0;
    NSArray *devices = [self _outputDevices];

    if ([devices count] == 0) {
      return NO;
    }

    if (device != nil) {
      index = [devices indexOfObjectPassingTest:^BOOL(RTCIODevice *e, NSUInteger i, BOOL *stop) {
        return (*stop = [e.deviceId isEqualToString:device.deviceId]);
      }];
      if (index == NSNotFound) {
        return NO;
      }
    }

    _native->StopPlayout();

    if (_native->SetPlayoutDevice(index) == 0 
        && _native->InitPlayout() == 0
        && _native->StartPlayout() == 0) {

        return YES;
    }

    return NO;
  });
}

- (RTCIODevice *)inputDevice {

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

- (void)setInputDevice: (RTCIODevice *)device {
  [self trySetInputDevice: device];
}

- (BOOL)trySetInputDevice: (RTCIODevice *)device {

  return _workerThread->BlockingCall([self, device] {

    NSUInteger index = 0;
    NSArray *devices = [self _inputDevices];

    if ([devices count] == 0) {
      return NO;
    }

    if (device != nil) {
      index = [devices indexOfObjectPassingTest:^BOOL(RTCIODevice *e, NSUInteger i, BOOL *stop) {
        return (*stop = [e.deviceId isEqualToString:device.deviceId]);
      }];
      if (index == NSNotFound) {
        return NO;
      }
    }

    _native->StopRecording();

    if (_native->SetRecordingDevice(index) == 0 
        && _native->InitRecording() == 0
        && _native->StartRecording() == 0) {

        return YES;
    }

    return NO;
  });
}

- (BOOL)playing {

  return _workerThread->BlockingCall([self] {
    return _native->Playing();
  });
}

- (BOOL)recording {

  return _workerThread->BlockingCall([self] {
    return _native->Recording();
  });
}

#pragma mark - Low-level access

- (BOOL)startPlayout {

  return _workerThread->BlockingCall([self] {
    return _native->StartPlayout() == 0;
  });
}

- (BOOL)stopPlayout {

  return _workerThread->BlockingCall([self] {
    return _native->StopPlayout() == 0;
  });
}

- (BOOL)initPlayout {

  return _workerThread->BlockingCall([self] {
    return _native->InitPlayout() == 0;
  });
}

- (BOOL)startRecording {

  return _workerThread->BlockingCall([self] {
    return _native->StartRecording() == 0;
  });
}

- (BOOL)stopRecording {

  return _workerThread->BlockingCall([self] {
    return _native->StopRecording() == 0;
  });
}

- (BOOL)initRecording {

  return _workerThread->BlockingCall([self] {
    return _native->InitRecording() == 0;
  });
}

- (BOOL)setDevicesUpdatedHandler: (nullable RTCOnAudioDevicesDidUpdate) handler {
  _sink->callback_handler_ = handler;
  return YES;
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
      RTCIODevice *device = [[RTCIODevice alloc] initWithType:RTCIODeviceTypeOutput deviceId:strGUID name:strName];
      [result addObject: device];
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
      RTCIODevice *device = [[RTCIODevice alloc] initWithType:RTCIODeviceTypeInput deviceId:strGUID name:strName];
      [result addObject: device];
    }
  }

  return result;
}

@end
