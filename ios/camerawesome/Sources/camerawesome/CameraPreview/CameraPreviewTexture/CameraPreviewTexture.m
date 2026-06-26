//
//  CameraPreviewTexture.m
//  camerawesome
//
//  Created by Dimitri Dessus on 28/03/2023.
//

#import "CameraPreviewTexture.h"
#import <CoreImage/CoreImage.h>

@interface CameraPreviewTexture ()
@property(nonatomic, strong) CIContext *ciContext;
@end

@implementation CameraPreviewTexture

- (instancetype)init {
  if (self = [super init]) {
    _previewRotationDegrees = 0;
  }
  return self;
}

- (void)updateBuffer:(CMSampleBufferRef)sampleBuffer {
  CVPixelBufferRef srcBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
  CVPixelBufferRef newBuffer;
  if (self.previewRotationDegrees == 0) {
    newBuffer = srcBuffer;
    CFRetain(newBuffer);
  } else {
    newBuffer = [self rotateBuffer:srcBuffer degrees:self.previewRotationDegrees];
  }
  CVPixelBufferRef old = atomic_load(&_latestPixelBuffer);
  while (!atomic_compare_exchange_strong(&_latestPixelBuffer, &old, newBuffer)) {
    old = atomic_load(&_latestPixelBuffer);
  }
  if (old != nil) {
    CFRelease(old);
  }
}

- (CVPixelBufferRef)rotateBuffer:(CVPixelBufferRef)src degrees:(NSInteger)degrees {
  CIImage *image = [CIImage imageWithCVImageBuffer:src];
  NSInteger norm = ((degrees % 360) + 360) % 360;
  // CGImagePropertyOrientation: 1=up, 6=right(90 CW), 3=down(180), 8=left(270 CW)
  NSInteger ciOrient;
  switch (norm) {
    case 90:  ciOrient = 6; break;
    case 180: ciOrient = 3; break;
    case 270: ciOrient = 8; break;
    default:  ciOrient = 1; break;
  }
  CIImage *rotated = [image imageByApplyingOrientation:(CGImagePropertyOrientation)ciOrient];
  size_t dstW = CVPixelBufferGetWidth(src);
  size_t dstH = CVPixelBufferGetHeight(src);
  if (norm == 90 || norm == 270) {
    size_t tmp = dstW; dstW = dstH; dstH = tmp;
  }
  NSDictionary *attrs = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}};
  CVPixelBufferRef dst;
  CVPixelBufferCreate(kCFAllocatorDefault, dstW, dstH,
                      CVPixelBufferGetPixelFormatType(src),
                      (__bridge CFDictionaryRef)attrs, &dst);
  if (_ciContext == nil) {
    _ciContext = [CIContext contextWithOptions:nil];
  }
  [_ciContext render:rotated toCVPixelBuffer:dst];
  return dst;
}

/// Used to copy pixels to in-memory buffer
- (CVPixelBufferRef _Nullable)copyPixelBuffer {
  CVPixelBufferRef pixelBuffer = atomic_load(&_latestPixelBuffer);
  while (!atomic_compare_exchange_strong(&_latestPixelBuffer, &pixelBuffer, nil)) {
    pixelBuffer = atomic_load(&_latestPixelBuffer);
  }

  return pixelBuffer;
}

- (void)dealloc {
  if (self.latestPixelBuffer) {
    CFRelease(self.latestPixelBuffer);
  }
}

@end
