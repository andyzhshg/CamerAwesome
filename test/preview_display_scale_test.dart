import 'package:camerawesome/pigeon.dart';
import 'package:camerawesome/src/orchestrator/analysis/analysis_to_image.dart';
import 'package:camerawesome/src/orchestrator/models/sensors.dart';
import 'package:camerawesome/src/widgets/preview/awesome_camera_preview.dart';
import 'package:camerawesome/src/widgets/preview/awesome_preview_fit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AnalysisPreview invariant under previewDisplayScale', () {
    AnalysisPreview captureFor() {
      final calculator = PreviewSizeCalculator(
        previewFit: CameraPreviewFit.contain,
        previewSize: PreviewSize(width: 960, height: 1280),
        constraints: const BoxConstraints(maxWidth: 400, maxHeight: 800),
      )..compute();
      return AnalysisPreview(
        nativePreviewSize: calculator.maxSize,
        previewSize: calculator.maxSize,
        offset: calculator.offset,
        scale: calculator.zoom,
        sensor: Sensor.position(SensorPosition.front),
      );
    }

    test('PreviewSizeCalculator output is independent of display scale', () {
      final a = captureFor();
      final b = captureFor();

      expect(a.nativePreviewSize, equals(b.nativePreviewSize));
      expect(a.previewSize, equals(b.previewSize));
      expect(a.offset, equals(b.offset));
      expect(a.scale, equals(b.scale));
    });

    testWidgets(
      'AnimatedPreviewFit emits identical AnalysisPreview for displayScale 1.0 vs 1.5',
      (tester) async {
        AnalysisPreview? emitted1;
        AnalysisPreview? emitted2;

        await tester.pumpWidget(MaterialApp(
          home: SizedBox(
            width: 400,
            height: 800,
            child: AnimatedPreviewFit(
              key: const ValueKey('scale-1.0'),
              previewFit: CameraPreviewFit.contain,
              previewSize: PreviewSize(width: 960, height: 1280),
              constraints: const BoxConstraints(maxWidth: 400, maxHeight: 800),
              sensor: Sensor.position(SensorPosition.front),
              previewDisplayScale: 1.0,
              onPreviewCalculated: (p) => emitted1 = p,
              child: const SizedBox.shrink(),
            ),
          ),
        ));
        await tester.pumpAndSettle();

        await tester.pumpWidget(MaterialApp(
          home: SizedBox(
            width: 400,
            height: 800,
            child: AnimatedPreviewFit(
              key: const ValueKey('scale-1.5'),
              previewFit: CameraPreviewFit.contain,
              previewSize: PreviewSize(width: 960, height: 1280),
              constraints: const BoxConstraints(maxWidth: 400, maxHeight: 800),
              sensor: Sensor.position(SensorPosition.front),
              previewDisplayScale: 1.5,
              onPreviewCalculated: (p) => emitted2 = p,
              child: const SizedBox.shrink(),
            ),
          ),
        ));
        await tester.pumpAndSettle();

        expect(emitted1, isNotNull);
        expect(emitted2, isNotNull);
        expect(
            emitted1!.nativePreviewSize, equals(emitted2!.nativePreviewSize));
        expect(emitted1!.previewSize, equals(emitted2!.previewSize));
        expect(emitted1!.offset, equals(emitted2!.offset));
        expect(emitted1!.scale, equals(emitted2!.scale));
      },
    );
  });

  group('preview presentation quarter turns', () {
    testWidgets('odd quarter turns swap emitted native preview dimensions', (
      tester,
    ) async {
      AnalysisPreview? emitted;

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 800,
            height: 400,
            child: AnimatedPreviewFit(
              previewFit: CameraPreviewFit.contain,
              previewSize: PreviewSize(width: 960, height: 1280),
              constraints: const BoxConstraints(
                maxWidth: 800,
                maxHeight: 400,
              ),
              sensor: Sensor.position(SensorPosition.front),
              previewPresentationQuarterTurns: 1,
              onPreviewCalculated: (preview) => emitted = preview,
              child: const ColoredBox(color: Colors.red),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(emitted, isNotNull);
      expect(emitted!.nativePreviewSize, const Size(1280, 960));
      expect(find.byType(RotatedBox), findsOneWidget);
      expect(
          tester.widget<RotatedBox>(find.byType(RotatedBox)).quarterTurns, 1);
      expect(
        find.byKey(const ValueKey('camerawesome-preview-display-scale')),
        findsOneWidget,
      );
    });

    testWidgets('quarter-turn updates recalculate geometry without extra scale',
        (
      tester,
    ) async {
      AnalysisPreview? emitted;

      Widget subject(int quarterTurns) => MaterialApp(
            home: SizedBox(
              width: 800,
              height: 400,
              child: AnimatedPreviewFit(
                previewFit: CameraPreviewFit.contain,
                previewSize: PreviewSize(width: 960, height: 1280),
                constraints:
                    const BoxConstraints(maxWidth: 800, maxHeight: 400),
                sensor: Sensor.position(SensorPosition.front),
                previewPresentationQuarterTurns: quarterTurns,
                onPreviewCalculated: (preview) => emitted = preview,
                child: const ColoredBox(color: Colors.red),
              ),
            ),
          );

      await tester.pumpWidget(subject(0));
      await tester.pumpAndSettle();
      expect(emitted!.nativePreviewSize, const Size(960, 1280));
      expect(find.byType(RotatedBox), findsNothing);

      await tester.pumpWidget(subject(3));
      await tester.pumpAndSettle();
      expect(emitted!.nativePreviewSize, const Size(1280, 960));
      expect(find.byType(RotatedBox), findsOneWidget);
      expect(
        find.byKey(const ValueKey('camerawesome-preview-display-scale')),
        findsOneWidget,
      );
    });
  });
}
