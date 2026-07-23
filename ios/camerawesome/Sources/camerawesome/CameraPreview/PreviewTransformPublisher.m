#import "PreviewTransformPublisher.h"

@interface PreviewTransformPublisher ()
@property(nonatomic, copy, nullable) FlutterEventSink eventSink;
@property(nonatomic, strong, nullable) NSDictionary<NSString *, id> *latestEvent;
@property(nonatomic, assign) int64_t nextSessionId;
@property(nonatomic, assign) int64_t sessionId;
@property(nonatomic, assign) int64_t revision;
@property(nonatomic, assign) int64_t textureId;
@property(nonatomic, assign) size_t bufferWidth;
@property(nonatomic, assign) size_t bufferHeight;
@property(nonatomic, assign) BOOL hasActiveSession;
@property(nonatomic, assign) BOOL hasTexture;
@property(nonatomic, assign) BOOL hasBuffer;
@property(nonatomic, assign) BOOL isMirroring;
@end

@implementation PreviewTransformPublisher

- (instancetype)init {
  self = [super init];
  if (self) {
    [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
    NSNotificationCenter *notifications = [NSNotificationCenter defaultCenter];
    [notifications addObserver:self
                      selector:@selector(windowOrientationMayHaveChanged:)
                          name:UIDeviceOrientationDidChangeNotification
                        object:nil];
    [notifications addObserver:self
                      selector:@selector(windowOrientationMayHaveChanged:)
                          name:UIApplicationDidBecomeActiveNotification
                        object:nil];
    [notifications addObserver:self
                      selector:@selector(windowOrientationMayHaveChanged:)
                          name:UIWindowDidBecomeKeyNotification
                        object:nil];
  }
  return self;
}

- (void)dealloc {
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  [[UIDevice currentDevice] endGeneratingDeviceOrientationNotifications];
}

- (void)setEventSink:(FlutterEventSink)eventSink {
  NSAssert([NSThread isMainThread], @"Preview transform events must use the main thread");
  _eventSink = [eventSink copy];
  if (_latestEvent != nil && _eventSink != nil) {
    _eventSink(_latestEvent);
  }
}

- (void)startSessionWithMirroring:(BOOL)isMirroring {
  NSAssert([NSThread isMainThread], @"Preview transform sessions must use the main thread");
  [self invalidateActiveSession];
  _sessionId = ++_nextSessionId;
  _revision = 0;
  _bufferWidth = 0;
  _bufferHeight = 0;
  _hasActiveSession = YES;
  _hasBuffer = NO;
  _isMirroring = isMirroring;
  [self emitInvalidated];
}

- (void)bindTextureId:(int64_t)textureId {
  NSAssert([NSThread isMainThread], @"Preview texture binding must use the main thread");
  if (!_hasActiveSession) {
    return;
  }
  if (_hasTexture && _textureId == textureId) {
    return;
  }
  _textureId = textureId;
  _hasTexture = YES;
  [self publishReadyIfPossible];
}

- (void)clearTextureBinding {
  NSAssert([NSThread isMainThread], @"Preview texture binding must use the main thread");
  _textureId = 0;
  _hasTexture = NO;
}

- (void)updateBufferWidth:(size_t)bufferWidth height:(size_t)bufferHeight {
  NSAssert([NSThread isMainThread], @"Preview buffer updates must use the main thread");
  if (!_hasActiveSession || bufferWidth == 0 || bufferHeight == 0) {
    return;
  }
  if (_hasBuffer && _bufferWidth == bufferWidth && _bufferHeight == bufferHeight) {
    return;
  }
  _bufferWidth = bufferWidth;
  _bufferHeight = bufferHeight;
  _hasBuffer = YES;
  [self publishReadyIfPossible];
}

- (void)updateMirroring:(BOOL)isMirroring {
  NSAssert([NSThread isMainThread], @"Preview mirror updates must use the main thread");
  if (!_hasActiveSession) {
    return;
  }
  if (_isMirroring == isMirroring) {
    return;
  }
  _isMirroring = isMirroring;
  [self publishReadyIfPossible];
}

- (void)invalidateActiveSession {
  NSAssert([NSThread isMainThread], @"Preview invalidation must use the main thread");
  if (!_hasActiveSession) {
    return;
  }
  _revision += 1;
  [self emitInvalidated];
  _hasActiveSession = NO;
}

- (void)windowOrientationMayHaveChanged:(NSNotification *)notification {
  dispatch_async(dispatch_get_main_queue(), ^{
    [self publishReadyIfPossible];
  });
}

- (void)publishReadyIfPossible {
  NSAssert([NSThread isMainThread], @"Preview transform publishing must use the main thread");
  if (!_hasActiveSession || !_hasTexture || !_hasBuffer) {
    return;
  }

  UIInterfaceOrientation orientation = [self currentInterfaceOrientation];
  NSInteger quarterTurns = [self quarterTurnsForOrientation:orientation];
  if (quarterTurns < 0) {
    return;
  }

  _revision += 1;
  BOOL swapsDimensions = quarterTurns % 2 == 1;
  NSDictionary<NSString *, id> *event = @{
    @"event" : @"ready",
    @"sessionId" : @(_sessionId),
    @"textureId" : @(_textureId),
    @"revision" : @(_revision),
    @"presentationQuarterTurns" : @(quarterTurns),
    @"bufferWidth" : @(_bufferWidth),
    @"bufferHeight" : @(_bufferHeight),
    @"orientedWidth" : @(swapsDimensions ? _bufferHeight : _bufferWidth),
    @"orientedHeight" : @(swapsDimensions ? _bufferWidth : _bufferHeight),
    @"cropLeft" : @0,
    @"cropTop" : @0,
    @"cropWidth" : @(_bufferWidth),
    @"cropHeight" : @(_bufferHeight),
    @"isMirroring" : @(_isMirroring),
    @"hasCameraTransform" : @YES,
  };
  [self emit:event];
}

- (UIInterfaceOrientation)currentInterfaceOrientation {
  UIApplication *application = [UIApplication sharedApplication];
  for (UIScene *scene in application.connectedScenes) {
    if (![scene isKindOfClass:[UIWindowScene class]]) {
      continue;
    }
    UIWindowScene *windowScene = (UIWindowScene *)scene;
    for (UIWindow *window in windowScene.windows) {
      if ([self controllerContainsFlutterViewController:window.rootViewController]) {
        return windowScene.interfaceOrientation;
      }
    }
  }

  id<UIApplicationDelegate> delegate = application.delegate;
  UIWindow *fallbackWindow = nil;
  if ([delegate respondsToSelector:@selector(window)]) {
    fallbackWindow = delegate.window;
  }
  if ([self controllerContainsFlutterViewController:fallbackWindow.rootViewController]) {
    return fallbackWindow.windowScene.interfaceOrientation;
  }
  return UIInterfaceOrientationUnknown;
}

- (BOOL)controllerContainsFlutterViewController:(UIViewController *)controller {
  if (controller == nil) {
    return NO;
  }
  if ([controller isKindOfClass:[FlutterViewController class]]) {
    return YES;
  }
  if ([self controllerContainsFlutterViewController:controller.presentedViewController]) {
    return YES;
  }
  for (UIViewController *child in controller.childViewControllers) {
    if ([self controllerContainsFlutterViewController:child]) {
      return YES;
    }
  }
  return NO;
}

- (NSInteger)quarterTurnsForOrientation:(UIInterfaceOrientation)orientation {
  switch (orientation) {
    case UIInterfaceOrientationPortrait:
      return 0;
    case UIInterfaceOrientationLandscapeLeft:
      return 1;
    case UIInterfaceOrientationLandscapeRight:
      return 3;
    case UIInterfaceOrientationPortraitUpsideDown:
      return 2;
    case UIInterfaceOrientationUnknown:
      return -1;
  }
}

- (void)emitInvalidated {
  [self emit:@{
    @"event" : @"invalidated",
    @"sessionId" : @(_sessionId),
    @"revision" : @(_revision),
  }];
}

- (void)emit:(NSDictionary<NSString *, id> *)event {
  _latestEvent = event;
  if (_eventSink != nil) {
    _eventSink(event);
  }
}

@end
