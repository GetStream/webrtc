/*
 *  Copyright 2026 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#import "RTCPictureInPictureVideoRenderer.h"

#if TARGET_OS_IPHONE && (!defined(TARGET_OS_VISION) || !TARGET_OS_VISION)

#import "RTCVideoFrameConverter.h"
#import "base/RTCLogging.h"
#import "base/RTCVideoFrame.h"

@interface RTC_OBJC_TYPE(RTCPictureInPictureVideoRenderer) ()

// Shared converter instance reused across frames.
// This enables internal pool reuse in converter and keeps per-frame overhead low.
@property(nonatomic, strong) RTC_OBJC_TYPE(RTCVideoFrameConverter) *frameConverter;
// Serial queue ensures frame conversion is ordered and non-concurrent.
// This protects converter internal state and avoids frame reordering.
@property(nonatomic, strong) dispatch_queue_t renderQueue;
// Last size reported by WebRTC through `setSize:`.
@property(nonatomic, assign) CGSize videoSize;
// Cached renderer bounds size, updated in `layoutSubviews`.
@property(nonatomic, assign) CGSize rendererSize;

@end

@implementation RTC_OBJC_TYPE(RTCPictureInPictureVideoRenderer)

@synthesize delegate = _delegate;

+ (Class)layerClass {
  // PiP display path is sample-buffer based, so use AVSampleBufferDisplayLayer.
  return AVSampleBufferDisplayLayer.class;
}

- (instancetype)initWithFrame:(CGRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    [self configure];
  }
  return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
  self = [super initWithCoder:coder];
  if (self) {
    [self configure];
  }
  return self;
}

- (void)configure {
  // Default behavior mirrors WebRTC renderers:
  // - renderer active by default
  // - aspect-fill display
  // - resize frames to current view bounds for PiP stability
  _enabled = YES;
  _resizesFramesToRendererSize = YES;
  _frameConverter = [[RTC_OBJC_TYPE(RTCVideoFrameConverter) alloc] init];
  _renderQueue =
      dispatch_queue_create("org.webrtc.pip-video-renderer",
                            DISPATCH_QUEUE_SERIAL);
  _rendererSize = self.bounds.size;
  
  self.videoGravity = AVLayerVideoGravityResizeAspectFill;
}

- (AVSampleBufferDisplayLayer *)sampleBufferDisplayLayer {
  return (AVSampleBufferDisplayLayer *)self.layer;
}

- (AVLayerVideoGravity)videoGravity {
  return self.sampleBufferDisplayLayer.videoGravity;
}

- (void)setVideoGravity:(AVLayerVideoGravity)videoGravity {
  self.sampleBufferDisplayLayer.videoGravity = videoGravity;
}

- (void)setEnabled:(BOOL)enabled {
  _enabled = enabled;
  if (!enabled) {
    // Flush when disabling so stale frames are removed immediately.
    [self.sampleBufferDisplayLayer flush];
  }
}

#pragma mark - RTCVideoRenderer

- (void)setSize:(CGSize)size {
  __weak RTC_OBJC_TYPE(RTCPictureInPictureVideoRenderer) *weakSelf = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    RTC_OBJC_TYPE(RTCPictureInPictureVideoRenderer) *strongSelf = weakSelf;

    // Called by WebRTC when stream dimensions change.
    strongSelf.videoSize = size;
    
    [strongSelf setNeedsLayout];
    
    // Delegate callbacks are delivered on main, matching existing renderers.
    [strongSelf.delegate videoView:strongSelf didChangeVideoSize:size];
  });
}

- (void)renderFrame:(nullable RTC_OBJC_TYPE(RTCVideoFrame) *)frame {
  // Fast guard for common no-op cases.
  if (!self.isEnabled) {
    return;
  }

  if (frame == nil) {
    RTCLogInfo(@"Incoming frame is nil. Exiting render callback.");
    return;
  }

  // Capture target size on caller thread so background work does not touch
  // UIKit properties directly.
  CGSize targetSize = [self targetSizeForFrame:frame];
  __weak RTC_OBJC_TYPE(RTCPictureInPictureVideoRenderer) *weakSelf = self;
  // Conversion work can be expensive; run it off WebRTC callback thread.
  dispatch_async(self.renderQueue, ^{
    RTC_OBJC_TYPE(RTCPictureInPictureVideoRenderer) *strongSelf = weakSelf;
    if (!strongSelf || !strongSelf.isEnabled) {
      return;
    }

    // Build sample buffer from frame in backend/policy agnostic way.
    CMSampleBufferRef sampleBuffer =
        [strongSelf.frameConverter copySampleBufferFromFrame:frame
                                                  targetSize:targetSize];
    if (!sampleBuffer) {
      return;
    }

    // Interact with AVSampleBufferDisplayLayer on main.
    dispatch_async(dispatch_get_main_queue(), ^{
      __strong __typeof(weakSelf) innerSelf = weakSelf;
      if (!innerSelf || !innerSelf.isEnabled) {
        CFRelease(sampleBuffer);
        return;
      }

      AVSampleBufferDisplayLayer *displayLayer = innerSelf.sampleBufferDisplayLayer;
      // Some decoder states require flush before enqueueing new data.
      if (@available(iOS 14.0, *)) {
        if (displayLayer.requiresFlushToResumeDecoding) {
          [displayLayer flush];
        }
      }

      // Recover from failed rendering state by flushing layer queue.
      if (displayLayer.status == AVQueuedSampleBufferRenderingStatusFailed) {
        [displayLayer flush];
      }

      // Respect backpressure; drop frame if layer is saturated.
      if (displayLayer.isReadyForMoreMediaData) {
        [displayLayer enqueueSampleBuffer:sampleBuffer];
      }

      // Balance retained CoreFoundation ownership from converter.
      CFRelease(sampleBuffer);
    });
  });
}

#pragma mark - Cross platform

#if TARGET_OS_IPHONE
- (void)layoutSubviews {
  [super layoutSubviews];
  [self performLayout];
}
#elif TARGET_OS_OSX
- (void)layout {
  [super layout];
  [self performLayout];
}

- (void)setNeedsLayout {
  self.needsLayout = YES;
}
#endif

#pragma mark - Private

- (void)performLayout {
  // Capture bounds changes so target sizing can happen off main thread
  // without reading UIKit state from background queues.
  self.rendererSize = self.bounds.size;
}

- (CGSize)targetSizeForFrame:(RTC_OBJC_TYPE(RTCVideoFrame) *)frame {
  // Preferred path for PiP:
  // scale to current renderer bounds when enabled.
  if (self.resizesFramesToRendererSize &&
      self.rendererSize.width > 0 &&
      self.rendererSize.height > 0) {
    return self.rendererSize;
  }
  // Secondary path:
  // use the latest size reported by WebRTC's `setSize`.
  if (self.videoSize.width > 0 && self.videoSize.height > 0) {
    return self.videoSize;
  }
  // Final fallback:
  // use frame's raw dimensions.
  return CGSizeMake(frame.width, frame.height);
}

@end

#endif
