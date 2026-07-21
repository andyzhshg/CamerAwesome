#import "CamerawesomePlugin.h"
#import "Pigeon.h"
#import "Permissions.h"
#import "SensorsController.h"
#import "SingleCameraPreview.h"
#import "MultiCameraController.h"
#import "AspectRatioUtils.h"
#import "CaptureModeUtils.h"
#import "FlashModeUtils.h"
#import "AnalysisController.h"
#import <mach/mach_time.h>

FlutterEventSink orientationEventSink;
FlutterEventSink videoRecordingEventSink;
FlutterEventSink imageStreamEventSink;
FlutterEventSink physicalButtonEventSink;

static dispatch_queue_t B2NativeSpikeStateQueue;
static NSDictionary *B2NativeSpikeContext;
static NSInteger B2NativeSpikeSetupCount = 0;
static NSInteger B2NativeSpikeBindCount = 0;
static FlutterMethodChannel *B2NativeSpikeChannel;
static NSInteger B2NativeSpikePendingDeliveries = 0;
static FlutterResult B2NativeSpikePendingFinish;
static NSString *B2NativeSpikePendingFinishRunId;

static id B2NativeSpikeJSONValue(id value) {
  return value == nil ? [NSNull null] : value;
}

uint64_t B2NativeSpikeMonotonicUs(void) {
  static mach_timebase_info_data_t timebase;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    mach_timebase_info(&timebase);
  });
  __uint128_t nanos = (__uint128_t)mach_continuous_time() * timebase.numer / timebase.denom;
  return (uint64_t)(nanos / 1000);
}

NSDictionary *B2NativeSpikeContextSnapshot(void) {
  if (B2NativeSpikeStateQueue == nil) {
    return nil;
  }
  __block NSDictionary *snapshot = nil;
  dispatch_sync(B2NativeSpikeStateQueue, ^{
    snapshot = B2NativeSpikeContext;
  });
  return snapshot;
}

NSDictionary *B2NativeSpikeCountersSnapshot(BOOL incrementSetup, BOOL incrementBind) {
  if (B2NativeSpikeStateQueue == nil) {
    return @{ @"setupCount": @0, @"bindCount": @0 };
  }
  __block NSDictionary *snapshot;
  dispatch_sync(B2NativeSpikeStateQueue, ^{
    if (incrementSetup) {
      B2NativeSpikeSetupCount += 1;
    }
    if (incrementBind) {
      B2NativeSpikeBindCount += 1;
    }
    snapshot = @{
      @"setupCount": @(B2NativeSpikeSetupCount),
      @"bindCount": @(B2NativeSpikeBindCount),
    };
  });
  return snapshot;
}

void B2NativeSpikeEmit(NSDictionary *contextSnapshot, NSString *event, NSDictionary *fields) {
  if (contextSnapshot == nil) {
    return;
  }

  NSDictionary *counters = fields[@"counters"] ?: B2NativeSpikeCountersSnapshot(NO, NO);
  NSDictionary *record = @{
    @"schemaVersion": @2,
    @"runId": B2NativeSpikeJSONValue(contextSnapshot[@"runId"]),
    @"scenarioId": B2NativeSpikeJSONValue(contextSnapshot[@"scenarioId"]),
    @"contextRevision": B2NativeSpikeJSONValue(contextSnapshot[@"contextRevision"]),
    @"platform": @"ios",
    @"deviceClass": B2NativeSpikeJSONValue(contextSnapshot[@"deviceClass"]),
    @"osVersion": B2NativeSpikeJSONValue(contextSnapshot[@"osVersion"]),
    @"expectedLens": B2NativeSpikeJSONValue(contextSnapshot[@"expectedLens"]),
    @"lens": B2NativeSpikeJSONValue(fields[@"lens"]),
    @"event": B2NativeSpikeJSONValue(event),
    @"eventDetail": B2NativeSpikeJSONValue(fields[@"eventDetail"]),
    @"clockDomain": @"ios_monotonic",
    @"monotonicUs": B2NativeSpikeJSONValue(fields[@"monotonicUs"] ?: @(B2NativeSpikeMonotonicUs())),
    @"dartCameraContextId": [NSNull null],
    @"dartSessionId": [NSNull null],
    @"nativeSessionId": B2NativeSpikeJSONValue(fields[@"nativeSessionId"]),
    @"nativeApplied": B2NativeSpikeJSONValue(fields[@"nativeApplied"]),
    @"previewFit": [NSNull null],
    @"previewDisplayScale": [NSNull null],
    @"viewportLogicalPx": [NSNull null],
    @"analysisPreview": [NSNull null],
    @"analysisImage": B2NativeSpikeJSONValue(fields[@"analysisImage"]),
    @"setupCount": B2NativeSpikeJSONValue(counters[@"setupCount"]),
    @"bindCount": B2NativeSpikeJSONValue(counters[@"bindCount"]),
    @"frameGapMs": B2NativeSpikeJSONValue(fields[@"frameGapMs"]),
    @"resumeToFirstFrameMs": B2NativeSpikeJSONValue(fields[@"resumeToFirstFrameMs"]),
    @"blackFrameObserved": [NSNull null],
  };

  __block FlutterMethodChannel *channel = nil;
  __block BOOL accepted = NO;
  dispatch_sync(B2NativeSpikeStateQueue, ^{
    NSString *activeRunId = B2NativeSpikeContext[@"runId"];
    NSString *eventRunId = contextSnapshot[@"runId"];
    channel = B2NativeSpikeChannel;
    if (channel != nil && activeRunId != nil && [activeRunId isEqualToString:eventRunId]) {
      B2NativeSpikePendingDeliveries += 1;
      accepted = YES;
    }
  });
  if (!accepted) {
    return;
  }
  dispatch_async(dispatch_get_main_queue(), ^{
    [channel invokeMethod:@"nativeEvent" arguments:record result:^(__unused id reply) {
      __block FlutterResult finish = nil;
      __block NSString *finishRunId = nil;
      dispatch_sync(B2NativeSpikeStateQueue, ^{
        B2NativeSpikePendingDeliveries -= 1;
        NSCAssert(B2NativeSpikePendingDeliveries >= 0, @"native spike delivery count underflow");
        if (B2NativeSpikePendingDeliveries == 0 && B2NativeSpikePendingFinish != nil) {
          finish = B2NativeSpikePendingFinish;
          finishRunId = B2NativeSpikePendingFinishRunId;
          B2NativeSpikePendingFinish = nil;
          B2NativeSpikePendingFinishRunId = nil;
        }
      });
      if (finish != nil) {
        finish(@{ @"runId": finishRunId });
      }
    }];
  });
}

@interface CamerawesomePlugin () <CameraInterface, AnalysisImageUtils>
@property(readonly, nonatomic) NSObject<FlutterTextureRegistry> *textureRegistry;
@property NSMutableArray<NSNumber *> *texturesIds;
@property SingleCameraPreview *camera;
@property MultiCameraPreview *multiCamera;
@property(nonatomic, strong) FlutterMethodChannel *b2NativeSpikeChannel;
- (instancetype)init:(NSObject<FlutterPluginRegistrar>*)registrar;
@end

// TODO: create a protocol to uniformize multi camera & single camera
// TODO: for multi camera, specify sensor position
// TODO: save all controllers here

@implementation CamerawesomePlugin {
  dispatch_queue_t _dispatchQueue;
  dispatch_queue_t _dispatchQueueAnalysis;
}

- (instancetype)init:(NSObject<FlutterPluginRegistrar>*)registrar {
  self = [super init];
  
  _textureRegistry = registrar.textures;
  
  if (_dispatchQueue == nil) {
    _dispatchQueue = dispatch_queue_create("camerawesome.dispatchqueue", NULL);
  }
  
  if (_dispatchQueueAnalysis == nil) {
    _dispatchQueueAnalysis = dispatch_queue_create("camerawesome.dispatchqueue.analysis", NULL);
  }

  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    B2NativeSpikeStateQueue = dispatch_queue_create("camerawesome.b2_native_spike.state", DISPATCH_QUEUE_SERIAL);
  });
  
  return self;
}

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  CamerawesomePlugin *instance = [[CamerawesomePlugin alloc] init:registrar];
  FlutterEventChannel *orientationChannel = [FlutterEventChannel eventChannelWithName:@"camerawesome/orientation"
                                                                      binaryMessenger:[registrar messenger]];
  FlutterEventChannel *imageStreamChannel = [FlutterEventChannel eventChannelWithName:@"camerawesome/images"
                                                                      binaryMessenger:[registrar messenger]];
  FlutterEventChannel *physicalButtonChannel = [FlutterEventChannel eventChannelWithName:@"camerawesome/physical_button"
                                                                         binaryMessenger:[registrar messenger]];
  [orientationChannel setStreamHandler:instance];
  [imageStreamChannel setStreamHandler:instance];
  [physicalButtonChannel setStreamHandler:instance];

  instance.b2NativeSpikeChannel = [FlutterMethodChannel
    methodChannelWithName:@"daily_cam/b2_native_spike"
    binaryMessenger:[registrar messenger]];
  B2NativeSpikeChannel = instance.b2NativeSpikeChannel;
  [instance.b2NativeSpikeChannel setMethodCallHandler:^(FlutterMethodCall *call, FlutterResult result) {
    if ([call.method isEqualToString:@"finishContext"]) {
      if (![call.arguments isKindOfClass:[NSDictionary class]]) {
        result([FlutterError errorWithCode:@"invalid_finish_context"
                                   message:@"finishContext requires a map"
                                   details:nil]);
        return;
      }
      NSString *runId = ((NSDictionary *)call.arguments)[@"runId"];
      if (![runId isKindOfClass:[NSString class]] || runId.length == 0) {
        result([FlutterError errorWithCode:@"invalid_finish_context"
                                   message:@"runId must be a non-empty string"
                                   details:nil]);
        return;
      }
      __block FlutterError *finishError = nil;
      __block BOOL finishNow = NO;
      dispatch_sync(B2NativeSpikeStateQueue, ^{
        NSString *activeRunId = B2NativeSpikeContext[@"runId"];
        if (activeRunId == nil || ![activeRunId isEqualToString:runId]) {
          finishError = [FlutterError errorWithCode:@"finish_context_mismatch"
                                            message:@"finishContext runId mismatch"
                                            details:nil];
          return;
        }
        if (B2NativeSpikePendingFinish != nil) {
          finishError = [FlutterError errorWithCode:@"finish_context_pending"
                                            message:@"finishContext is already pending"
                                            details:nil];
          return;
        }
        B2NativeSpikeContext = nil;
        if (B2NativeSpikePendingDeliveries == 0) {
          finishNow = YES;
        } else {
          B2NativeSpikePendingFinish = [result copy];
          B2NativeSpikePendingFinishRunId = [runId copy];
        }
      });
      if (finishError != nil) {
        result(finishError);
      } else if (finishNow) {
        result(@{ @"runId": runId });
      }
      return;
    }
    if (![call.method isEqualToString:@"setContext"]) {
      result(FlutterMethodNotImplemented);
      return;
    }

    if (![call.arguments isKindOfClass:[NSDictionary class]]) {
      result([FlutterError errorWithCode:@"invalid_context"
                                 message:@"setContext requires a map"
                                 details:nil]);
      return;
    }

    NSDictionary *arguments = (NSDictionary *)call.arguments;
    NSArray<NSString *> *stringKeys = @[
      @"runId", @"scenarioId", @"deviceClass", @"osVersion", @"expectedLens"
    ];
    for (NSString *key in stringKeys) {
      id value = arguments[key];
      if (![value isKindOfClass:[NSString class]] || [(NSString *)value length] == 0) {
        result([FlutterError errorWithCode:@"invalid_context"
                                   message:[NSString stringWithFormat:@"%@ must be a non-empty string", key]
                                   details:nil]);
        return;
      }
    }
    id revisionValue = arguments[@"contextRevision"];
    if (![revisionValue isKindOfClass:[NSNumber class]] || [revisionValue integerValue] < 1) {
      result([FlutterError errorWithCode:@"invalid_context"
                                 message:@"contextRevision must be a positive integer"
                                 details:nil]);
      return;
    }

    NSDictionary *published = @{
      @"runId": arguments[@"runId"],
      @"scenarioId": arguments[@"scenarioId"],
      @"deviceClass": arguments[@"deviceClass"],
      @"osVersion": arguments[@"osVersion"],
      @"expectedLens": arguments[@"expectedLens"],
      @"contextRevision": @([revisionValue integerValue]),
    };
    __block FlutterError *publishError = nil;
    dispatch_sync(B2NativeSpikeStateQueue, ^{
      NSString *previousRunId = B2NativeSpikeContext[@"runId"];
      NSInteger previousRevision = [B2NativeSpikeContext[@"contextRevision"] integerValue];
      BOOL sameRun = previousRunId != nil && [previousRunId isEqualToString:published[@"runId"]];
      NSInteger nextRevision = [published[@"contextRevision"] integerValue];
      if (!sameRun && nextRevision != 1) {
        publishError = [FlutterError errorWithCode:@"invalid_context_revision"
                                           message:@"the first contextRevision in a run must be 1"
                                           details:nil];
        return;
      }
      if (sameRun && nextRevision != previousRevision + 1) {
        publishError = [FlutterError errorWithCode:@"invalid_context_revision"
                                           message:@"contextRevision must increase by exactly one within a run"
                                           details:nil];
        return;
      }
      if (!sameRun) {
        B2NativeSpikeSetupCount = 0;
        B2NativeSpikeBindCount = 0;
      }
      B2NativeSpikeContext = [published copy];
    });
    if (publishError != nil) {
      result(publishError);
      return;
    }

    result(@{ @"contextRevision": published[@"contextRevision"] });
  }];
  
  CameraInterfaceSetup(registrar.messenger, instance);
  AnalysisImageUtilsSetup(registrar.messenger, instance);
}

#pragma mark - Camera engine methods

- (void)setupCameraSensors:(nonnull NSArray<PigeonSensor *> *)sensors aspectRatio:(nonnull NSString *)aspectRatio zoom:(nonnull NSNumber *)zoom mirrorFrontCamera:(nonnull NSNumber *)mirrorFrontCamera enablePhysicalButton:(nonnull NSNumber *)enablePhysicalButton flashMode:(nonnull NSString *)flashMode captureMode:(nonnull NSString *)captureMode enableImageStream:(nonnull NSNumber *)enableImageStream exifPreferences:(nonnull ExifPreferences *)exifPreferences videoOptions:(nullable VideoOptions *)videoOptions completion:(nonnull void (^)(NSNumber * _Nullable, FlutterError * _Nullable))completion {
  
  CaptureModes captureModeType = [CaptureModeUtils captureModeFromCaptureModeType:captureMode];
  if (![CameraPermissionsController checkAndRequestPermission]) {
    completion(nil, [FlutterError errorWithCode:@"MISSING_PERMISSION" message:@"you got to accept all permissions" details:nil]);
    return;
  }
  
  if (sensors == nil || [sensors count] <= 0) {
    completion(nil, [FlutterError errorWithCode:@"SENSOR_ERROR" message:@"empty sensors provided, please provide at least 1 sensor" details:nil]);
    return;
  }
  
  // If camera preview exist, dispose it
  if (self.camera != nil) {
    [self.camera dispose];
    self.camera = nil;
  }
  if (self.multiCamera != nil) {
    [self.multiCamera dispose];
    self.multiCamera = nil;
  }
  
  _texturesIds = [NSMutableArray new];
  
  AspectRatio aspectRatioMode = [AspectRatioUtils convertAspectRatio:aspectRatio];
  
  bool multiSensors = [sensors count] > 1;
  if (multiSensors) {
    if (![MultiCameraController isMultiCamSupported]) {
      completion(nil, [FlutterError errorWithCode:@"MULTI_CAM_NOT_SUPPORTED" message:@"multi camera feature is not supported" details:nil]);
      return;
    }
    
    self.multiCamera = [[MultiCameraPreview alloc] initWithSensors:sensors
                                                 mirrorFrontCamera:[mirrorFrontCamera boolValue]
                                              enablePhysicalButton:[enablePhysicalButton boolValue]
                                                   aspectRatioMode:aspectRatioMode
                                                       captureMode:captureModeType
                                                     dispatchQueue:dispatch_queue_create("camerawesome.multi_preview.dispatchqueue", NULL)];
    
    for (int i = 0; i < [sensors count]; i++) {
      int64_t textureId = [self->_textureRegistry registerTexture:self.multiCamera.textures[i]];
      [_texturesIds addObject:[NSNumber numberWithLongLong:textureId]];
    }
    
    __weak typeof(self) weakSelf = self;
    self.multiCamera.onPreviewFrameAvailable = ^(NSNumber * _Nullable i) {
      if (i == nil) {
        return;
      }
      
      NSNumber *textureNumber = weakSelf.texturesIds[[i intValue]];
      [weakSelf.textureRegistry textureFrameAvailable:[textureNumber longLongValue]];
    };
  } else {
    PigeonSensor *firstSensor = sensors.firstObject;
    self.camera = [[SingleCameraPreview alloc] initWithCameraSensor:firstSensor.position
                                                       videoOptions:videoOptions != nil ? videoOptions.ios : nil
                                                   recordingQuality:videoOptions != nil ? videoOptions.quality : VideoRecordingQualityHighest
                                                       streamImages:[enableImageStream boolValue]
                                                  mirrorFrontCamera:[mirrorFrontCamera boolValue]
                                               enablePhysicalButton:[enablePhysicalButton boolValue]
                                                    aspectRatioMode:aspectRatioMode
                                                        captureMode:captureModeType
                                                         completion:completion
                                                      dispatchQueue:dispatch_queue_create("camerawesome.single_preview.dispatchqueue", NULL)];
    
    int64_t textureId = [self->_textureRegistry registerTexture:self.camera.previewTexture];
    
    __weak typeof(self) weakSelf = self;
    self.camera.onPreviewFrameAvailable = ^{
      [weakSelf.textureRegistry textureFrameAvailable:textureId];
    };
    
    [self->_textureRegistry textureFrameAvailable:textureId];
    
    [self.texturesIds addObject:[NSNumber numberWithLongLong:textureId]];
  }
  
  completion(@(YES), nil);
}

- (nullable NSNumber *)startWithError:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  if (self.camera == nil && self.multiCamera == nil) {
    *error = [FlutterError errorWithCode:@"CAMERA_MUST_BE_INIT" message:@"init must be call before start" details:nil];
    return @(NO);
  }
  
  dispatch_async(_dispatchQueue, ^{
    if (self.multiCamera != nil) {
      [self->_multiCamera start];
    } else {
      [self->_camera start];
    }
  });
  
  return @(YES);
}

- (nullable NSNumber *)stopWithError:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  if (self.camera == nil && self.multiCamera == nil) {
    *error = [FlutterError errorWithCode:@"CAMERA_MUST_BE_INIT" message:@"init must be call before start" details:nil];
    return @(NO);
  }
  
  for (NSNumber *textureId in self->_texturesIds) {
    [self->_textureRegistry unregisterTexture:[textureId longLongValue]];
    dispatch_async(_dispatchQueue, ^{
      if (self.multiCamera != nil) {
        [self->_multiCamera stop];
      } else {
        [self->_camera stop];
      }
    });
  }
  
  return @(YES);
}

- (void)refreshWithError:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  if (self.camera == nil && self.multiCamera == nil) {
    *error = [FlutterError errorWithCode:@"CAMERA_MUST_BE_INIT" message:@"init must be call before start" details:nil];
    return;
  }
  
  if (self.multiCamera != nil) {
    [self.multiCamera refresh];
  } else {
    [self.camera refresh];
  }
}

- (nullable NSNumber *)getPreviewTextureIdCameraPosition:(nonnull NSNumber *)cameraPosition error:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  int cameraIndex = [cameraPosition intValue];
  
  if (_texturesIds != nil && [_texturesIds count] >= cameraIndex) {
    return [_texturesIds objectAtIndex:cameraIndex];
  }
  
  return nil;
}

#pragma mark - Event sink methods

- (FlutterError *)onListenWithArguments:(NSString *)arguments eventSink:(FlutterEventSink)eventSink {
  if ([arguments  isEqual: @"orientationChannel"]) {
    orientationEventSink = eventSink;
    
    if (self.camera != nil) {
      [self.camera setOrientationEventSink:orientationEventSink];
    }
    
  } else if ([arguments  isEqual: @"imagesChannel"]) {
    imageStreamEventSink = eventSink;
    
    if (self.camera != nil) {
      [self.camera setImageStreamEvent:imageStreamEventSink];
    }
  } else if ([arguments  isEqual: @"physicalButtonChannel"]) {
    physicalButtonEventSink = eventSink;
    
    if (self.camera != nil) {
      [self.camera setPhysicalButtonEventSink:physicalButtonEventSink];
    }
  }
  
  return nil;
}

- (FlutterError *)onCancelWithArguments:(NSString *)arguments {
  if ([arguments  isEqual: @"orientationChannel"]) {
    orientationEventSink = nil;
    
    if (self.camera != nil && self.camera.motionController != nil) {
      [self.camera setOrientationEventSink:orientationEventSink];
    }
  } else if ([arguments  isEqual: @"imagesChannel"]) {
    imageStreamEventSink = nil;
    
    if (self.camera != nil) {
      [self.camera setImageStreamEvent:imageStreamEventSink];
    }
  } else if ([arguments  isEqual: @"physicalButtonChannel"]) {
    physicalButtonEventSink = nil;
    
    if (self.camera != nil) {
      [self.camera setPhysicalButtonEventSink:physicalButtonEventSink];
    }
  }
  return nil;
}

#pragma mark - Permissions methods

- (void)requestPermissionsSaveGpsLocation:(nonnull NSNumber *)saveGpsLocation completion:(nonnull void (^)(NSArray<NSString *> * _Nullable, FlutterError * _Nullable))completion {
  NSMutableArray *permissions = [NSMutableArray new];
  
  const BOOL cameraGranted = [CameraPermissionsController checkAndRequestPermission];
  if (cameraGranted) {
    [permissions addObject:@"camera"];
  }
  
  bool needToSaveGPSLocation = [saveGpsLocation boolValue];
  if (needToSaveGPSLocation) {
    // TODO: move this to permissions object
    [self.camera.locationController requestWhenInUseAuthorizationOnGranted:^{
      [permissions addObject:@"location"];
      
      completion(permissions, nil);
    } declined:^{
      completion(permissions, nil);
    }];
  }
}

- (nullable NSArray<NSString *> *)checkPermissionsPermissions:(nonnull NSArray<NSString *> *)permissions error:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  bool isMicrophonePermissionRequired = [permissions containsObject:@"microphone"];
  bool isCameraPermissionRequired = [permissions containsObject:@"camera"];
  
  bool cameraPermission = isCameraPermissionRequired ? [CameraPermissionsController checkPermission] : NO;
  bool microphonePermission = isMicrophonePermissionRequired ? [MicrophonePermissionsController checkPermission] : NO;
  
  NSMutableArray *grantedPermissions = [NSMutableArray new];
  if (cameraPermission) {
    [grantedPermissions addObject:@"camera"];
  }
  
  if (microphonePermission) {
    [grantedPermissions addObject:@"record_audio"];
  }
  
  return grantedPermissions;
}

- (nullable NSArray<NSString *> *)requestPermissionsWithError:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  return @[];
}

#pragma mark - Focus methods

- (void)focusOnPointPreviewSize:(nonnull PreviewSize *)previewSize x:(nonnull NSNumber *)x y:(nonnull NSNumber *)y androidFocusSettings:(nullable AndroidFocusSettings *)androidFocusSettings error:(FlutterError *_Nullable __autoreleasing *_Nonnull)error {
  if (previewSize.width <= 0 || previewSize.height <= 0) {
    *error = [FlutterError errorWithCode:@"INVALID_PREVIEW" message:@"preview size width and height must be set" details:nil];
    return;
  }
  
  if (self.camera == nil && self.multiCamera == nil) {
    *error = [FlutterError errorWithCode:@"CAMERA_MUST_BE_INIT" message:@"init must be call before start" details:nil];
    return;
  }
  
  if (self.multiCamera != nil) {
    [self.multiCamera focusOnPoint:CGPointMake([x floatValue], [y floatValue]) preview:CGSizeMake([previewSize.width floatValue], [previewSize.height floatValue]) error:error];
  } else {
    [self.camera focusOnPoint:CGPointMake([x floatValue], [y floatValue]) preview:CGSizeMake([previewSize.width floatValue], [previewSize.height floatValue]) error:error];
  }
}

- (void)handleAutoFocusWithError:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  // TODO: to remove ?
}

#pragma mark - Video recording methods

- (void)pauseVideoRecordingWithError:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  if (self.camera == nil && self.multiCamera == nil) {
    *error = [FlutterError errorWithCode:@"CAMERA_MUST_BE_INIT" message:@"init must be call before start" details:nil];
    return;
  }
  
  if (self.camera == nil) {
    *error = [FlutterError errorWithCode:@"MULTI_CAMERA_UNSUPPORTED" message:@"this feature is currently not supported with multi camera feature" details:nil];
    return;
  }
  
  [self.camera pauseVideoRecording];
}

- (void)recordVideoSensors:(nonnull NSArray<PigeonSensor *> *)sensors paths:(nonnull NSArray<NSString *> *)paths completion:(nonnull void (^)(FlutterError * _Nullable))completion {
  if (self.camera == nil && self.multiCamera == nil) {
    completion([FlutterError errorWithCode:@"CAMERA_MUST_BE_INIT" message:@"init must be call before start" details:nil]);
    return;
  }
  
  if (self.camera == nil) {
    completion([FlutterError errorWithCode:@"MULTI_CAMERA_UNSUPPORTED" message:@"this feature is currently not supported with multi camera feature" details:nil]);
    return;
  }
  
  if (sensors == nil || [sensors count] <= 0 || paths == nil || [paths count] <= 0) {
    completion([FlutterError errorWithCode:@"PATH_NOT_SET" message:@"at least one path must be set" details:nil]);
    return;
  }
  
  if ([sensors count] != [paths count]) {
    completion([FlutterError errorWithCode:@"PATH_INVALID" message:@"sensors & paths list seems to be different" details:nil]);
    return;
  }
  
  [self.camera recordVideoAtPath:[paths firstObject] completion:completion];
}

- (void)resumeVideoRecordingWithError:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  if (self.camera == nil && self.multiCamera == nil) {
    *error = [FlutterError errorWithCode:@"CAMERA_MUST_BE_INIT" message:@"init must be call before start" details:nil];
    return;
  }
  
  if (self.camera == nil) {
    *error = [FlutterError errorWithCode:@"MULTI_CAMERA_UNSUPPORTED" message:@"this feature is currently not supported with multi camera feature" details:nil];
    return;
  }
  
  [self.camera resumeVideoRecording];
}

- (void)setRecordingAudioModeEnableAudio:(NSNumber *)enableAudio completion:(void(^)(NSNumber *_Nullable, FlutterError *_Nullable))completion {
  if (self.camera == nil && self.multiCamera == nil) {
    completion(nil, [FlutterError errorWithCode:@"CAMERA_MUST_BE_INIT" message:@"init must be call before start" details:nil]);
    return;
  }
  
  if (self.camera == nil) {
    completion(nil, [FlutterError errorWithCode:@"MULTI_CAMERA_UNSUPPORTED" message:@"this feature is currently not supported with multi camera feature" details:nil]);
    return;
  }
  
  [self.camera setRecordingAudioMode:[enableAudio boolValue] completion:completion];
}

- (void)stopRecordingVideoWithCompletion:(nonnull void (^)(NSNumber * _Nullable, FlutterError * _Nullable))completion {
  if (self.camera == nil && self.multiCamera == nil) {
    completion(nil, [FlutterError errorWithCode:@"CAMERA_MUST_BE_INIT" message:@"init must be call before start" details:nil]);
    return;
  }
  
  if (self.camera == nil) {
    completion(nil, [FlutterError errorWithCode:@"MULTI_CAMERA_UNSUPPORTED" message:@"this feature is currently not supported with multi camera feature" details:nil]);
    return;
  }
  
  dispatch_async(_dispatchQueue, ^{
    [self->_camera stopRecordingVideo:completion];
  });
}

#pragma mark - General methods

- (void)takePhotoSensors:(nonnull NSArray<PigeonSensor *> *)sensors paths:(nonnull NSArray<NSString *> *)paths completion:(nonnull void (^)(NSNumber * _Nullable, FlutterError * _Nullable))completion {
  if (self.camera == nil && self.multiCamera == nil) {
    completion(nil, [FlutterError errorWithCode:@"CAMERA_MUST_BE_INIT" message:@"init must be call before start" details:nil]);
    return;
  }
  
  if (sensors == nil || [sensors count] <= 0 || paths == nil || [paths count] <= 0) {
    completion(0, [FlutterError errorWithCode:@"PATH_NOT_SET" message:@"at least one path must be set" details:nil]);
    return;
  }
  
  if ([sensors count] != [paths count]) {
    completion(0, [FlutterError errorWithCode:@"PATH_INVALID" message:@"sensors & paths list seems to be different" details:nil]);
    return;
  }
  
  dispatch_async(_dispatchQueue, ^{
    if (self.multiCamera != nil) {
      [self->_multiCamera takePhotoSensors:sensors paths:paths completion:completion];
    } else {
      [self->_camera takePictureAtPath:[paths firstObject] completion:completion];
    }
  });
}

- (void)setMirrorFrontCameraMirror:(nonnull NSNumber *)mirror error:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  if (self.camera == nil && self.multiCamera == nil) {
    *error = [FlutterError errorWithCode:@"CAMERA_MUST_BE_INIT" message:@"init must be call before start" details:nil];
    return;
  }
  
  BOOL mirrorFrontCamera = [mirror boolValue];
  if (self.multiCamera != nil) {
    [self.multiCamera setMirrorFrontCamera:mirrorFrontCamera error:error];
  } else {
    [self.camera setMirrorFrontCamera:mirrorFrontCamera error:error];
  }
}

- (void)setCaptureModeMode:(nonnull NSString *)mode error:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  if (self.camera == nil && self.multiCamera == nil) {
    *error = [FlutterError errorWithCode:@"CAMERA_MUST_BE_INIT" message:@"init must be call before start" details:nil];
    return;
  }
  
  CaptureModes captureMode = [CaptureModeUtils captureModeFromCaptureModeType:mode];
  if (self.multiCamera != nil) {
    if (captureMode == Video) {
      *error = [FlutterError errorWithCode:@"MULTI_CAMERA_UNSUPPORTED" message:@"impossible to set video mode when multi camera" details:nil];
      return;
    }
    
    [self.camera setCaptureMode:captureMode error:error];
  } else {
    [self.camera setCaptureMode:captureMode error:error];
  }
}

- (void)setCorrectionBrightness:(nonnull NSNumber *)brightness error:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  if (self.camera == nil && self.multiCamera == nil) {
    *error = [FlutterError errorWithCode:@"CAMERA_MUST_BE_INIT" message:@"init must be call before start" details:nil];
    return;
  }
  if (self.multiCamera != nil) {
    [self.multiCamera setBrightness:brightness error:error];
  } else {
    [self.camera setBrightness:brightness error:error];
  }
}

- (void)setExifPreferencesExifPreferences:(ExifPreferences *)exifPreferences completion:(void(^)(NSNumber *_Nullable, FlutterError *_Nullable))completion {
  if (self.camera == nil && self.multiCamera == nil) {
    completion(nil, [FlutterError errorWithCode:@"CAMERA_MUST_BE_INIT" message:@"init must be call before start" details:nil]);
    return;
  }
  
  if (self.multiCamera != nil) {
    [self.multiCamera setExifPreferencesGPSLocation: exifPreferences.saveGPSLocation completion:completion];
  } else {
    [self.camera setExifPreferencesGPSLocation: exifPreferences.saveGPSLocation completion:completion];
  }
}

- (void)setFlashModeMode:(nonnull NSString *)mode error:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  if (mode == nil || mode.length <= 0) {
    *error = [FlutterError errorWithCode:@"FLASH_MODE_ERROR" message:@"a flash mode NONE, AUTO, ALWAYS must be provided" details:nil];
    return;
  }
  
  if (self.camera == nil && self.multiCamera == nil) {
    *error = [FlutterError errorWithCode:@"CAMERA_MUST_BE_INIT" message:@"init must be call before start" details:nil];
    return;
  }
  
  CameraFlashMode flash = [FlashModeUtils flashFromString:mode];
  if (self.multiCamera != nil) {
    [self.multiCamera setFlashMode:flash error:error];
  } else {
    [self.camera setFlashMode:flash error:error];
  }
}

- (void)setPhotoSizeSize:(nonnull PreviewSize *)size error:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  if (size.width <= 0 || size.height <= 0) {
    *error = [FlutterError errorWithCode:@"NO_SIZE_SET" message:@"width and height must be set" details:nil];
    return;
  }
  
  if (self.camera == nil && self.multiCamera == nil) {
    *error = [FlutterError errorWithCode:@"CAMERA_MUST_BE_INIT" message:@"init must be call before start" details:nil];
    return;
  }
  
  if (self.camera == nil) {
    *error = [FlutterError errorWithCode:@"MULTI_CAMERA_UNSUPPORTED" message:@"this feature is currently not supported with multi camera feature" details:nil];
    return;
  }
  
  [self.camera setCameraPreset:CGSizeMake([size.width floatValue], [size.height floatValue])];
}

- (void)setAspectRatioAspectRatio:(nonnull NSString *)aspectRatio error:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  if (aspectRatio == nil || aspectRatio.length <= 0) {
    *error = [FlutterError errorWithCode:@"RATIO_NOT_SET" message:@"a ratio must be set" details:nil];
    return;
  }
  
  if (self.camera == nil && self.multiCamera == nil) {
    *error = [FlutterError errorWithCode:@"CAMERA_MUST_BE_INIT" message:@"init must be call before start" details:nil];
    return;
  }
  
  AspectRatio aspectRatioMode = [AspectRatioUtils convertAspectRatio:aspectRatio];
  if (self.multiCamera != nil) {
    [self.multiCamera setAspectRatio:aspectRatioMode];
  } else {
    [self.camera setAspectRatio:aspectRatioMode];
  }
}

#pragma mark - Preview methods

- (nullable NSArray<PreviewSize *> *)availableSizesWithError:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  if (self.camera == nil && self.multiCamera == nil) {
    *error = [FlutterError errorWithCode:@"CAMERA_MUST_BE_INIT" message:@"init must be call before start" details:nil];
    return @[];
  }
  
  if (self.multiCamera != nil) {
    return [CameraQualities captureFormatsForDevice:self.multiCamera.devices.firstObject.device];
  } else {
    return [CameraQualities captureFormatsForDevice:self.camera.captureDevice];
  }
}

- (void)setPreviewSizeSize:(nonnull PreviewSize *)size error:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  if (size.width <= 0 || size.height <= 0) {
    *error = [FlutterError errorWithCode:@"NO_SIZE_SET" message:@"width and height must be set" details:nil];
    return;
  }
  
  if (self.camera == nil && self.multiCamera == nil) {
    *error = [FlutterError errorWithCode:@"CAMERA_MUST_BE_INIT" message:@"init must be call before start" details:nil];
    return;
  }
  
  if (self.multiCamera != nil) {
    [self.multiCamera setPreviewSize:CGSizeMake([size.width floatValue], [size.height floatValue]) error:error];
  } else {
    [self.camera setPreviewSize:CGSizeMake([size.width floatValue], [size.height floatValue]) error:error];
  }
}

- (nullable PreviewSize *)getEffectivPreviewSizeIndex:(nonnull NSNumber *)index error:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  if (self.camera == nil && self.multiCamera == nil) {
    *error = [FlutterError errorWithCode:@"CAMERA_MUST_BE_INIT" message:@"init must be call before start" details:nil];
  }
  
  CGSize previewSize;
  if (self.multiCamera != nil) {
    previewSize = [self.multiCamera getEffectivPreviewSize];
  } else {
    previewSize = [self.camera getEffectivPreviewSize];
  }
  
  // height & width are inverted, this is intentionnal, because camera is always on portrait mode
  return [PreviewSize makeWithWidth:@(previewSize.height) height:@(previewSize.width)];
}

#pragma mark - Zoom methods

- (nullable NSNumber *)getMaxZoomWithError:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  if (self.camera == nil && self.multiCamera == nil) {
    *error = [FlutterError errorWithCode:@"CAMERA_MUST_BE_INIT" message:@"init must be call before start" details:nil];
  }
  
  if (self.multiCamera != nil) {
    return @([self.multiCamera getMaxZoom]);
  } else {
    return @([self.camera getMaxZoom]);
  }
}

- (nullable NSNumber *)getMinZoomWithError:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  return @(0);
}

- (void)setZoomZoom:(nonnull NSNumber *)zoom error:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  if (self.camera == nil && self.multiCamera == nil) {
    *error = [FlutterError errorWithCode:@"CAMERA_MUST_BE_INIT" message:@"init must be call before start" details:nil];
    return;
  }
  
  if (self.multiCamera != nil) {
    [self.multiCamera setZoom:[zoom floatValue] error:error];
  } else {
    [self.camera setZoom:[zoom floatValue] error:error];
  }
}

#pragma mark - Image stream methods

- (void)receivedImageFromStreamWithError:(FlutterError *_Nullable *_Nonnull)error {
  if (self.camera == nil && self.multiCamera == nil) {
    *error = [FlutterError errorWithCode:@"CAMERA_MUST_BE_INIT" message:@"init must be call before start" details:nil];
    return;
  }
  
  if (self.camera == nil) {
    *error = [FlutterError errorWithCode:@"MULTI_CAMERA_UNSUPPORTED" message:@"this feature is currently not supported with multi camera feature" details:nil];
    return;
  }
  
  [self.camera receivedImageFromStream];
}

- (void)setupImageAnalysisStreamFormat:(nonnull NSString *)format width:(nonnull NSNumber *)width maxFramesPerSecond:(nullable NSNumber *)maxFramesPerSecond autoStart:(nonnull NSNumber *)autoStart error:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  if (self.camera == nil && self.multiCamera == nil) {
    *error = [FlutterError errorWithCode:@"CAMERA_MUST_BE_INIT" message:@"init must be call before start" details:nil];
    return;
  }
  
  if (self.camera == nil) {
    *error = [FlutterError errorWithCode:@"MULTI_CAMERA_UNSUPPORTED" message:@"this feature is currently not supported with multi camera feature" details:nil];
    return;
  }
  
  [self.camera.imageStreamController setStreamImages:autoStart];
  
  // Force a frame rate to improve performance
  [self.camera.imageStreamController setMaxFramesPerSecond:[maxFramesPerSecond floatValue]];
}

- (void)startAnalysisWithError:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  if (self.camera == nil && self.multiCamera == nil) {
    *error = [FlutterError errorWithCode:@"CAMERA_MUST_BE_INIT" message:@"init must be call before start" details:nil];
    return;
  }
  
  if (self.camera == nil) {
    *error = [FlutterError errorWithCode:@"MULTI_CAMERA_UNSUPPORTED" message:@"this feature is currently not supported with multi camera feature" details:nil];
    return;
  }
  
  [self.camera.imageStreamController setStreamImages:true];
}

- (void)stopAnalysisWithError:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  if (self.camera == nil && self.multiCamera == nil) {
    *error = [FlutterError errorWithCode:@"CAMERA_MUST_BE_INIT" message:@"init must be call before start" details:nil];
    return;
  }
  
  if (self.camera == nil) {
    *error = [FlutterError errorWithCode:@"MULTI_CAMERA_UNSUPPORTED" message:@"this feature is currently not supported with multi camera feature" details:nil];
    return;
  }
  
  [self.camera.imageStreamController setStreamImages:false];
}

- (void)isVideoRecordingAndImageAnalysisSupportedSensor:(PigeonSensorPosition)sensor completion:(void (^)(NSNumber *_Nullable, FlutterError *_Nullable))completion {
  completion(@(YES), nil);
}

#pragma mark - Sensors methods

- (nullable NSArray<PigeonSensorTypeDevice *> *)getFrontSensorsWithError:(FlutterError *_Nullable *_Nonnull)error {
  return [SensorsController getSensors:AVCaptureDevicePositionFront];
}

- (nullable NSArray<PigeonSensorTypeDevice *> *)getBackSensorsWithError:(FlutterError *_Nullable *_Nonnull)error {
  return [SensorsController getSensors:AVCaptureDevicePositionBack];
}

- (void)setSensorSensors:(nonnull NSArray<PigeonSensor *> *)sensors error:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  if (self.camera == nil && self.multiCamera == nil) {
    *error = [FlutterError errorWithCode:@"CAMERA_MUST_BE_INIT" message:@"init must be call before start" details:nil];
    return;
  }
  
  if (sensors != nil && [sensors count] > 1 && self.multiCamera != nil) {
    if ([self.multiCamera.sensors count] != [sensors count]) {
      *error = [FlutterError errorWithCode:@"SENSORS_COUNT_INVALID" message:@"sensors count seems to be different, you can only update current sensors, adding or deleting is impossible for now" details:nil];
      return;
    }
    
    [self.multiCamera setSensors:sensors];
  } else {
    [self.camera setSensor:sensors.firstObject];
  }
}

#pragma mark - Filter methods

- (void)setFilterMatrix:(NSArray<NSNumber *> *)matrix error:(FlutterError *_Nullable *_Nonnull)error {
  // TODO: try to use CIFilter when taking a picture
}

#pragma mark - Multi camera methods

- (nullable NSNumber *)isMultiCamSupportedWithError:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  return [NSNumber numberWithBool: [MultiCameraController isMultiCamSupported]];
}

- (void)bgra8888toJpegBgra8888image:(nonnull AnalysisImageWrapper *)bgra8888image jpegQuality:(nonnull NSNumber *)jpegQuality completion:(nonnull void (^)(AnalysisImageWrapper * _Nullable, FlutterError * _Nullable))completion {
  dispatch_async(_dispatchQueueAnalysis, ^{
    [AnalysisController bgra8888toJpegBgra8888image:bgra8888image jpegQuality:jpegQuality completion:completion];
  });
}

- (void)nv21toJpegNv21Image:(nonnull AnalysisImageWrapper *)nv21Image jpegQuality:(nonnull NSNumber *)jpegQuality completion:(nonnull void (^)(AnalysisImageWrapper * _Nullable, FlutterError * _Nullable))completion {
  [AnalysisController nv21toJpegNv21Image:nv21Image jpegQuality:jpegQuality completion:completion];
}

- (void)yuv420toJpegYuvImage:(nonnull AnalysisImageWrapper *)yuvImage jpegQuality:(nonnull NSNumber *)jpegQuality completion:(nonnull void (^)(AnalysisImageWrapper * _Nullable, FlutterError * _Nullable))completion {
  [AnalysisController yuv420toJpegYuvImage:yuvImage jpegQuality:jpegQuality completion:completion];
}

- (void)yuv420toNv21YuvImage:(nonnull AnalysisImageWrapper *)yuvImage completion:(nonnull void (^)(AnalysisImageWrapper * _Nullable, FlutterError * _Nullable))completion {
  [AnalysisController yuv420toNv21YuvImage:yuvImage completion:completion];
}

@end
