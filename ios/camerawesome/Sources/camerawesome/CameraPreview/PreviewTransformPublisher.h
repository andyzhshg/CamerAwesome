#import <Flutter/Flutter.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface PreviewTransformPublisher : NSObject

- (void)setEventSink:(nullable FlutterEventSink)eventSink;
- (void)startSessionWithMirroring:(BOOL)isMirroring;
- (void)bindTextureId:(int64_t)textureId;
- (void)clearTextureBinding;
- (void)updateBufferWidth:(size_t)bufferWidth height:(size_t)bufferHeight;
- (void)updateMirroring:(BOOL)isMirroring;
- (void)invalidateActiveSession;

@end

NS_ASSUME_NONNULL_END
