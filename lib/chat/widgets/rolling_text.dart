import 'package:flutter/material.dart';

/// [text] whose digits roll as they change, as an odometer's: the new one
/// up from below, the old one up and away. Its places are counted from
/// its end, where a number's ones are, so a digit gained in front leaves
/// the rest where they were. All at once where motion is turned down.
class RollingText extends StatelessWidget {
  const RollingText(this.text, {super.key, required this.style});

  final String text;
  final TextStyle style;

  static const duration = Duration(milliseconds: 220);

  /// [text] in runs: each digit alone, what is between them together.
  static List<String> runsOf(String text) {
    final runs = <String>[];
    final other = StringBuffer();
    for (final char in text.characters) {
      if (_isDigit(char)) {
        if (other.isNotEmpty) runs.add(other.toString());
        other.clear();
        runs.add(char);
      } else {
        other.write(char);
      }
    }
    if (other.isNotEmpty) runs.add(other.toString());
    return runs;
  }

  static bool _isDigit(String char) =>
      char.length == 1 &&
      char.codeUnitAt(0) >= 0x30 &&
      char.codeUnitAt(0) <= 0x39;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) {
      return Text(text, style: style);
    }
    final runs = runsOf(text);
    return Semantics(
      label: text,
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (index, run) in runs.indexed)
            KeyedSubtree(
              key: ValueKey(runs.length - index),
              child: _isDigit(run)
                  ? _Digit(run, style: style)
                  : Text(run, style: style),
            ),
        ],
      ),
    );
  }
}

class _Digit extends StatefulWidget {
  const _Digit(this.digit, {required this.style});

  final String digit;
  final TextStyle style;

  @override
  State<_Digit> createState() => _DigitState();
}

class _DigitState extends State<_Digit> {
  /// Each change's own: a digit back before the last has gone out is
  /// another child than that.
  int _change = 0;

  @override
  void didUpdateWidget(_Digit oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.digit != oldWidget.digit) _change++;
  }

  @override
  Widget build(BuildContext context) {
    final key = ValueKey(_change);
    return ClipRect(
      child: AnimatedSwitcher(
        duration: RollingText.duration,
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, animation) {
          // Played forward coming in, backward going: the one going out
          // leaves upward, as the one coming in rises.
          final incoming = child.key == key;
          final offset = Tween(
            begin: Offset(0, incoming ? 0.8 : -0.8),
            end: Offset.zero,
          ).animate(animation);
          return FadeTransition(
            opacity: animation,
            child: SlideTransition(position: offset, child: child),
          );
        },
        child: Text(widget.digit, key: key, style: widget.style),
      ),
    );
  }
}
