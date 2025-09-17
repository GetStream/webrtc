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

#import "RTCAudioDeviceModule.h"
#import "sdk/objc/native/api/audio_device_module.h"

#include "rtc_base/thread.h"

NS_ASSUME_NONNULL_BEGIN

typedef void (^RTCMicrophoneFrameBlock)(int16_t *samples,
                                        size_t frames,
                                        int sampleRate,
                                        size_t channels,
                                        int64_t timestampNs);

@interface RTC_OBJC_TYPE(RTCAudioDeviceModule) ()

- (instancetype)initWithNativeModule:(webrtc::scoped_refptr<webrtc::AudioDeviceModule>)module
                        workerThread:(webrtc::Thread *)workerThread;

- (void)setMicrophoneFrameBlock:(nullable RTCMicrophoneFrameBlock)block;

@end

NS_ASSUME_NONNULL_END
