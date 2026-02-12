/*
 *  Copyright 2026 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#import "RTCPeerConnectionFactory.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, RTC_OBJC_TYPE(RTCFrameBufferPolicy)) {
  RTC_OBJC_TYPE(RTCFrameBufferPolicyNone) = 0,
  RTC_OBJC_TYPE(RTCFrameBufferPolicyWrapOnlyExistingNV12),
  RTC_OBJC_TYPE(RTCFrameBufferPolicyCopyToNV12),
  RTC_OBJC_TYPE(RTCFrameBufferPolicyConvertWithPoolToNV12)
};

@interface RTC_OBJC_TYPE(RTCPeerConnectionFactory) (StreamRenderingBackend)

/**
 * Controls how decoded frame buffers are bridged to Objective-C. Default is `none`.
 * This can be toggled at runtime.
 *
 * Note: the policy is evaluated per frame. Changing it mid-call can result in
 * a mix of I420 and NV12 buffers for in-flight frames. For consistent format,
 * set it before starting a call.
 *
 * Thread-safety: property access is not synchronized; set it from a single
 * thread if you need strict consistency.
 */
@property(nonatomic, assign) RTC_OBJC_TYPE(RTCFrameBufferPolicy) frameBufferPolicy;

@end

NS_ASSUME_NONNULL_END
