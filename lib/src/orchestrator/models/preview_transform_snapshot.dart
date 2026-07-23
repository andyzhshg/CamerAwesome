import 'dart:ui' show Rect, Size;

sealed class PreviewTransformEvent {
  const PreviewTransformEvent({
    required this.sessionId,
    required this.revision,
  });

  factory PreviewTransformEvent.fromMap(Object? value) {
    if (value is! Map) {
      throw const FormatException('Preview transform event must be a map.');
    }

    final event = _requiredString(value, 'event');
    final sessionId = _requiredNonNegativeInt(value, 'sessionId');
    final revision = _requiredNonNegativeInt(value, 'revision');

    switch (event) {
      case 'ready':
        final textureId = _requiredNonNegativeInt(value, 'textureId');
        final turns = _requiredInt(value, 'presentationQuarterTurns');
        if (turns < 0 || turns > 3) {
          throw const FormatException(
            'presentationQuarterTurns must be between 0 and 3.',
          );
        }

        final bufferSize = Size(
          _requiredPositiveInt(value, 'bufferWidth').toDouble(),
          _requiredPositiveInt(value, 'bufferHeight').toDouble(),
        );
        final orientedSize = Size(
          _requiredPositiveInt(value, 'orientedWidth').toDouble(),
          _requiredPositiveInt(value, 'orientedHeight').toDouble(),
        );
        final cropRect = Rect.fromLTWH(
          _requiredNonNegativeInt(value, 'cropLeft').toDouble(),
          _requiredNonNegativeInt(value, 'cropTop').toDouble(),
          _requiredPositiveInt(value, 'cropWidth').toDouble(),
          _requiredPositiveInt(value, 'cropHeight').toDouble(),
        );
        final isMirroring = _requiredBool(value, 'isMirroring');
        final hasCameraTransform = _requiredBool(
          value,
          'hasCameraTransform',
        );

        final expectedOrientedSize = turns.isOdd
            ? Size(bufferSize.height, bufferSize.width)
            : bufferSize;
        if (orientedSize != expectedOrientedSize) {
          throw const FormatException(
            'orientedSize does not match the buffer and quarter turns.',
          );
        }
        if (cropRect.left < 0 ||
            cropRect.top < 0 ||
            cropRect.right > bufferSize.width ||
            cropRect.bottom > bufferSize.height) {
          throw const FormatException('cropRect is outside the buffer.');
        }
        final fullBufferRect = Rect.fromLTWH(
          0,
          0,
          bufferSize.width,
          bufferSize.height,
        );
        if (cropRect != fullBufferRect) {
          throw const FormatException(
            'Only a full-buffer crop is currently supported.',
          );
        }
        if (!hasCameraTransform) {
          throw const FormatException(
            'The native camera transform is unavailable.',
          );
        }

        return PreviewTransformReady(
          sessionId: sessionId,
          textureId: textureId,
          revision: revision,
          presentationQuarterTurns: turns,
          bufferSize: bufferSize,
          orientedSize: orientedSize,
          cropRect: cropRect,
          isMirroring: isMirroring,
        );
      case 'invalidated':
        return PreviewTransformInvalidated(
          sessionId: sessionId,
          revision: revision,
        );
      default:
        throw FormatException('Unknown preview transform event: $event.');
    }
  }

  final int sessionId;
  final int revision;
}

final class PreviewTransformReady extends PreviewTransformEvent {
  const PreviewTransformReady({
    required super.sessionId,
    required this.textureId,
    required super.revision,
    required this.presentationQuarterTurns,
    required this.bufferSize,
    required this.orientedSize,
    required this.cropRect,
    required this.isMirroring,
  });

  final int textureId;
  final int presentationQuarterTurns;
  final Size bufferSize;

  /// Buffer dimensions after applying [presentationQuarterTurns].
  ///
  /// This is informational transform metadata, not a second preview-layout
  /// authority. Widgets must use the preview size resolved by
  /// [AwesomeCameraPreview] after its fit pipeline has normalized sensor axes.
  final Size orientedSize;
  final Rect cropRect;

  /// Native already bakes mirroring into the texture.
  final bool isMirroring;

  @override
  bool operator ==(Object other) {
    return other is PreviewTransformReady &&
        other.sessionId == sessionId &&
        other.textureId == textureId &&
        other.revision == revision &&
        other.presentationQuarterTurns == presentationQuarterTurns &&
        other.bufferSize == bufferSize &&
        other.orientedSize == orientedSize &&
        other.cropRect == cropRect &&
        other.isMirroring == isMirroring;
  }

  @override
  int get hashCode => Object.hash(
        sessionId,
        textureId,
        revision,
        presentationQuarterTurns,
        bufferSize,
        orientedSize,
        cropRect,
        isMirroring,
      );
}

final class PreviewTransformInvalidated extends PreviewTransformEvent {
  const PreviewTransformInvalidated({
    required super.sessionId,
    required super.revision,
  });

  @override
  bool operator ==(Object other) {
    return other is PreviewTransformInvalidated &&
        other.sessionId == sessionId &&
        other.revision == revision;
  }

  @override
  int get hashCode => Object.hash(sessionId, revision);
}

int _requiredInt(Map<dynamic, dynamic> map, String key) {
  final value = map[key];
  if (value is! int) {
    throw FormatException('$key must be an integer.');
  }
  return value;
}

int _requiredNonNegativeInt(Map<dynamic, dynamic> map, String key) {
  final value = _requiredInt(map, key);
  if (value < 0) {
    throw FormatException('$key must be non-negative.');
  }
  return value;
}

int _requiredPositiveInt(Map<dynamic, dynamic> map, String key) {
  final value = _requiredInt(map, key);
  if (value <= 0) {
    throw FormatException('$key must be positive.');
  }
  return value;
}

String _requiredString(Map<dynamic, dynamic> map, String key) {
  final value = map[key];
  if (value is! String) {
    throw FormatException('$key must be a string.');
  }
  return value;
}

bool _requiredBool(Map<dynamic, dynamic> map, String key) {
  final value = map[key];
  if (value is! bool) {
    throw FormatException('$key must be a boolean.');
  }
  return value;
}
