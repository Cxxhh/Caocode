import 'dart:async';

import 'package:bao_editor/monaco/flutter/wheel_glide.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// A [ScrollController] for lists a mouse wheel scrolls smoothly
/// ([WheelGliding]); a trackpad's scrolling is as it comes.
class SmoothScrollController extends ScrollController {
  SmoothScrollController({
    super.initialScrollOffset,
    super.keepScrollOffset,
    super.debugLabel,
    super.onAttach,
    super.onDetach,
  });

  /// Where the list is going, as [offset] is where it is: where a wheel's
  /// notches are taking it, while they glide it ([WheelGliding.headedTo]).
  double get headedTo => switch (position) {
    final WheelGliding gliding => gliding.headedTo,
    final other => other.pixels,
  };

  @override
  void attach(ScrollPosition position) {
    _WheelSignal.watch();
    super.attach(position);
  }

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) => _SmoothScrollPosition(
    physics: physics,
    context: context,
    initialPixels: initialScrollOffset,
    keepScrollOffset: keepScrollOffset,
    oldPosition: oldPosition,
    debugLabel: debugLabel,
  );
}

/// A [SmoothScrollController] of its own for the scroll view [builder]
/// builds: for a widget with no state to keep one in.
class SmoothScrolling extends StatefulWidget {
  const SmoothScrolling({super.key, required this.builder});

  final Widget Function(BuildContext context, ScrollController controller)
  builder;

  @override
  State<SmoothScrolling> createState() => _SmoothScrollingState();
}

class _SmoothScrollingState extends State<SmoothScrolling> {
  final _controller = SmoothScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _controller);
}

class _SmoothScrollPosition extends ScrollPositionWithSingleContext
    with WheelGliding {
  _SmoothScrollPosition({
    required super.physics,
    required super.context,
    super.initialPixels,
    super.keepScrollOffset,
    super.oldPosition,
    super.debugLabel,
  });
}

/// The device of the wheel's (or trackpad's) scroll signal being handled:
/// seen as it comes, after every view under the pointer has (they ask to
/// take it), before the one that takes it does; forgotten after.
abstract final class _WheelSignal {
  static PointerDeviceKind? kind;
  static bool _watching = false;

  static void watch() {
    if (_watching) return;
    _watching = true;
    GestureBinding.instance.pointerRouter.addGlobalRoute(_see);
  }

  static void _see(PointerEvent event) {
    if (event is! PointerScrollEvent) return;
    kind = event.kind;
    scheduleMicrotask(() => kind = null);
  }
}

/// A scroll position a mouse wheel scrolls smoothly: each notch moves it by
/// the distance the system gives (as Chrome takes it, not sped up), eased
/// out over a few frames ([WheelGlide]), under way in the frame after the
/// notch. The next notch adds to what the last had left, from where the
/// list is. A trackpad's scrolling, and anything else's, is as it comes.
///
/// Its controller is a [SmoothScrollController], which sees what device a
/// signal is from.
mixin WheelGliding on ScrollPositionWithSingleContext {
  @override
  void pointerScroll(double delta) {
    if (_WheelSignal.kind != PointerDeviceKind.mouse || delta == 0) {
      super.pointerScroll(delta);
      return;
    }
    final going = activity;
    final glide = WheelGlide.next(
      going is WheelScrollActivity ? going.glide : null,
      at: pixels,
      delta: delta,
      min: minScrollExtent,
      max: maxScrollExtent,
      frame: WheelGlide.frameOf(context.notificationContext),
    );
    if (glide == null) {
      // Back where it was going from (or still at an end): it stops.
      if (going is WheelScrollActivity) goBallistic(0);
      return;
    }
    // The user's, as a jump would be.
    updateUserScrollDirection(
      glide.distance > 0 ? ScrollDirection.reverse : ScrollDirection.forward,
    );
    beginActivity(
      WheelScrollActivity(this, vsync: context.vsync, glide: glide),
    );
  }

  /// Where the list is going: where a wheel's notches are taking it, while
  /// they move it; else where it is.
  double get headedTo => switch (activity) {
    final WheelScrollActivity wheel => pixels + wheel.glide.left,
    _ => pixels,
  };
}

/// A mouse wheel's notches scrolling a list ([WheelGlide]), stopped at an
/// end of it.
class WheelScrollActivity extends ScrollActivity {
  WheelScrollActivity(
    super.delegate, {
    required TickerProvider vsync,
    required this.glide,
  }) {
    _ticker = vsync.createTicker(_tick)..start();
  }

  final WheelGlide glide;

  late final Ticker _ticker;
  bool _disposed = false;

  void _tick(Duration _) {
    final position = delegate as ScrollPosition;
    final to = position.pixels + glide.step();
    final kept = to.clamp(position.minScrollExtent, position.maxScrollExtent);
    delegate.setPixels(kept);
    if (_disposed) return; // Stopped by what the move set off.
    if (glide.done || kept != to) delegate.goBallistic(0);
  }

  @override
  void dispatchOverscrollNotification(
    ScrollMetrics metrics,
    BuildContext context,
    double overscroll,
  ) {
    OverscrollNotification(
      metrics: metrics,
      context: context,
      overscroll: overscroll,
      velocity: velocity,
    ).dispatch(context);
  }

  @override
  bool get shouldIgnorePointer => false;

  @override
  bool get isScrolling => true;

  /// Pixels a second, now.
  @override
  double get velocity => glide.velocity;

  @override
  void dispose() {
    _disposed = true;
    _ticker.dispose();
    super.dispose();
  }
}
