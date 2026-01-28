/*
 *  Copyright 2026 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#include "sdk/objc/native/src/objc_nv12_conversion.h"

#include <atomic>

namespace webrtc {
namespace {
std::atomic<ObjCFrameBufferPolicy> g_frame_buffer_policy{
    ObjCFrameBufferPolicy::kNone};
}  // namespace

ObjCFrameBufferPolicy ObjCGetFrameBufferPolicy() {
  return g_frame_buffer_policy.load(std::memory_order_relaxed);
}

void SetObjCFrameBufferPolicy(ObjCFrameBufferPolicy policy) {
  g_frame_buffer_policy.store(policy, std::memory_order_relaxed);
}

}  // namespace webrtc
