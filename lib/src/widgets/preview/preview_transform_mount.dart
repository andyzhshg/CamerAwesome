import 'package:camerawesome/src/orchestrator/models/preview_transform_snapshot.dart';
import 'package:camerawesome/src/orchestrator/preview_transform/preview_transform_geometry.dart';
import 'package:flutter/widgets.dart';

class PreviewTransformMount extends StatelessWidget {
  const PreviewTransformMount({
    super.key,
    required this.snapshot,
    required this.child,
  });

  final PreviewTransformReady snapshot;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return RotatedBox(
      quarterTurns: snapshot.presentationQuarterTurns,
      child: child,
    );
  }
}

Offset mapPresentationTapToBuffer({
  required Offset point,
  required Size presentationSize,
  required PreviewTransformReady snapshot,
}) {
  if (snapshot.presentationQuarterTurns == 0) {
    return point;
  }
  if (presentationSize.width <= 0 || presentationSize.height <= 0) {
    throw ArgumentError.value(
      presentationSize,
      'presentationSize',
      'must be positive',
    );
  }

  final normalizedPresentation = Offset(
    point.dx / presentationSize.width,
    point.dy / presentationSize.height,
  );
  final normalizedBuffer =
      PreviewTransformGeometry(snapshot).presentationToBuffer(
    normalizedPresentation,
  );
  return Offset(
    normalizedBuffer.dx * presentationSize.width,
    normalizedBuffer.dy * presentationSize.height,
  );
}
