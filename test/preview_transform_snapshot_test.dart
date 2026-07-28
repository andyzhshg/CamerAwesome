import 'dart:ui';

import 'package:camerawesome/src/orchestrator/models/preview_transform_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PreviewTransformEvent.fromMap', () {
    test('parses a valid ready event', () {
      final event = PreviewTransformEvent.fromMap(_readyMap());

      expect(event, isA<PreviewTransformReady>());
      final ready = event as PreviewTransformReady;
      expect(ready.sessionId, 12);
      expect(ready.textureId, 7);
      expect(ready.revision, 4);
      expect(ready.presentationQuarterTurns, 1);
      expect(ready.bufferSize, const Size(1600, 1200));
      expect(ready.orientedSize, const Size(1200, 1600));
      expect(ready.cropRect, const Rect.fromLTWH(0, 0, 1600, 1200));
      expect(ready.isMirroring, isFalse);
    });

    test('parses a valid invalidated event', () {
      final event = PreviewTransformEvent.fromMap({
        'event': 'invalidated',
        'sessionId': 13,
        'revision': 0,
      });

      expect(
        event,
        isA<PreviewTransformInvalidated>()
            .having((value) => value.sessionId, 'sessionId', 13)
            .having((value) => value.revision, 'revision', 0),
      );
    });

    test('rejects missing required fields', () {
      final map = _readyMap()..remove('textureId');

      expect(
        () => PreviewTransformEvent.fromMap(map),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects fields with the wrong type', () {
      final map = _readyMap()..['revision'] = 4.0;

      expect(
        () => PreviewTransformEvent.fromMap(map),
        throwsA(isA<FormatException>()),
      );
    });

    for (final turns in [-1, 4]) {
      test('rejects quarter turns $turns', () {
        final map = _readyMap()..['presentationQuarterTurns'] = turns;

        expect(
          () => PreviewTransformEvent.fromMap(map),
          throwsA(isA<FormatException>()),
        );
      });
    }

    test('rejects non-positive dimensions', () {
      final map = _readyMap()..['bufferWidth'] = 0;

      expect(
        () => PreviewTransformEvent.fromMap(map),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects oriented dimensions that do not match an odd turn', () {
      final map = _readyMap()
        ..['orientedWidth'] = 1600
        ..['orientedHeight'] = 1200;

      expect(
        () => PreviewTransformEvent.fromMap(map),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects oriented dimensions that do not match an even turn', () {
      final map = _readyMap()
        ..['presentationQuarterTurns'] = 2
        ..['orientedWidth'] = 1200
        ..['orientedHeight'] = 1600;

      expect(
        () => PreviewTransformEvent.fromMap(map),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects an out-of-bounds crop', () {
      final map = _readyMap()..['cropWidth'] = 1601;

      expect(
        () => PreviewTransformEvent.fromMap(map),
        throwsA(isA<FormatException>()),
      );
    });

    test('accepts a non-full crop as informational metadata', () {
      // Landscape sensor buffer cropped by the ViewPort to the capture aspect.
      final map = _readyMap()
        ..['cropLeft'] = 350
        ..['cropWidth'] = 900;

      final event = PreviewTransformEvent.fromMap(map);

      expect(event, isA<PreviewTransformReady>());
      expect(
        (event as PreviewTransformReady).cropRect,
        const Rect.fromLTWH(350, 0, 900, 1200),
      );
    });

    test('rejects a missing camera transform', () {
      final map = _readyMap()..['hasCameraTransform'] = false;

      expect(
        () => PreviewTransformEvent.fromMap(map),
        throwsA(isA<FormatException>()),
      );
    });
  });
}

Map<String, Object> _readyMap() => {
      'event': 'ready',
      'sessionId': 12,
      'textureId': 7,
      'revision': 4,
      'presentationQuarterTurns': 1,
      'bufferWidth': 1600,
      'bufferHeight': 1200,
      'orientedWidth': 1200,
      'orientedHeight': 1600,
      'cropLeft': 0,
      'cropTop': 0,
      'cropWidth': 1600,
      'cropHeight': 1200,
      'isMirroring': false,
      'hasCameraTransform': true,
    };
