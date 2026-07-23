import 'dart:async';
import 'dart:io';

import 'package:camerawesome/camerawesome_plugin.dart';
import 'package:camerawesome/pigeon.dart';
import 'package:camerawesome/src/orchestrator/preview_transform/preview_transform_tracker.dart';
import 'package:camerawesome/src/widgets/preview/awesome_preview_fit.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

enum CameraPreviewFit {
  fitWidth,
  fitHeight,
  contain,
  cover,
}

/// This is a fullscreen camera preview
/// some part of the preview are cropped so we have a full sized camera preview
class AwesomeCameraPreview extends StatefulWidget {
  final CameraPreviewFit previewFit;
  final Widget? loadingWidget;
  final CameraState state;
  final OnPreviewTap? onPreviewTap;
  final OnPreviewScale? onPreviewScale;
  final CameraLayoutBuilder interfaceBuilder;
  final CameraLayoutBuilder? previewDecoratorBuilder;
  final EdgeInsets padding;
  final Alignment alignment;
  final PictureInPictureConfigBuilder? pictureInPictureConfigBuilder;
  final double previewDisplayScale;
  @visibleForTesting
  final Stream<PreviewTransformEvent>? previewTransformStream;

  const AwesomeCameraPreview({
    super.key,
    this.loadingWidget,
    required this.state,
    this.onPreviewTap,
    this.onPreviewScale,
    this.previewFit = CameraPreviewFit.cover,
    required this.interfaceBuilder,
    this.previewDecoratorBuilder,
    required this.padding,
    required this.alignment,
    this.pictureInPictureConfigBuilder,
    this.previewDisplayScale = 1.0,
    this.previewTransformStream,
  });

  @override
  State<StatefulWidget> createState() {
    return AwesomeCameraPreviewState();
  }
}

class AwesomeCameraPreviewState extends State<AwesomeCameraPreview> {
  PreviewSize? _previewSize;

  final List<_PreviewTextureEntry> _textures = [];
  final PreviewTransformTracker _previewTransformTracker =
      PreviewTransformTracker();

  PreviewTransformReady? get _matchingTransform {
    if (_textures.isEmpty) {
      return null;
    }
    return _previewTransformTracker.readyForTexture(_textures.first.textureId);
  }

  PreviewSize? get pixelPreviewSize {
    final transform = _matchingTransform;
    final nativePreviewSize = _previewSize;
    if (transform == null || nativePreviewSize == null) {
      return null;
    }

    final portraitWidth = nativePreviewSize.width <= nativePreviewSize.height
        ? nativePreviewSize.width
        : nativePreviewSize.height;
    final portraitHeight = nativePreviewSize.width <= nativePreviewSize.height
        ? nativePreviewSize.height
        : nativePreviewSize.width;
    if (transform.presentationQuarterTurns.isOdd) {
      return PreviewSize(
        width: portraitHeight,
        height: portraitWidth,
      );
    }
    return PreviewSize(
      width: portraitWidth,
      height: portraitHeight,
    );
  }

  StreamSubscription? _sensorConfigSubscription;
  StreamSubscription? _aspectRatioSubscription;
  StreamSubscription<PreviewTransformEvent>? _previewTransformSubscription;
  CameraAspectRatios? _aspectRatio;
  double? _aspectRatioValue;
  AnalysisPreview? _preview;
  bool _previewTransformFailed = false;

  // TODO: fetch this value from the native side
  final int kMaximumSupportedFloatingPreview = 3;

  @override
  void initState() {
    super.initState();
    _previewTransformSubscription = (widget.previewTransformStream ??
            CamerawesomePlugin.previewTransformStream)
        .listen(
      (event) {
        if (!mounted) {
          return;
        }
        final previousTransform = _matchingTransform;
        _previewTransformTracker.accept(event);
        if (event is PreviewTransformReady) {
          _adoptAcceptedPrimaryTexture(event);
        }
        final nextTransform = _matchingTransform;
        final presentationChanged = !_samePresentation(
          previousTransform,
          nextTransform,
        );
        if (!_previewTransformFailed && !presentationChanged) {
          return;
        }
        setState(() {
          _previewTransformFailed = false;
          if (presentationChanged) {
            _preview = null;
          }
        });
      },
      onError: (Object _, StackTrace __) {
        if (!mounted) {
          return;
        }
        setState(() {
          _previewTransformFailed = true;
          _preview = null;
        });
      },
    );
    Future.wait([
      widget.state.previewSize(0),
      _loadTextures(),
    ]).then((data) {
      if (mounted) {
        setState(() {
          _previewSize = data[0];
        });
      }
    });

    // refactor this
    _sensorConfigSubscription =
        widget.state.sensorConfig$.listen((sensorConfig) {
      _aspectRatioSubscription?.cancel();
      _aspectRatioSubscription =
          sensorConfig.aspectRatio$.listen((event) async {
        final previewSize = await widget.state.previewSize(0);
        if ((_previewSize != previewSize || _aspectRatio != event) && mounted) {
          setState(() {
            _aspectRatio = event;
            switch (event) {
              case CameraAspectRatios.ratio_16_9:
                _aspectRatioValue = 16 / 9;
                break;
              case CameraAspectRatios.ratio_4_3:
                _aspectRatioValue = 4 / 3;
                break;
              case CameraAspectRatios.ratio_1_1:
                _aspectRatioValue = 1;
                break;
            }
            _previewSize = previewSize;
          });
        }
      });
    });
  }

  Future _loadTextures() async {
    // ignore: invalid_use_of_protected_member
    final sensors = widget.state.cameraContext.sensorConfig.sensors.length;

    // Set it to true to debug the floating preview on a device that doesn't
    // support multicam
    // ignore: dead_code
    if (false) {
      for (int i = 0; i < 2; i++) {
        final textureId = await widget.state.previewTextureId(0);
        if (textureId != null) {
          _addLoadedTexture(0, textureId);
        }
      }
    } else {
      for (int i = 0; i < sensors; i++) {
        final textureId = await widget.state.previewTextureId(i);
        if (textureId != null) {
          _addLoadedTexture(i, textureId);
        }
      }
    }
  }

  void _addLoadedTexture(int index, int textureId) {
    if (index == 0 && _textures.isNotEmpty) {
      return;
    }
    if (_textures.any((entry) => entry.textureId == textureId)) {
      return;
    }
    _textures.add(_PreviewTextureEntry(textureId));
  }

  void _adoptAcceptedPrimaryTexture(PreviewTransformReady event) {
    final accepted = _previewTransformTracker.readyForTexture(event.textureId);
    if (accepted == null ||
        accepted.sessionId != event.sessionId ||
        accepted.revision != event.revision) {
      return;
    }

    final replacement = _PreviewTextureEntry(event.textureId);
    if (_textures.isEmpty) {
      _textures.add(replacement);
    } else if (_textures.first.textureId != event.textureId) {
      _textures[0] = replacement;
    }
  }

  @override
  void dispose() {
    _sensorConfigSubscription?.cancel();
    _aspectRatioSubscription?.cancel();
    _previewTransformSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final transform = _matchingTransform;
    final effectivePreviewSize = pixelPreviewSize;
    if (_textures.isEmpty ||
        _previewSize == null ||
        _aspectRatio == null ||
        transform == null ||
        effectivePreviewSize == null ||
        _previewTransformFailed) {
      return widget.loadingWidget ??
          Center(
            child: Platform.isIOS
                ? const CupertinoActivityIndicator()
                : const CircularProgressIndicator(),
          );
    }

    return Container(
      color: Colors.black,
      child: LayoutBuilder(
        builder: (context, constraints) {
          return Stack(
            children: [
              Positioned.fill(
                child: AnimatedPreviewFit(
                  alignment: widget.alignment,
                  previewFit: widget.previewFit,
                  previewSize: effectivePreviewSize,
                  previewPadding: widget.padding,
                  constraints: constraints,
                  sensor: widget.state.sensorConfig.sensors.first,
                  previewDisplayScale: widget.previewDisplayScale,
                  presentationTransform: transform,
                  onPreviewCalculated: (preview) {
                    WidgetsBinding.instance.addPostFrameCallback((timeStamp) {
                      if (mounted) {
                        setState(() {
                          _preview = preview;
                        });
                      }
                    });
                  },
                  child: AwesomeCameraGestureDetector(
                    onPreviewTapBuilder: widget.onPreviewTap != null
                        ? OnPreviewTapBuilder(
                            pixelPreviewSizeGetter: () => effectivePreviewSize,
                            flutterPreviewSizeGetter: () =>
                                effectivePreviewSize,
                            tapPositionMapper: (position) =>
                                mapPresentationTapToBuffer(
                              point: position,
                              presentationSize: effectivePreviewSize.toSize(),
                              snapshot: transform,
                            ),
                            onPreviewTap: widget.onPreviewTap!,
                          )
                        : null,
                    onPreviewScale: widget.onPreviewScale,
                    initialZoom: widget.state.sensorConfig.zoom,
                    child: StreamBuilder<AwesomeFilter>(
                      //FIX performances
                      stream: widget.state.filter$,
                      builder: (context, snapshot) {
                        final texture = _textures.first.texture;
                        final filteredTexture = snapshot.hasData &&
                                snapshot.data != AwesomeFilter.None
                            ? ColorFiltered(
                                colorFilter: snapshot.data!.preview,
                                child: texture,
                              )
                            : texture;
                        return PreviewTransformMount(
                          snapshot: transform,
                          child: filteredTexture,
                        );
                      },
                    ),
                  ),
                ),
              ),
              if (widget.previewDecoratorBuilder != null && _preview != null)
                Positioned.fill(
                  child: widget.previewDecoratorBuilder!(
                    widget.state,
                    _preview!,
                  ),
                ),
              if (_preview != null)
                Positioned.fill(
                  child: widget.interfaceBuilder(
                    widget.state,
                    _preview!,
                  ),
                ),
              // TODO: be draggable
              // TODO: add shadow & border
              ..._buildPreviewTextures(),
            ],
          );
        },
      ),
    );
  }

  List<Widget> _buildPreviewTextures() {
    final previewFrames = <Widget>[];
    // if there is only one texture
    if (_textures.length <= 1) {
      return previewFrames;
    }
    // ignore: invalid_use_of_protected_member
    final sensors = widget.state.cameraContext.sensorConfig.sensors;

    for (int i = 1; i < _textures.length; i++) {
      // TODO: add a way to retrive how camera can be added ("budget" on iOS ?)
      if (i >= kMaximumSupportedFloatingPreview) {
        break;
      }

      final texture = _textures[i].texture;
      final sensor = sensors[kDebugMode ? 0 : i];
      final frame = AwesomeCameraFloatingPreview(
        index: i,
        sensor: sensor,
        texture: texture,
        aspectRatio: 1 / _aspectRatioValue!,
        pictureInPictureConfig:
            widget.pictureInPictureConfigBuilder?.call(i, sensor) ??
                PictureInPictureConfig(
                  startingPosition: Offset(
                    i * 20,
                    MediaQuery.of(context).padding.top + 60 + (i * 20),
                  ),
                  sensor: sensor,
                ),
      );
      previewFrames.add(frame);
    }

    return previewFrames;
  }
}

bool _samePresentation(
  PreviewTransformReady? left,
  PreviewTransformReady? right,
) {
  if (identical(left, right)) {
    return true;
  }
  if (left == null || right == null) {
    return false;
  }
  return left.sessionId == right.sessionId &&
      left.textureId == right.textureId &&
      left.presentationQuarterTurns == right.presentationQuarterTurns &&
      left.bufferSize == right.bufferSize &&
      left.orientedSize == right.orientedSize &&
      left.cropRect == right.cropRect &&
      left.isMirroring == right.isMirroring;
}

class _PreviewTextureEntry {
  _PreviewTextureEntry(this.textureId)
      : texture = Texture(textureId: textureId);

  final int textureId;
  final Texture texture;
}
