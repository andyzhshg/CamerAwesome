import 'dart:ui' show Offset;

import '../models/preview_transform_snapshot.dart';

class PreviewTransformGeometry {
  const PreviewTransformGeometry(this.snapshot);

  final PreviewTransformReady snapshot;

  Offset bufferToPresentation(Offset point) {
    _validateNormalized(point);
    return switch (snapshot.presentationQuarterTurns) {
      0 => point,
      1 => Offset(1 - point.dy, point.dx),
      2 => Offset(1 - point.dx, 1 - point.dy),
      3 => Offset(point.dy, 1 - point.dx),
      _ => throw StateError('Invalid preview transform snapshot.'),
    };
  }

  Offset presentationToBuffer(Offset point) {
    _validateNormalized(point);
    return switch (snapshot.presentationQuarterTurns) {
      0 => point,
      1 => Offset(point.dy, 1 - point.dx),
      2 => Offset(1 - point.dx, 1 - point.dy),
      3 => Offset(1 - point.dy, point.dx),
      _ => throw StateError('Invalid preview transform snapshot.'),
    };
  }

  void _validateNormalized(Offset point) {
    if (!point.dx.isFinite ||
        !point.dy.isFinite ||
        point.dx < 0 ||
        point.dx > 1 ||
        point.dy < 0 ||
        point.dy > 1) {
      throw RangeError('Coordinates must be inside the normalized domain.');
    }
  }
}
