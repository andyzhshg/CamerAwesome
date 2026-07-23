import 'dart:async';

import 'package:camerawesome/camerawesome_plugin.dart';
import 'package:camerawesome/pigeon.dart';
import 'package:camerawesome/src/orchestrator/camera_context.dart';
import 'package:camerawesome/src/widgets/preview/awesome_preview_fit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late StreamController<PreviewTransformEvent> transforms;
  late _FakePreviewCameraState cameraState;

  setUp(() {
    transforms = StreamController<PreviewTransformEvent>.broadcast();
    cameraState = _FakePreviewCameraState();
  });

  tearDown(() async {
    await transforms.close();
    cameraState.disposeForTest();
  });

  testWidgets('keeps a new texture hidden until matching ready arrives',
      (tester) async {
    await _pumpPreview(tester, cameraState, transforms.stream);

    expect(find.byKey(const Key('loading')), findsOneWidget);
    expect(find.byType(Texture), findsNothing);

    transforms.add(_ready(sessionId: 1, textureId: 7, revision: 1));
    final pumps = await tester.pumpAndSettle();

    expect(find.byKey(const Key('loading')), findsNothing);
    expect(find.byType(Texture), findsOneWidget);
    expect(find.byType(RotatedBox), findsOneWidget);
    expect(pumps, lessThan(10));
  });

  testWidgets('old session cannot reveal a reused texture after invalidation',
      (tester) async {
    await _pumpPreview(tester, cameraState, transforms.stream);
    transforms.add(_ready(sessionId: 1, textureId: 7, revision: 1));
    await _pumpPreviewFrames(tester);
    expect(find.byType(Texture), findsOneWidget);

    transforms.add(
      const PreviewTransformInvalidated(sessionId: 2, revision: 0),
    );
    await _pumpPreviewFrames(tester);
    expect(find.byKey(const Key('loading')), findsOneWidget);

    transforms.add(_ready(sessionId: 1, textureId: 7, revision: 99));
    await _pumpPreviewFrames(tester);
    expect(find.byKey(const Key('loading')), findsOneWidget);

    transforms.add(_ready(sessionId: 2, textureId: 7, revision: 1));
    await _pumpPreviewFrames(tester);
    expect(find.byType(Texture), findsOneWidget);
  });

  testWidgets('camera switch mounts the accepted session texture', (
    tester,
  ) async {
    await _pumpPreview(tester, cameraState, transforms.stream);
    transforms.add(_ready(sessionId: 1, textureId: 7, revision: 1));
    await _pumpPreviewFrames(tester);
    expect(tester.widget<Texture>(find.byType(Texture)).textureId, 7);

    transforms.add(
      const PreviewTransformInvalidated(sessionId: 2, revision: 0),
    );
    await _pumpPreviewFrames(tester);
    expect(find.byKey(const Key('loading')), findsOneWidget);

    transforms.add(_ready(sessionId: 2, textureId: 9, revision: 1));
    await _pumpPreviewFrames(tester);

    expect(find.byKey(const Key('loading')), findsNothing);
    expect(tester.widget<Texture>(find.byType(Texture)).textureId, 9);
  });

  testWidgets('same-session revision atomically updates turns and dimensions',
      (tester) async {
    await _pumpPreview(tester, cameraState, transforms.stream);
    transforms.add(_ready(sessionId: 1, textureId: 7, revision: 1));
    await _pumpPreviewFrames(tester);

    var fit = tester.widget<AnimatedPreviewFit>(
      find.byType(AnimatedPreviewFit),
    );
    expect(fit.previewSize.width, 1200);
    expect(fit.previewSize.height, 1600);
    expect(
      tester.widget<RotatedBox>(find.byType(RotatedBox)).quarterTurns,
      0,
    );

    transforms.add(
      _ready(
        sessionId: 1,
        textureId: 7,
        revision: 2,
        turns: 1,
      ),
    );
    await _pumpPreviewFrames(tester);

    fit = tester.widget<AnimatedPreviewFit>(find.byType(AnimatedPreviewFit));
    expect(fit.previewSize.width, 1600);
    expect(fit.previewSize.height, 1200);
    expect(
      tester.widget<RotatedBox>(find.byType(RotatedBox)).quarterTurns,
      1,
    );
    expect(find.byType(Texture), findsOneWidget);
  });

  testWidgets(
      'initial landscape native size still resolves the landscape stage once',
      (tester) async {
    cameraState = _FakePreviewCameraState(
      previewSize: PreviewSize(width: 1600, height: 1200),
    );
    await _pumpPreview(tester, cameraState, transforms.stream);
    transforms.add(
      _ready(
        sessionId: 1,
        textureId: 7,
        revision: 1,
        turns: 1,
      ),
    );
    await _pumpPreviewFrames(tester);

    final fit = tester.widget<AnimatedPreviewFit>(
      find.byType(AnimatedPreviewFit),
    );
    expect(fit.previewSize.width, 1600);
    expect(fit.previewSize.height, 1200);
    expect(
      tester.widget<RotatedBox>(find.byType(RotatedBox)).quarterTurns,
      1,
    );
  });

  testWidgets(
      'same-session duplicate presentation does not rebuild camera controls',
      (tester) async {
    var controlBuilds = 0;
    await _pumpPreview(
      tester,
      cameraState,
      transforms.stream,
      interfaceBuilder: (_, __) {
        controlBuilds += 1;
        return const SizedBox(key: Key('camera-controls'));
      },
    );
    transforms.add(_ready(sessionId: 1, textureId: 7, revision: 1));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('camera-controls')), findsOneWidget);
    final buildsAfterReady = controlBuilds;

    transforms.add(_ready(sessionId: 1, textureId: 7, revision: 2));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('camera-controls')), findsOneWidget);
    expect(controlBuilds, buildsAfterReady);
  });

  testWidgets('stream errors fail closed behind the readiness gate',
      (tester) async {
    await _pumpPreview(tester, cameraState, transforms.stream);

    transforms.addError(const FormatException('unsupported native event'));
    await _pumpPreviewFrames(tester);

    expect(find.byKey(const Key('loading')), findsOneWidget);
    expect(find.byType(Texture), findsNothing);
  });
}

Future<void> _pumpPreview(
  WidgetTester tester,
  _FakePreviewCameraState cameraState,
  Stream<PreviewTransformEvent> transforms, {
  CameraLayoutBuilder? interfaceBuilder,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: SizedBox(
        width: 300,
        height: 400,
        child: AwesomeCameraPreview(
          state: cameraState,
          previewTransformStream: transforms,
          loadingWidget: const SizedBox(key: Key('loading')),
          interfaceBuilder:
              interfaceBuilder ?? (_, __) => const SizedBox.shrink(),
          previewDecoratorBuilder: null,
          padding: EdgeInsets.zero,
          alignment: Alignment.center,
        ),
      ),
    ),
  );
  await _pumpPreviewFrames(tester);
}

Future<void> _pumpPreviewFrames(WidgetTester tester) async {
  for (var frame = 0; frame < 4; frame++) {
    await tester.pump();
  }
}

PreviewTransformReady _ready({
  required int sessionId,
  required int textureId,
  required int revision,
  int turns = 0,
}) {
  const bufferSize = Size(1600, 1200);
  return PreviewTransformReady(
    sessionId: sessionId,
    textureId: textureId,
    revision: revision,
    presentationQuarterTurns: turns,
    bufferSize: bufferSize,
    orientedSize: turns.isOdd ? const Size(1200, 1600) : bufferSize,
    cropRect: const Rect.fromLTWH(0, 0, 1600, 1200),
    isMirroring: false,
  );
}

class _FakePreviewCameraState extends PreviewCameraState {
  _FakePreviewCameraState({
    PreviewSize? previewSize,
  })  : _previewSize = previewSize ?? PreviewSize(width: 1200, height: 1600),
        super(
          cameraContext: CameraContext.create(
            SensorConfig.single(),
            initialCaptureMode: CaptureMode.preview,
            saveConfig: null,
            exifPreferences: ExifPreferences(saveGPSLocation: false),
            filter: AwesomeFilter.None,
            enablePhysicalButton: false,
          ),
        );

  final PreviewSize _previewSize;

  @override
  Future<PreviewSize> previewSize(int index) async => _previewSize;

  @override
  Future<int?> previewTextureId(int cameraPosition) async => 7;

  void disposeForTest() {
    cameraContext.dispose();
  }
}
