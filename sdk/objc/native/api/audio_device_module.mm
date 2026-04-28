/*
 *  Copyright 2018 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#include "audio_device_module.h"

#include "api/environment/environment_factory.h"
#include "api/make_ref_counted.h"
#include "rtc_base/logging.h"

#if defined(WEBRTC_IOS)
#include "sdk/objc/native/src/audio/audio_device_module_ios.h"
#endif

#include "modules/audio_device/include/audio_device.h"

namespace webrtc {

webrtc::scoped_refptr<AudioDeviceModule> CreateAudioDeviceModule(
    bool bypass_voice_processing) {
  return CreateAudioDeviceModule(CreateEnvironment(), bypass_voice_processing);
}

webrtc::scoped_refptr<AudioDeviceModule> CreateAudioDeviceModule(
    const Environment& env,
    bool bypass_voice_processing) {
  RTC_DLOG(LS_INFO) << __FUNCTION__;
#if defined(WEBRTC_IOS)
  return webrtc::make_ref_counted<ios_adm::AudioDeviceModuleIOS>(
      env,
      bypass_voice_processing,
      /*muted_speech_event_handler=*/nullptr,
      /*error_handler=*/nullptr);
#else
  RTC_LOG(LS_ERROR)
      << "current platform is not supported => this module will self destruct!";
  return nullptr;
#endif
}

webrtc::scoped_refptr<AudioDeviceModule> CreateMutedDetectAudioDeviceModule(
    AudioDeviceModule::MutedSpeechEventHandler muted_speech_event_handler,
    bool bypass_voice_processing) {
  return CreateMutedDetectAudioDeviceModule(CreateEnvironment(),
                                            muted_speech_event_handler,
                                            /*error_handler=*/nullptr,
                                            bypass_voice_processing);
}

webrtc::scoped_refptr<AudioDeviceModule> CreateMutedDetectAudioDeviceModule(
    const Environment& env,
    AudioDeviceModule::MutedSpeechEventHandler muted_speech_event_handler,
    bool bypass_voice_processing) {
  return CreateMutedDetectAudioDeviceModule(env,
                                            muted_speech_event_handler,
                                            /*error_handler=*/nullptr,
                                            bypass_voice_processing);
}

webrtc::scoped_refptr<AudioDeviceModule> CreateMutedDetectAudioDeviceModule(
    AudioDeviceModule::MutedSpeechEventHandler muted_speech_event_handler,
    ADMErrorHandler error_handler,
    bool bypass_voice_processing) {
  return CreateMutedDetectAudioDeviceModule(CreateEnvironment(),
                                            muted_speech_event_handler,
                                            error_handler,
                                            bypass_voice_processing);
}

webrtc::scoped_refptr<AudioDeviceModule> CreateMutedDetectAudioDeviceModule(
    const Environment& env,
    AudioDeviceModule::MutedSpeechEventHandler muted_speech_event_handler,
    ADMErrorHandler error_handler,
    bool bypass_voice_processing) {
  RTC_DLOG(LS_INFO) << __FUNCTION__;
#if defined(WEBRTC_IOS)
  return webrtc::make_ref_counted<ios_adm::AudioDeviceModuleIOS>(
      env, bypass_voice_processing, muted_speech_event_handler, error_handler);
#else
  RTC_LOG(LS_ERROR)
      << "current platform is not supported => this module will self destruct!";
  return nullptr;
#endif
}
}  // namespace webrtc
