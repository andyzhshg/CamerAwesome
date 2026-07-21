import 'package:flutter/widgets.dart';

/// Constrains the live camera texture without constraining the full-screen UI.
class AwesomePreviewViewport extends StatelessWidget {
  const AwesomePreviewViewport({
    required this.child,
    this.viewportRect,
    super.key,
  });

  final Rect? viewportRect;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final rect = viewportRect;
    return rect == null
        ? Positioned.fill(child: child)
        : Positioned.fromRect(rect: rect, child: child);
  }
}
