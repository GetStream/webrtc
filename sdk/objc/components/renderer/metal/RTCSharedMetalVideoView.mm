/*
 *  Copyright 2026 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#import "RTCSharedMetalVideoView.h"

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <os/lock.h>

#import "RTCSharedMetalRenderAdapter.h"
#import "RTCSharedMetalRenderingContext.h"
#import "RTCSharedMetalRenderingContext+Private.h"
#import "base/RTCLogging.h"

@implementation RTC_OBJC_TYPE(RTCSharedMetalVideoView) {
  RTC_OBJC_TYPE(RTCSharedMetalRenderingContext) *_context;
  RTC_OBJC_TYPE(RTCSharedMetalRenderAdapter) *_adapter;
  os_unfair_lock _stateLock;
  BOOL _renderActive;
}

+ (Class)layerClass {
  return [CAMetalLayer class];
}

- (instancetype)initWithFrame:(CGRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    _context = [RTC_OBJC_TYPE(RTCSharedMetalRenderingContext) sharedContext];
    if (!_context) {
      RTCLogError(@"SharedMetal: Failed to create rendering context");
      return nil;
    }
    _adapter = [[RTC_OBJC_TYPE(RTCSharedMetalRenderAdapter) alloc]
        initWithContext:_context];
    if (!_adapter) {
      RTCLogError(@"SharedMetal: Failed to create render adapter");
      return nil;
    }

    _enabled = YES;
    _renderActive = YES;
    _videoContentMode = UIViewContentModeScaleAspectFill;
    _maxInFlightFrames = 0;
    _stateLock = OS_UNFAIR_LOCK_INIT;

    [self configureLayer];
    [_adapter setContentMode:_videoContentMode];
    [_adapter setMaxInFlightFrames:_maxInFlightFrames];
    // Registers the view with the shared display-link renderer.
    [_context registerView:self];
  }
  return self;
}

- (void)dealloc {
  [_context unregisterView:self];
}

- (void)layoutSubviews {
  [super layoutSubviews];
  [self updateDrawableSizeWithSize:self.bounds.size];
}

- (void)setEnabled:(BOOL)enabled {
  _enabled = enabled;
  os_unfair_lock_lock(&_stateLock);
  _renderActive = enabled;
  os_unfair_lock_unlock(&_stateLock);
}

- (void)setVideoContentMode:(UIViewContentMode)videoContentMode {
  _videoContentMode = videoContentMode;
  [_adapter setContentMode:videoContentMode];
}

- (void)setMaxInFlightFrames:(NSInteger)maxInFlightFrames {
  _maxInFlightFrames = MAX(0, maxInFlightFrames);
  [_adapter setMaxInFlightFrames:_maxInFlightFrames];
}

#pragma mark - RTC_OBJC_TYPE(RTCVideoRenderer)

- (void)setSize:(CGSize)size {
  __weak RTC_OBJC_TYPE(RTCSharedMetalVideoView) *weakSelf = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    RTC_OBJC_TYPE(RTCSharedMetalVideoView) *strongSelf = weakSelf;
    if (!strongSelf) {
      return;
    }
    // Keep drawable size tied to view bounds; setSize conveys frame size only.
    [strongSelf updateDrawableSizeWithSize:strongSelf.bounds.size];
    [strongSelf.delegate videoView:strongSelf didChangeVideoSize:size];
  });
}

- (void)renderFrame:(nullable RTC_OBJC_TYPE(RTCVideoFrame) *)frame {
  if (!self.isEnabled) {
    return;
  }
  [_adapter renderFrame:frame];
}

#pragma mark - Rendering

- (void)drawIfNeeded {
  os_unfair_lock_lock(&_stateLock);
  BOOL isActive = _renderActive;
  os_unfair_lock_unlock(&_stateLock);
  if (!isActive) {
    return;
  }
  if (![_adapter consumeNeedsRedraw]) {
    return;
  }
  if (![_adapter beginFrameIfPossible]) {
    return;
  }
  id<CAMetalDrawable> drawable = [self metalLayer].nextDrawable;
  if (!drawable) {
    [_adapter endFrame];
    return;
  }
  RTC_OBJC_TYPE(RTCVideoFrame) *frame = [_adapter consumeFrame];
  if (!frame) {
    [_adapter endFrame];
    return;
  }
  id<MTLCommandBuffer> commandBuffer =
      [_context.commandQueue commandBuffer];
  if (!commandBuffer) {
    [_adapter endFrame];
    return;
  }

  BOOL encoded = [_adapter encodeFrame:frame
                              drawable:drawable
                               context:_context
                         commandBuffer:commandBuffer
                      rotationOverride:self.rotationOverride];
  if (!encoded) {
    [_adapter endFrame];
    return;
  }

  [commandBuffer presentDrawable:drawable];

  RTC_OBJC_TYPE(RTCSharedMetalRenderAdapter) *adapter = _adapter;
  [commandBuffer addCompletedHandler:^(__unused id<MTLCommandBuffer> buffer) {
    [adapter endFrame];
  }];

  [commandBuffer commit];
}

#pragma mark - Private

- (CAMetalLayer *)metalLayer {
  return (CAMetalLayer *)self.layer;
}

- (void)configureLayer {
  CAMetalLayer *layer = [self metalLayer];
  layer.device = _context.device;
  layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
  layer.framebufferOnly = YES;
  layer.opaque = YES;
  layer.contentsScale = UIScreen.mainScreen.scale;
  [self updateDrawableSizeWithSize:self.bounds.size];
}

- (void)updateDrawableSizeWithSize:(CGSize)size {
  CAMetalLayer *layer = [self metalLayer];
  CGFloat scale = self.window ? self.window.screen.scale : UIScreen.mainScreen.scale;
  layer.frame = self.bounds;
  layer.drawableSize = CGSizeMake(size.width * scale, size.height * scale);
}

@end
