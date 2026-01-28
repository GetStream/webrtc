/*
 *  Copyright 2026 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#import "RTCVideoRenderingView.h"

#import "RTCMTLVideoView.h"
#if TARGET_OS_IPHONE && defined(RTC_STREAM_RENDERING_BACKEND)
#import "RTCSharedMetalVideoView.h"
#endif

#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#endif

#if TARGET_OS_IPHONE
typedef UIView<RTC_OBJC_TYPE(RTCVideoRenderer)> RTCVideoRenderingBackendView;
#elif TARGET_OS_OSX
typedef NSView<RTC_OBJC_TYPE(RTCVideoRenderer)> RTCVideoRenderingBackendView;
#endif

@protocol RTCVideoRenderingBackendConfigurable <NSObject>
@property(nonatomic, weak) id<RTC_OBJC_TYPE(RTCVideoViewDelegate)> delegate;
@property(nonatomic, getter=isEnabled) BOOL enabled;
@property(nonatomic, nullable) NSValue *rotationOverride;
@property(nonatomic, assign) NSInteger maxInFlightFrames;
#if TARGET_OS_IPHONE
@property(nonatomic) UIViewContentMode videoContentMode;
#endif
@end

@interface RTC_OBJC_TYPE(RTCVideoRenderingView) ()

@property(nonatomic, strong) RTCVideoRenderingBackendView *activeView;

@end

@implementation RTC_OBJC_TYPE(RTCVideoRenderingView)

- (instancetype)initWithFrame:(CGRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    _renderingBackend = RTC_OBJC_TYPE(RTCVideoRenderingBackendDefault);
    _enabled = YES;
    _maxInFlightFrames = 0;
#if TARGET_OS_IPHONE
    _videoContentMode = UIViewContentModeScaleAspectFill;
#endif
    [self rebuildActiveView];
  }
  return self;
}

- (void)layoutSubviews {
  [super layoutSubviews];
  self.activeView.frame = self.bounds;
}

- (void)setRenderingBackend:(RTC_OBJC_TYPE(RTCVideoRenderingBackend))renderingBackend {
  if (_renderingBackend == renderingBackend) {
    return;
  }
  _renderingBackend = renderingBackend;
  [self rebuildActiveView];
}

- (void)setEnabled:(BOOL)enabled {
  _enabled = enabled;
  if ([self.activeView respondsToSelector:@selector(setEnabled:)]) {
    id<RTCVideoRenderingBackendConfigurable> configurable = (id)self.activeView;
    configurable.enabled = enabled;
  }
}

#if TARGET_OS_IPHONE
- (void)setVideoContentMode:(UIViewContentMode)videoContentMode {
  _videoContentMode = videoContentMode;
  if ([self.activeView respondsToSelector:@selector(setVideoContentMode:)]) {
    id<RTCVideoRenderingBackendConfigurable> configurable = (id)self.activeView;
    configurable.videoContentMode = videoContentMode;
  }
}
#endif

- (void)setRotationOverride:(NSValue *)rotationOverride {
  _rotationOverride = rotationOverride;
  if ([self.activeView respondsToSelector:@selector(setRotationOverride:)]) {
    id<RTCVideoRenderingBackendConfigurable> configurable = (id)self.activeView;
    configurable.rotationOverride = rotationOverride;
  }
}

- (void)setMaxInFlightFrames:(NSInteger)maxInFlightFrames {
  // Only shared-metal uses this; other backends ignore it.
  _maxInFlightFrames = MAX(0, maxInFlightFrames);
  if ([self.activeView respondsToSelector:@selector(setMaxInFlightFrames:)]) {
    id<RTCVideoRenderingBackendConfigurable> configurable = (id)self.activeView;
    configurable.maxInFlightFrames = _maxInFlightFrames;
  }
}

- (void)setDelegate:(id<RTC_OBJC_TYPE(RTCVideoViewDelegate)>)delegate {
  _delegate = delegate;
  if ([self.activeView respondsToSelector:@selector(setDelegate:)]) {
    id<RTCVideoRenderingBackendConfigurable> configurable = (id)self.activeView;
    configurable.delegate = delegate;
  }
}

#pragma mark - RTCVideoRenderer

- (void)setSize:(CGSize)size {
  [self.activeView setSize:size];
}

- (void)renderFrame:(RTC_OBJC_TYPE(RTCVideoFrame) *)frame {
  [self.activeView renderFrame:frame];
}

#pragma mark - Private

- (void)rebuildActiveView {
  [self.activeView removeFromSuperview];
  self.activeView = [self createViewForBackend:_renderingBackend];
  self.activeView.frame = self.bounds;
  [self addSubview:self.activeView];

  if ([self.activeView respondsToSelector:@selector(setEnabled:)]) {
    id<RTCVideoRenderingBackendConfigurable> configurable = (id)self.activeView;
    configurable.enabled = _enabled;
  }
  if ([self.activeView respondsToSelector:@selector(setRotationOverride:)]) {
    id<RTCVideoRenderingBackendConfigurable> configurable = (id)self.activeView;
    configurable.rotationOverride = _rotationOverride;
  }
  if ([self.activeView respondsToSelector:@selector(setDelegate:)]) {
    id<RTCVideoRenderingBackendConfigurable> configurable = (id)self.activeView;
    configurable.delegate = _delegate;
  }
  if ([self.activeView respondsToSelector:@selector(setMaxInFlightFrames:)]) {
    id<RTCVideoRenderingBackendConfigurable> configurable = (id)self.activeView;
    configurable.maxInFlightFrames = _maxInFlightFrames;
  }
#if TARGET_OS_IPHONE
  if ([self.activeView respondsToSelector:@selector(setVideoContentMode:)]) {
    id<RTCVideoRenderingBackendConfigurable> configurable = (id)self.activeView;
    configurable.videoContentMode = _videoContentMode;
  }
#endif
}

- (RTCVideoRenderingBackendView *)createViewForBackend:
    (RTC_OBJC_TYPE(RTCVideoRenderingBackend))backend {
  // Shared metal is iOS-only and gated by RTC_STREAM_RENDERING_BACKEND. If it's
  // not available we fall back to RTCMTLVideoView.
  switch (backend) {
    case RTC_OBJC_TYPE(RTCVideoRenderingBackendSharedMetal):
#if TARGET_OS_IPHONE
#if defined(RTC_STREAM_RENDERING_BACKEND)
      {
        RTC_OBJC_TYPE(RTCSharedMetalVideoView) *view =
            [[RTC_OBJC_TYPE(RTCSharedMetalVideoView) alloc]
                initWithFrame:self.bounds];
        if (view) {
          return view;
        }
      }
#endif
#endif
      return [[RTC_OBJC_TYPE(RTCMTLVideoView) alloc] initWithFrame:self.bounds];
    case RTC_OBJC_TYPE(RTCVideoRenderingBackendDefault):
    default:
      return [[RTC_OBJC_TYPE(RTCMTLVideoView) alloc] initWithFrame:self.bounds];
  }
}

@end
