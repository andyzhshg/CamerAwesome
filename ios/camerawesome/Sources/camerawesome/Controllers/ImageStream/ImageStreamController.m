//
//  ImageStreamController.m
//  camerawesome
//
//  Created by Dimitri Dessus on 17/12/2020.
//

#import "ImageStreamController.h"
#import <stdint.h>

static const size_t BgraBytesPerPixel = 4;

static NSInteger UprightRotationDegreesForDeviceOrientation(UIDeviceOrientation orientation) {
  switch (orientation) {
    case UIDeviceOrientationLandscapeLeft:
      return 90;
    case UIDeviceOrientationLandscapeRight:
      return 270;
    case UIDeviceOrientationPortraitUpsideDown:
      return 180;
    case UIDeviceOrientationPortrait:
    default:
      return 0;
  }
}

static NSString *DeviceOrientationName(UIDeviceOrientation orientation) {
  switch (orientation) {
    case UIDeviceOrientationLandscapeLeft:
      return @"landscape_left";
    case UIDeviceOrientationLandscapeRight:
      return @"landscape_right";
    case UIDeviceOrientationPortraitUpsideDown:
      return @"portrait_down";
    case UIDeviceOrientationPortrait:
    default:
      return @"portrait_up";
  }
}

static NSData *CopyUprightBGRA8888Bytes(
  const void *source,
  size_t sourceWidth,
  size_t sourceHeight,
  size_t sourceBytesPerRow,
  NSInteger rotationDegrees,
  size_t *outputWidth,
  size_t *outputHeight,
  size_t *outputBytesPerRow
) {
  size_t dstW = sourceWidth;
  size_t dstH = sourceHeight;
  if (rotationDegrees == 90 || rotationDegrees == 270) {
    dstW = sourceHeight;
    dstH = sourceWidth;
  }
  size_t dstBytesPerRow = dstW * BgraBytesPerPixel;
  NSMutableData *dstData = [NSMutableData dataWithLength:dstBytesPerRow * dstH];
  uint8_t *dst = [dstData mutableBytes];
  const uint8_t *src = (const uint8_t *)source;
  for (size_t y = 0; y < sourceHeight; y++) {
    for (size_t x = 0; x < sourceWidth; x++) {
      const uint8_t *srcPixel = src + y * sourceBytesPerRow + x * BgraBytesPerPixel;
      size_t dstX;
      size_t dstY;
      switch (rotationDegrees) {
        case 90:
          dstX = sourceHeight - 1 - y;
          dstY = x;
          break;
        case 180:
          dstX = sourceWidth - 1 - x;
          dstY = sourceHeight - 1 - y;
          break;
        case 270:
          dstX = y;
          dstY = sourceWidth - 1 - x;
          break;
        default:
          dstX = x;
          dstY = y;
          break;
      }
      uint8_t *dstPixel = dst + dstY * dstBytesPerRow + dstX * BgraBytesPerPixel;
      dstPixel[0] = srcPixel[0];
      dstPixel[1] = srcPixel[1];
      dstPixel[2] = srcPixel[2];
      dstPixel[3] = srcPixel[3];
    }
  }
  *outputWidth = dstW;
  *outputHeight = dstH;
  *outputBytesPerRow = dstBytesPerRow;
  return dstData;
}

@implementation ImageStreamController

NSInteger const MaxPendingProcessedImage = 4;

- (instancetype)initWithStreamImages:(bool)streamImages {
  self = [super init];
  _streamImages = streamImages;
  _processingImage = 0;
  return self;
}

# pragma mark - Camera Delegates
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection orientation:(UIDeviceOrientation)orientation {
  if (_imageStreamEventSink == nil) {
    return;
  }
  
  bool shouldFPSGuard = [self fpsGuard];
  bool shouldOverflowCrashingGuard = [self overflowCrashingGuard];
  
  if (shouldFPSGuard || shouldOverflowCrashingGuard) {
    return;
  }
  
  _processingImage++;
  
  CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
  CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
  
  size_t imageWidth = CVPixelBufferGetWidth(pixelBuffer);
  size_t imageHeight = CVPixelBufferGetHeight(pixelBuffer);
  
  NSMutableArray *planes = [NSMutableArray array];

  // mlkit input is rotated to upright per device orientation (preview is left raw).
  NSInteger uprightDegrees = UprightRotationDegreesForDeviceOrientation(orientation);
  if (uprightDegrees != 0) {
    void *baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer);
    size_t outW;
    size_t outH;
    size_t outBPR;
    NSData *rotated = CopyUprightBGRA8888Bytes(
      baseAddress,
      CVPixelBufferGetWidth(pixelBuffer),
      CVPixelBufferGetHeight(pixelBuffer),
      CVPixelBufferGetBytesPerRow(pixelBuffer),
      uprightDegrees,
      &outW,
      &outH,
      &outBPR);
    [planes addObject:@{
      @"bytesPerRow": @(outBPR),
      @"width": @(outW),
      @"height": @(outH),
      @"bytes": [FlutterStandardTypedData typedDataWithBytes:rotated],
    }];
    imageWidth = outW;
    imageHeight = outH;
  } else {
    const Boolean isPlanar = CVPixelBufferIsPlanar(pixelBuffer);
    size_t planeCount;
    if (isPlanar) {
      planeCount = CVPixelBufferGetPlaneCount(pixelBuffer);
    } else {
      planeCount = 1;
    }
    for (int i = 0; i < planeCount; i++) {
      void *planeAddress;
      size_t bytesPerRow;
      size_t height;
      size_t width;
      if (isPlanar) {
        planeAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, i);
        bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, i);
        height = CVPixelBufferGetHeightOfPlane(pixelBuffer, i);
        width = CVPixelBufferGetWidthOfPlane(pixelBuffer, i);
      } else {
        planeAddress = CVPixelBufferGetBaseAddress(pixelBuffer);
        bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);
        height = CVPixelBufferGetHeight(pixelBuffer);
        width = CVPixelBufferGetWidth(pixelBuffer);
      }
      NSNumber *length = @(bytesPerRow * height);
      NSData *bytes = [NSData dataWithBytes:planeAddress length:length.unsignedIntegerValue];
      [planes addObject:@{
        @"bytesPerRow": @(bytesPerRow),
        @"width": @(width),
        @"height": @(height),
        @"bytes": [FlutterStandardTypedData typedDataWithBytes:bytes],
      }];
    }
  }

  CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);

  NSDictionary *imageBuffer = @{
    @"width": [NSNumber numberWithUnsignedLong:imageWidth],
    @"height": [NSNumber numberWithUnsignedLong:imageHeight],
    @"format": @"bgra8888",
    @"planes": planes,
    @"rotation": @"rotation0deg",
    @"deviceOrientation": DeviceOrientationName(orientation),
  };
  
  dispatch_async(dispatch_get_main_queue(), ^{
    self->_imageStreamEventSink(imageBuffer);
  });
  
}

- (NSString *)getInputImageOrientation:(UIDeviceOrientation)orientation {
  switch (orientation) {
    case UIDeviceOrientationLandscapeLeft:
      return @"rotation90deg";
    case UIDeviceOrientationLandscapeRight:
      return @"rotation270deg";
    case UIDeviceOrientationPortrait:
      return @"rotation0deg";
    case UIDeviceOrientationPortraitUpsideDown:
      return @"rotation180deg";
    default:
      return @"rotation0deg";
  }
}

#pragma mark - Guards

- (bool)fpsGuard {
  // calculate time interval between latest emitted frame
  NSDate *nowDate = [NSDate date];
  NSTimeInterval secondsBetween = [nowDate timeIntervalSinceDate:_latestEmittedFrame];
  
  // fps limit check, ignored if nil or == 0
  if (_maxFramesPerSecond && _maxFramesPerSecond > 0) {
    if (secondsBetween <= (1 / _maxFramesPerSecond)) {
      // skip image because out of time
      return YES;
    }
  }
  
  return NO;
}

- (bool)overflowCrashingGuard {
  // overflow crash prevent condition
  if (_processingImage > MaxPendingProcessedImage) {
    // too many frame are pending processing, skipping...
    // this prevent crashing on older phones like iPhone 6, 7...
    return YES;
  }
  
  return NO;
}

// This is used to know the exact time when the image was received on the Flutter part
- (void)receivedImageFromStream {
  // used for the fps limit condition
  _latestEmittedFrame = [NSDate date];
  
  // used for the overflow prevent crashing condition
  if (_processingImage >= 0) {
    _processingImage--;
  }
}

#pragma mark - Setters

- (void)setImageStreamEventSink:(FlutterEventSink)imageStreamEventSink {
  _imageStreamEventSink = imageStreamEventSink;
}

- (void)setMaxFramesPerSecond:(float)maxFramesPerSecond {
  _maxFramesPerSecond = maxFramesPerSecond;
}

- (void)setStreamImages:(bool)streamImages {
  _streamImages = streamImages;
}

@end
