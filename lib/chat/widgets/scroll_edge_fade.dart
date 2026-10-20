import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'edge_fade_mask.dart';

/// Fades the scroll view in [child] out towards an edge that more of it is
/// scrolled past ([EdgeFadeMask]), as it scrolls and as its content or size
/// changes. Follows the scroll view right under it, not those inside that.
///
/// Which edges fade is read from the scroll view's position as it paints:
/// its notifications come a frame after it is laid out, a frame that would
/// show content grown past an edge (a section expanded) unfaded there. Its
/// content in [ScrollEdgeFadeContent]s, a change of their size repaints it
/// that frame.
class ScrollEdgeFade extends StatefulWidget {
  const ScrollEdgeFade({
    super.key,
    required this.child,
    this.fadeLength = 24,
    this.fadeOffset = 0,
    this.topCover,
    this.coverFade = 16,
    this.repaint,
    this.axis = Axis.vertical,
  });

  final Widget child;
  final double fadeLength;
  final double fadeOffset;

  /// What covers its top, as [EdgeFadeMask.topCover] (a heading stuck over
  /// the list): hidden down to there, fading in below; read at paint, as
  /// [repaint] asks.
  final ValueGetter<double?>? topCover;
  final double coverFade;
  final Listenable? repaint;

  /// The scroll view's: [Axis.horizontal] fades its left and right edges.
  final Axis axis;

  @override
  State<ScrollEdgeFade> createState() => _ScrollEdgeFadeState();
}

class _ScrollEdgeFadeState extends State<ScrollEdgeFade> {
  bool _moreBefore = false;
  bool _moreAfter = false;

  final _mask = GlobalKey();

  /// The scroll view's position, once it said it has one.
  ScrollPosition? _position;

  ({bool top, bool bottom})? _edges() {
    final position = _position;
    if (position == null ||
        !position.hasContentDimensions ||
        !position.hasPixels) {
      return null;
    }
    return (
      top: position.pixels > position.minScrollExtent + 0.5,
      bottom: position.pixels < position.maxScrollExtent - 0.5,
    );
  }

  void _contentLaidOut() =>
      _mask.currentContext?.findRenderObject()?.markNeedsPaint();

  bool _sync(ScrollMetrics metrics, BuildContext? context) {
    if (context != null && context.mounted) {
      _position = Scrollable.maybeOf(context)?.position ?? _position;
    }
    if (!metrics.hasContentDimensions) return false;
    final before = metrics.pixels > metrics.minScrollExtent + 0.5;
    final after = metrics.pixels < metrics.maxScrollExtent - 0.5;
    if (before == _moreBefore && after == _moreAfter) return false;
    void apply() {
      if (!mounted) return;
      setState(() {
        _moreBefore = before;
        _moreAfter = after;
      });
    }

    // Told while it is laid out (content shrunk under a scrolled list, which
    // settles it back in range): the next frame, as a build cannot be asked
    // for now. The mask reads the edges as it paints this one ([_edges]).
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => apply());
    } else {
      apply();
    }
    return false;
  }

  @override
  Widget build(BuildContext context) =>
      NotificationListener<ScrollMetricsNotification>(
        onNotification: (notification) =>
            notification.depth == 0 &&
            _sync(notification.metrics, notification.context),
        child: NotificationListener<ScrollNotification>(
          onNotification: (notification) =>
              notification.depth == 0 &&
              _sync(notification.metrics, notification.context),
          child: EdgeFadeMask(
            key: _mask,
            top: _moreBefore,
            bottom: _moreAfter,
            edges: _edges,
            axis: widget.axis,
            fadeLength: widget.fadeLength,
            fadeOffset: widget.fadeOffset,
            topCover: widget.topCover,
            coverFade: widget.coverFade,
            repaint: widget.repaint,
            child: _ContentScope(
              onLaidOut: _contentLaidOut,
              child: widget.child,
            ),
          ),
        ),
      );
}

class _ContentScope extends InheritedWidget {
  const _ContentScope({required this.onLaidOut, required super.child});

  final VoidCallback onLaidOut;

  @override
  bool updateShouldNotify(_ContentScope oldWidget) => false;
}

/// Content of a [ScrollEdgeFade]'s scroll view (a row of its list): grown
/// or shrunk, the fade is painted anew that frame, for the edges as they
/// are now.
class ScrollEdgeFadeContent extends SingleChildRenderObjectWidget {
  const ScrollEdgeFadeContent({super.key, required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderContent(_onLaidOut(context));

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) =>
      (renderObject as _RenderContent).onLaidOut = _onLaidOut(context);

  static VoidCallback? _onLaidOut(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_ContentScope>()?.onLaidOut;
}

class _RenderContent extends RenderProxyBox {
  _RenderContent(this.onLaidOut);

  VoidCallback? onLaidOut;

  @override
  void performLayout() {
    final before = hasSize ? size : null;
    super.performLayout();
    if (before != null && before != size) onLaidOut?.call();
  }
}
