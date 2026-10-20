import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// [child] drawn [scale] times its size, as VS Code's `window.zoomLevel`
/// draws a window: it is laid out in the space divided by [scale] and
/// painted, hit and placed (`localToGlobal`) scaled back up, so its text,
/// icons, gaps and fixed heights all grow together. At 1 it adds nothing.
class UiZoom extends SingleChildRenderObjectWidget {
  const UiZoom({super.key, required this.scale, super.child});

  final double scale;

  /// [media] as [child] sees it under [scale]: the window's size and insets
  /// in its own units, and as many device pixels to each of them.
  static MediaQueryData zoomed(MediaQueryData media, double scale) =>
      scale == 1
      ? media
      : media.copyWith(
          size: media.size / scale,
          devicePixelRatio: media.devicePixelRatio * scale,
          padding: media.padding / scale,
          viewPadding: media.viewPadding / scale,
          viewInsets: media.viewInsets / scale,
          systemGestureInsets: media.systemGestureInsets / scale,
        );

  @override
  RenderUiZoom createRenderObject(BuildContext context) => RenderUiZoom(scale);

  @override
  void updateRenderObject(BuildContext context, RenderUiZoom renderObject) {
    renderObject.scale = scale;
  }
}

class RenderUiZoom extends RenderProxyBox {
  RenderUiZoom(this._scale);

  double get scale => _scale;
  double _scale;
  set scale(double value) {
    if (value == _scale) return;
    _scale = value;
    markNeedsLayout();
  }

  Matrix4 get _transform => Matrix4.diagonal3Values(_scale, _scale, 1);

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final child = this.child;
    if (child == null) return constraints.smallest;
    return constraints.constrain(child.getDryLayout(constraints / _scale) * _scale);
  }

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    child.layout(constraints / _scale, parentUsesSize: true);
    size = constraints.constrain(child.size * _scale);
  }

  @override
  double computeMinIntrinsicWidth(double height) =>
      (child?.getMinIntrinsicWidth(height / _scale) ?? 0) * _scale;

  @override
  double computeMaxIntrinsicWidth(double height) =>
      (child?.getMaxIntrinsicWidth(height / _scale) ?? 0) * _scale;

  @override
  double computeMinIntrinsicHeight(double width) =>
      (child?.getMinIntrinsicHeight(width / _scale) ?? 0) * _scale;

  @override
  double computeMaxIntrinsicHeight(double width) =>
      (child?.getMaxIntrinsicHeight(width / _scale) ?? 0) * _scale;

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final child = this.child;
    if (child == null) return false;
    if (_scale == 1) return child.hitTest(result, position: position);
    return result.addWithPaintTransform(
      transform: _transform,
      position: position,
      hitTest: (result, position) => child.hitTest(result, position: position),
    );
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) {
      layer = null;
      return;
    }
    if (_scale == 1) {
      layer = null;
      context.paintChild(child, offset);
      return;
    }
    layer = context.pushTransform(
      needsCompositing,
      offset,
      _transform,
      (context, offset) => context.paintChild(child, offset),
      oldLayer: layer is TransformLayer ? layer! as TransformLayer : null,
    );
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    if (_scale != 1) transform.multiply(_transform);
  }
}
