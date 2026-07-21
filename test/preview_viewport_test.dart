import 'package:camerawesome/src/widgets/preview/awesome_preview_viewport.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('viewport constrains only its preview child', (tester) async {
    const rect = Rect.fromLTWH(30, 40, 240, 180);

    await tester.pumpWidget(
      const MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 400,
            height: 300,
            child: Stack(
              children: [
                AwesomePreviewViewport(
                  viewportRect: rect,
                  child: ColoredBox(
                    key: ValueKey('previewTexture'),
                    color: Colors.red,
                  ),
                ),
                Positioned.fill(
                  child: ColoredBox(
                    key: ValueKey('fullScreenInterface'),
                    color: Colors.transparent,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    expect(tester.getRect(find.byKey(const ValueKey('previewTexture'))), rect);
    expect(
      tester.getRect(find.byKey(const ValueKey('fullScreenInterface'))),
      const Rect.fromLTWH(0, 0, 400, 300),
    );
  });

  testWidgets('null viewport preserves the full-screen preview contract', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 400,
            height: 300,
            child: Stack(
              children: [
                AwesomePreviewViewport(
                  child: ColoredBox(
                    key: ValueKey('previewTexture'),
                    color: Colors.red,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    expect(
      tester.getRect(find.byKey(const ValueKey('previewTexture'))),
      const Rect.fromLTWH(0, 0, 400, 300),
    );
  });
}
