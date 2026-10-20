import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// An interactive tooltip lives outside its anchor's scrollable. Pass scrolling
/// back to that scrollable, after any scrollable inside the tooltip has a turn.
class TooltipScroll extends StatefulWidget {
  const TooltipScroll({
    super.key,
    required this.anchorContext,
    required this.child,
  });

  final BuildContext anchorContext;
  final Widget child;

  @override
  State<TooltipScroll> createState() => _TooltipScrollState();
}

class _TooltipScrollState extends State<TooltipScroll> {
  Drag? _drag;

  void _wheel(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    var context = widget.anchorContext;
    while (context.mounted) {
      final scrollable = Scrollable.maybeOf(context);
      if (scrollable == null) return;
      final position = scrollable.position;
      var axis = axisDirectionToAxis(position.axisDirection);
      final modifiers = ScrollConfiguration.of(context).pointerAxisModifiers;
      if (event.kind == PointerDeviceKind.mouse &&
          HardwareKeyboard.instance.logicalKeysPressed.any(
            modifiers.contains,
          )) {
        axis = flipAxis(axis);
      }
      var delta = axis == Axis.vertical
          ? event.scrollDelta.dy
          : event.scrollDelta.dx;
      if (axisDirectionIsReversed(position.axisDirection)) delta = -delta;
      if (position.physics.shouldAcceptUserOffset(position) &&
          delta != 0 &&
          (position.pixels + delta).clamp(
                position.minScrollExtent,
                position.maxScrollExtent,
              ) !=
              position.pixels) {
        // A scrollable inside the tooltip registers first and takes priority.
        GestureBinding.instance.pointerSignalResolver.register(event, (_) {
          if (!mounted || !scrollable.mounted) return;
          position.pointerScroll(delta);
          event.respond(allowPlatformDefault: false);
        });
        return;
      }
      context = scrollable.context;
    }
  }

  void _startPan(DragStartDetails details) {
    final scrollable = Scrollable.maybeOf(widget.anchorContext);
    if (scrollable == null ||
        !scrollable.position.physics.shouldAcceptUserOffset(
          scrollable.position,
        )) {
      return;
    }
    _drag?.cancel();
    _drag = scrollable.position.drag(details, () => _drag = null);
  }

  @override
  void dispose() {
    _drag?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scrollable = Scrollable.maybeOf(widget.anchorContext);
    if (scrollable == null) return widget.child;
    final vertical =
        axisDirectionToAxis(scrollable.axisDirection) == Axis.vertical;
    return Listener(
      onPointerSignal: _wheel,
      child: GestureDetector(
        // Mouse drags still select the tooltip's text. The source position's
        // drag handles trackpad direction, physics and momentum as usual.
        supportedDevices: const {PointerDeviceKind.trackpad},
        onVerticalDragStart: vertical ? _startPan : null,
        onVerticalDragUpdate: vertical
            ? (details) => _drag?.update(details)
            : null,
        onVerticalDragEnd: vertical ? (details) => _drag?.end(details) : null,
        onVerticalDragCancel: vertical ? () => _drag?.cancel() : null,
        onHorizontalDragStart: vertical ? null : _startPan,
        onHorizontalDragUpdate: vertical
            ? null
            : (details) => _drag?.update(details),
        onHorizontalDragEnd: vertical ? null : (details) => _drag?.end(details),
        onHorizontalDragCancel: vertical ? null : () => _drag?.cancel(),
        child: widget.child,
      ),
    );
  }
}
