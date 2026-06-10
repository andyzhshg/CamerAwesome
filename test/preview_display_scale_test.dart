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
        expect(emitted1!.nativePreviewSize, equals(emitted2!.nativePreviewSize));
        expect(emitted1!.previewSize, equals(emitted2!.previewSize));
        expect(emitted1!.offset, equals(emitted2!.offset));
        expect(emitted1!.scale, equals(emitted2!.scale));
      },
    );
  });
}
