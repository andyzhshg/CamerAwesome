import 'dart:ui';

import 'package:camerawesome/src/orchestrator/models/preview_transform_snapshot.dart';
import 'package:camerawesome/src/orchestrator/preview_transform/preview_transform_geometry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PreviewTransformGeometry', () {
    const source = Offset(0.2, 0.3);
    const expectedByTurns = <Offset>[
      Offset(0.2, 0.3),
      Offset(0.7, 0.2),
      Offset(0.8, 0.7),
      Offset(0.3, 0.8),
    ];

    for (var turns = 0; turns < 4; turns += 1) {
      test('maps normalized points for quarter turn $turns', () {
        final geometry = PreviewTransformGeometry(_snapshot(turns));

        expect(geometry.bufferToPresentation(source), expectedByTurns[turns]);
      });

      test('round trips normalized points for quarter turn $turns', () {
        final geometry = PreviewTransformGeometry(_snapshot(turns));

        final presented = geometry.bufferToPresentation(source);
        _expectOffsetClose(geometry.presentationToBuffer(presented), source);
      });
    }

    test('odd turns use swapped oriented dimensions', () {
      expect(_snapshot(1).orientedSize, const Size(1200, 1600));
      expect(_snapshot(3).orientedSize, const Size(1200, 1600));
    });

    test('front mirror metadata does not add a Dart reflection', () {
      final back = PreviewTransformGeometry(_snapshot(1));
      final front = PreviewTransformGeometry(
        _snapshot(1, isMirroring: true),
      );

      expect(front.bufferToPresentation(source),
          back.bufferToPresentation(source));
    });

    for (final outside in [
      const Offset(-0.01, 0.5),
      const Offset(1.01, 0.5),
      const Offset(0.5, -0.01),
      const Offset(0.5, 1.01),
    ]) {
      test('rejects coordinates outside the normalized domain: $outside', () {
        final geometry = PreviewTransformGeometry(_snapshot(0));

        expect(
          () => geometry.bufferToPresentation(outside),
          throwsRangeError,
        );
        expect(
          () => geometry.presentationToBuffer(outside),
          throwsRangeError,
        );
      });
    }
  });
}

void _expectOffsetClose(Offset actual, Offset expected) {
  expect(actual.dx, moreOrLessEquals(expected.dx));
  expect(actual.dy, moreOrLessEquals(expected.dy));
}

PreviewTransformReady _snapshot(
  int turns, {
  bool isMirroring = false,
}) {
  final odd = turns.isOdd;
  return PreviewTransformReady(
    sessionId: 1,
    textureId: 7,
    revision: 1,
    presentationQuarterTurns: turns,
    bufferSize: const Size(1600, 1200),
    orientedSize: odd ? const Size(1200, 1600) : const Size(1600, 1200),
    cropRect: const Rect.fromLTWH(0, 0, 1600, 1200),
    isMirroring: isMirroring,
  );
}
