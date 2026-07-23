import 'dart:ui';

import 'package:camerawesome/src/orchestrator/models/preview_transform_snapshot.dart';
import 'package:camerawesome/src/orchestrator/preview_transform/preview_transform_tracker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PreviewTransformTracker', () {
    test('accepts the first ready event', () {
      final tracker = PreviewTransformTracker()..accept(_ready());

      expect(tracker.readyForTexture(7), _ready());
    });

    test('accepts a newer revision in the same session', () {
      final tracker = PreviewTransformTracker()
        ..accept(_ready())
        ..accept(_ready(revision: 2, turns: 1));

      expect(
        tracker.readyForTexture(7),
        _ready(revision: 2, turns: 1),
      );
    });

    test('ignores a duplicate revision', () {
      final first = _ready();
      final tracker = PreviewTransformTracker()
        ..accept(first)
        ..accept(_ready(turns: 2));

      expect(tracker.readyForTexture(7), same(first));
    });

    test('ignores a lower revision', () {
      final latest = _ready(revision: 3, turns: 2);
      final tracker = PreviewTransformTracker()
        ..accept(latest)
        ..accept(_ready(revision: 2, turns: 1));

      expect(tracker.readyForTexture(7), same(latest));
    });

    test('accepts a new session with a reused texture id', () {
      final replacement = _ready(sessionId: 2, revision: 0, turns: 3);
      final tracker = PreviewTransformTracker()
        ..accept(_ready())
        ..accept(replacement);

      expect(tracker.readyForTexture(7), same(replacement));
    });

    test('ignores an old-session event after a new session', () {
      final replacement = _ready(sessionId: 2, revision: 0, turns: 3);
      final tracker = PreviewTransformTracker()
        ..accept(_ready())
        ..accept(replacement)
        ..accept(_ready(sessionId: 1, revision: 99, turns: 2));

      expect(tracker.readyForTexture(7), same(replacement));
    });

    test('an invalidated event clears readiness', () {
      final tracker = PreviewTransformTracker()
        ..accept(_ready())
        ..accept(
          const PreviewTransformInvalidated(sessionId: 1, revision: 2),
        );

      expect(tracker.readyForTexture(7), isNull);
    });

    test('does not return readiness for a different texture', () {
      final tracker = PreviewTransformTracker()..accept(_ready());

      expect(tracker.readyForTexture(8), isNull);
    });
  });
}

PreviewTransformReady _ready({
  int sessionId = 1,
  int revision = 1,
  int turns = 0,
}) {
  final odd = turns.isOdd;
  return PreviewTransformReady(
    sessionId: sessionId,
    textureId: 7,
    revision: revision,
    presentationQuarterTurns: turns,
    bufferSize: const Size(1600, 1200),
    orientedSize: odd ? const Size(1200, 1600) : const Size(1600, 1200),
    cropRect: const Rect.fromLTWH(0, 0, 1600, 1200),
    isMirroring: false,
  );
}
