import 'package:camerawesome/src/orchestrator/models/preview_transform_snapshot.dart';
import 'package:camerawesome/src/widgets/preview/preview_transform_mount.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PreviewTransformMount', () {
    for (var turns = 0; turns < 4; turns++) {
      testWidgets('applies quarter turn $turns exactly once', (tester) async {
        final snapshot = _ready(turns: turns);

        await tester.pumpWidget(
          MaterialApp(
            home: PreviewTransformMount(
              snapshot: snapshot,
              child: const ColoredBox(color: Colors.red),
            ),
          ),
        );

        final rotatedBoxes = tester.widgetList<RotatedBox>(
          find.byType(RotatedBox),
        );
        expect(rotatedBoxes, hasLength(1));
        expect(rotatedBoxes.single.quarterTurns, turns);
      });
    }

    testWidgets('does not apply a Dart mirror transform', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: PreviewTransformMount(
            snapshot: _ready(isMirroring: true),
            child: const ColoredBox(color: Colors.red),
          ),
        ),
      );

      expect(find.byType(Transform), findsNothing);
      expect(find.byType(RotatedBox), findsOneWidget);
    });
  });

  group('mapPresentationTapToBuffer', () {
    test('turn zero preserves the exact Offset instance', () {
      const point = Offset(123.5, 456.25);

      final mapped = mapPresentationTapToBuffer(
        point: point,
        presentationSize: const Size(1600, 1200),
        snapshot: _ready(),
      );

      expect(identical(mapped, point), isTrue);
    });

    test('inverse maps an odd quarter turn', () {
      final mapped = mapPresentationTapToBuffer(
        point: const Offset(300, 320),
        presentationSize: const Size(1200, 1600),
        snapshot: _ready(turns: 1),
      );

      expect(mapped, const Offset(240, 1200));
    });
  });
}

PreviewTransformReady _ready({
  int turns = 0,
  bool isMirroring = false,
}) {
  const bufferSize = Size(1600, 1200);
  return PreviewTransformReady(
    sessionId: 1,
    textureId: 7,
    revision: 1,
    presentationQuarterTurns: turns,
    bufferSize: bufferSize,
    orientedSize: turns.isOdd ? const Size(1200, 1600) : bufferSize,
    cropRect: const Rect.fromLTWH(0, 0, 1600, 1200),
    isMirroring: isMirroring,
  );
}
