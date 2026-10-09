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

#include "extensions/android/audio-processing/src/external_audio_processing_factory.h"

#include <jni.h>
#include <syslog.h>

#include "api/audio/builtin_audio_processing_builder.h"
#include "api/environment/environment_factory.h"
#include "api/make_ref_counted.h"
#include "rtc_base/ref_counted_object.h"
#include "extensions/android/audio-processing/generated_effects_jni/ExternalAudioProcessingFactory_jni.h"
#include "sdk/android/native_api/jni/java_types.h"
#include "sdk/android/native_api/jni/scoped_java_ref.h"
#include "sdk/android/src/jni/jni_helpers.h"
#include "extensions/android/audio-processing/src/external_audio_processor.h"

namespace webrtc {
namespace jni {

ExternalAudioProcessingJni::ExternalAudioProcessingJni(
    JNIEnv* jni,
    const JavaRef<jobject>& j_processing)
    : j_processing_global_(jni, j_processing) {}
ExternalAudioProcessingJni::~ExternalAudioProcessingJni() {}
void ExternalAudioProcessingJni::Initialize(int sample_rate_hz,
                                            int num_channels) {
  JNIEnv* env = AttachCurrentThreadIfNeeded();
  Java_AudioProcessing_initialize(env, j_processing_global_, sample_rate_hz,
                                  num_channels);
}

void ExternalAudioProcessingJni::Reset(int new_rate) {
  JNIEnv* env = AttachCurrentThreadIfNeeded();
  Java_AudioProcessing_reset(env, j_processing_global_, new_rate);
}

void ExternalAudioProcessingJni::Process(int num_bands, int num_frames, int buffer_size, float* buffer) {
  JNIEnv* env = AttachCurrentThreadIfNeeded();
  ScopedJavaLocalRef<jobject> audio_buffer =
      NewDirectByteBuffer(env, (void*)buffer, buffer_size * sizeof(float));
  Java_AudioProcessing_process(env, j_processing_global_, num_bands, num_frames, audio_buffer);
}

ExternalAudioProcessingFactory::ExternalAudioProcessingFactory() {
  capture_post_processor_ = new ExternalAudioProcessor();
  std::unique_ptr<webrtc::CustomProcessing> capture_post_processor(
      capture_post_processor_);

  render_pre_processor_ = new ExternalAudioProcessor();
  std::unique_ptr<webrtc::CustomProcessing> render_pre_processor(
      render_pre_processor_);

  apm_ = webrtc::BuiltinAudioProcessingBuilder()
             .SetCapturePostProcessing(std::move(capture_post_processor))
             .SetRenderPreProcessing(std::move(render_pre_processor))
             .Build(CreateEnvironment());

  webrtc::AudioProcessing::Config config;
  apm_->ApplyConfig(config);
}

static webrtc::scoped_refptr<ExternalAudioProcessingFactory> default_processor;

static jlong JNI_ExternalAudioProcessingFactory_GetDefaultApm(JNIEnv* env) {
  if (!default_processor) {
    default_processor = webrtc::make_ref_counted<ExternalAudioProcessingFactory>();
  }
  return webrtc::jni::jlongFromPointer(default_processor->apm().get());
}

static void JNI_ExternalAudioProcessingFactory_SetCaptureCompressionGain(
    JNIEnv* env,
    jint compression_gain_db) {
  if (!default_processor) {
    return;
  }
  default_processor->apm().get()->SetRuntimeSetting(AudioProcessing::RuntimeSetting::CreateCompressionGainDb(compression_gain_db));
}


static void JNI_ExternalAudioProcessingFactory_EnableGainController1(
    JNIEnv* env,
    jint mode,
    jint target_level_dbfs,
    jint compression_gain_db,
    jboolean enable_limiter
  ) {
  if (!default_processor) {
    return;
  }
  if (!default_processor->apm()) {
    return;
  }
  webrtc::AudioProcessing::Config config = default_processor->apm()->GetConfig();
  config.gain_controller1.enabled = true;
  config.gain_controller2.enabled = false;
  if (mode == 0) {
    config.gain_controller1.mode = webrtc::AudioProcessing::Config::GainController1::kAdaptiveAnalog;
  } else if (mode == 1) {
    config.gain_controller1.mode = webrtc::AudioProcessing::Config::GainController1::kAdaptiveDigital;
  } else if (mode == 2) {
    config.gain_controller1.mode = webrtc::AudioProcessing::Config::GainController1::kFixedDigital;
  }
  config.gain_controller1.target_level_dbfs = target_level_dbfs;
  config.gain_controller1.compression_gain_db = compression_gain_db;
  config.gain_controller1.enable_limiter = enable_limiter;
  default_processor->apm()->ApplyConfig(config);
}

static jlong JNI_ExternalAudioProcessingFactory_SetCapturePostProcessing(
    JNIEnv* env,
    const JavaParamRef<jobject>& j_processing) {
  if (!default_processor) {
    return 0;
  }
  auto processing =
      webrtc::make_ref_counted<ExternalAudioProcessingJni>(env, j_processing);
  processing->AddRef();
  default_processor->capture_post_processor()->SetExternalAudioProcessing(
      processing.get());
  return jlongFromPointer(processing.get());
}

static jlong JNI_ExternalAudioProcessingFactory_SetRenderPreProcessing(
    JNIEnv* env,
    const JavaParamRef<jobject>& j_processing) {
  if (!default_processor) {
    return 0;
  }
  auto processing =
      webrtc::make_ref_counted<ExternalAudioProcessingJni>(env, j_processing);
  processing->AddRef();
  default_processor->render_pre_processor()->SetExternalAudioProcessing(
      processing.get());
  return jlongFromPointer(processing.get());
}

static void JNI_ExternalAudioProcessingFactory_SetBypassFlagForCapturePost(
    JNIEnv* env,
    jboolean bypass) {
  if (!default_processor) {
    return;
  }
  default_processor->capture_post_processor()->SetBypassFlag(bypass);
}

static void JNI_ExternalAudioProcessingFactory_SetBypassFlagForRenderPre(
    JNIEnv* env,
    jboolean bypass) {
  if (!default_processor) {
    return;
  }
  default_processor->render_pre_processor()->SetBypassFlag(bypass);
}

static void JNI_ExternalAudioProcessingFactory_Destroy(JNIEnv* env) {
  if (!default_processor) {
    return;
  }
  default_processor->render_pre_processor()->SetExternalAudioProcessing(
      nullptr);
  default_processor->capture_post_processor()->SetExternalAudioProcessing(
      nullptr);
  default_processor = nullptr;
}

}  // namespace jni
}  // namespace webrtc
