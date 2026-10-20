import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ide/ide_spinning.dart';
import '../l10n/l10n.dart';
import '../theme/app_theme.dart';
import '../theme/codicons.dart';
import '../theme/workbench_theme.dart' show themeColors;

/// Shows a feature's welcome (Stash's, the browser's): a card over the
/// window that comes in growing a little, gone with Escape, Enter, or its
/// button; not with a click beside it, a step half done there kept.
Future<void> showWelcomeDialog(
  BuildContext context, {
  required WidgetBuilder builder,
}) => showGeneralDialog<void>(
  context: context,
  barrierDismissible: false,
  barrierLabel: context.l10n.commonDismiss,
  barrierColor: const Color(0x59000000),
  transitionDuration: const Duration(milliseconds: 280),
  transitionBuilder: (context, animation, _, child) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return FadeTransition(
      opacity: curved,
      child: ScaleTransition(
        scale: Tween(begin: .96, end: 1.0).animate(curved),
        child: child,
      ),
    );
  },
  pageBuilder: (context, _, _) => builder(context),
);

/// A welcome's card: its [picture] on the left, beside what it says, which
/// scrolls in a short window, and its [footer] under that, which stays; on
/// a narrow window the picture at the top instead. Escape and Enter close
/// it, unless it is not [closable].
class WelcomeFrame extends StatelessWidget {
  const WelcomeFrame({
    super.key,
    required this.picture,
    required this.body,
    required this.footer,
    this.closable = true,
    this.stacked = false,
  });

  /// [pictureHeight] high, as wide as it is given.
  final Widget picture;
  final List<Widget> body;
  final Widget footer;

  /// False: only its [footer]'s button closes it.
  final bool closable;

  /// The picture at the top on a wide window too: a card narrower and
  /// taller, for a welcome with less to say.
  final bool stacked;

  static const pictureHeight = 180.0;

  /// The picture's side and the text's, side by side.
  static const _pictureWidth = 400.0;
  static const _textWidth = 440.0;
  static const _stackedWidth = 500.0;

  @override
  Widget build(BuildContext context) {
    final border = themeColors.get('widget.border') ?? AppColors.border;
    final size = MediaQuery.sizeOf(context);
    final wide = !stacked && size.width >= _pictureWidth + _textWidth + 48;
    final glow = AppColors.accent.withValues(alpha: .10);
    final edge = BorderSide(color: AppColors.border);
    final backdrop = BoxDecoration(
      gradient: RadialGradient(
        center: Alignment(0, wide ? -.1 : -.2),
        radius: 1.1,
        colors: [glow, glow.withValues(alpha: 0)],
      ),
      border: wide ? Border(right: edge) : Border(bottom: edge),
    );
    final text = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Flexible(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [if (wide) const SizedBox(height: 12), ...body],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 16, 28, 22),
          child: footer,
        ),
      ],
    );
    final framed = SizedBox(height: pictureHeight, child: picture);
    return CallbackShortcuts(
      bindings: {
        if (closable) ...{
          const SingleActivator(LogicalKeyboardKey.escape): () =>
              Navigator.pop(context),
          const SingleActivator(LogicalKeyboardKey.enter): () =>
              Navigator.pop(context),
        },
      },
      child: FocusScope(
        autofocus: true,
        child: Center(
          child: Material(
            type: MaterialType.transparency,
            child: Container(
              width: wide
                  ? _pictureWidth + _textWidth
                  : stacked
                  ? _stackedWidth
                  : 480,
              constraints: BoxConstraints(maxHeight: size.height * .9),
              decoration: BoxDecoration(
                color: themeColors['editorWidget.background'],
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: border),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x33000000),
                    blurRadius: 40,
                    offset: Offset(0, 16),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(15),
                child: wide
                    // The picture as tall as the text beside it.
                    ? Stack(
                        children: [
                          Positioned(
                            left: 0,
                            top: 0,
                            bottom: 0,
                            width: _pictureWidth,
                            child: DecoratedBox(
                              decoration: backdrop,
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [framed],
                              ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.only(left: _pictureWidth),
                            child: text,
                          ),
                        ],
                      )
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          DecoratedBox(decoration: backdrop, child: framed),
                          Flexible(child: text),
                        ],
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A welcome's title and the line under it.
class WelcomeHeading extends StatelessWidget {
  const WelcomeHeading({
    super.key,
    required this.title,
    required this.lead,
    this.above,
  });

  final String title;
  final String lead;

  /// Over the title, a little apart (a tag).
  final Widget? above;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(28, 20, 28, 0),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (above case final above?) ...[above, const SizedBox(height: 12)],
        Text(
          title,
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          lead,
          style: TextStyle(
            color: AppColors.textMuted,
            fontSize: 13,
            height: 1.5,
          ),
        ),
      ],
    ),
  );
}

/// [child] fading in as it rises a little.
class WelcomeRise extends StatelessWidget {
  const WelcomeRise({super.key, required this.animation, required this.child});

  final Animation<double> animation;
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: animation,
    builder: (context, child) => Opacity(
      opacity: animation.value.clamp(0.0, 1.0),
      child: Transform.translate(
        offset: Offset(0, (1 - animation.value) * 10),
        child: child,
      ),
    ),
    child: child,
  );
}

/// One thing the feature does: its icon in a tile, a title, a line.
class WelcomeLine extends StatelessWidget {
  const WelcomeLine({
    super.key,
    required this.icon,
    required this.title,
    required this.text,
  });

  final Widget icon;
  final String title;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(28, 6, 28, 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 30,
          height: 30,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: AppColors.textMuted.withValues(alpha: .1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: IconTheme.merge(
            data: IconThemeData(color: AppColors.text),
            child: icon,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                text,
                style: TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 12.5,
                  height: 1.45,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

/// The one thing to do, in a box of its own: green with a tick once done.
class WelcomeStep extends StatelessWidget {
  const WelcomeStep({
    super.key,
    required this.done,
    required this.icon,
    required this.title,
    required this.text,
    this.below = const [],
    this.spinning = false,
  });

  final bool done;

  /// Shown till [done]; turning while [spinning].
  final IconData icon;
  final bool spinning;
  final String title;
  final String text;
  final List<Widget> below;

  @override
  Widget build(BuildContext context) {
    final green = themeColors['charts.green'];
    return AnimatedContainer(
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      margin: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      padding: const EdgeInsets.fromLTRB(8, 12, 14, 14),
      decoration: BoxDecoration(
        color: (done ? green : AppColors.textMuted).withValues(alpha: .07),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: done ? green.withValues(alpha: .35) : AppColors.border,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: (done ? green : AppColors.textMuted).withValues(
                alpha: .14,
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              transitionBuilder: (child, animation) => ScaleTransition(
                scale: CurvedAnimation(
                  parent: animation,
                  curve: Curves.easeOutBack,
                ),
                child: FadeTransition(opacity: animation, child: child),
              ),
              child: done || !spinning
                  ? Icon(
                      done ? Codicons.check : icon,
                      key: ValueKey(done),
                      size: 15,
                      color: done ? green : AppColors.text,
                    )
                  : IdeSpinning(
                      key: const ValueKey('spinning'),
                      Icon(icon, size: 15, color: AppColors.text),
                    ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  text,
                  style: TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 12.5,
                    height: 1.45,
                  ),
                ),
                ...below,
              ],
            ),
          ),
        ],
      ),
    );
  }
}
