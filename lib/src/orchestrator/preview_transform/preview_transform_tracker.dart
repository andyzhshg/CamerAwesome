import 'package:camerawesome/src/orchestrator/models/preview_transform_snapshot.dart';

class PreviewTransformTracker {
  int? _sessionId;
  int? _revision;
  PreviewTransformReady? _ready;

  void accept(PreviewTransformEvent event) {
    final currentSessionId = _sessionId;
    if (currentSessionId != null && event.sessionId < currentSessionId) {
      return;
    }

    if (currentSessionId == event.sessionId) {
      final currentRevision = _revision;
      if (currentRevision != null && event.revision <= currentRevision) {
        return;
      }
    }

    _sessionId = event.sessionId;
    _revision = event.revision;
    _ready = switch (event) {
      PreviewTransformReady() => event,
      PreviewTransformInvalidated() => null,
    };
  }

  PreviewTransformReady? readyForTexture(int textureId) {
    final ready = _ready;
    return ready?.textureId == textureId ? ready : null;
  }
}
