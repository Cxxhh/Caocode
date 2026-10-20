import 'dart:async';

import 'package:flutter/material.dart';

import '../ide/ide_button.dart';
import '../ide/ide_dialog.dart';
import '../ide/ide_menu.dart';
import '../kernel/codex/codex_environment.dart';
import '../theme/codicons.dart';
import 'window_controls.dart';

/// Shared by the sidebar, empty state and CLI settings.
class CodexEnvironmentPicker extends StatefulWidget {
  const CodexEnvironmentPicker({super.key, this.onChanged});
  final VoidCallback? onChanged;
  @override
  State<CodexEnvironmentPicker> createState() => _CodexEnvironmentPickerState();
}

class _CodexEnvironmentPickerState extends State<CodexEnvironmentPicker> {
  bool _busy = false;

  Future<void> _open(BuildContext anchor) async {
    setState(() => _busy = true);
    final controller = CodexEnvironmentController.instance;
    // Capture the anchor before the asynchronous discovery.
    final box = anchor.findRenderObject()! as RenderBox;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    try {
      var choices = const [CodexEnvironment.windows()];
      Object? discoveryError;
      try {
        choices = await controller.choices();
      } catch (error) {
        discoveryError = error;
      }
      if (!mounted) return;
      await showIdeMenu(
        context,
        anchor: rect,
        entries: [
          for (final choice in choices)
            IdeMenuAction(
              choice.label,
              checked: choice.id == controller.selected.id,
              onSelected: () => unawaited(_select(choice)),
            ),
          if (discoveryError != null)
            IdeMenuAction('无法读取 WSL2：$discoveryError', enabled: false)
          else if (choices.length == 1)
            const IdeMenuAction('未发现 WSL2 发行版', enabled: false),
        ],
      );
    } catch (error) {
      if (mounted) {
        await showIdeDialog(
          context,
          message: '无法读取运行环境',
          detail: '$error',
          buttons: const ['确定'],
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _select(CodexEnvironment environment) async {
    try {
      await CodexEnvironmentController.instance.select(environment);
      widget.onChanged?.call();
    } catch (error) {
      if (mounted) {
        await showIdeDialog(
          context,
          message: '无法保存运行环境',
          detail: '$error',
          buttons: const ['确定'],
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = CodexEnvironmentController.instance;
    if (!controller.supported) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => Builder(
        builder: (anchor) => IdeButton(
          key: const ValueKey('codex-environment-picker'),
          label: _busy ? '正在读取环境…' : controller.selected.label,
          icon: Codicons.terminal,
          secondary: true,
          onPressed: _busy ? null : () => unawaited(_open(anchor)),
        ),
      ),
    );
  }
}

/// All project-opening entry points use the same target and remembered folder.
/// Generic directory pickers (data, downloads, etc.) remain native pickers.
Future<String?> pickCodexProjectDirectory(BuildContext context) async {
  try {
    return await CodexEnvironmentController.instance.pick(
      (initial) => WindowControls.pickDirectory(initialDirectory: initial),
    );
  } catch (error) {
    if (context.mounted) {
      await showIdeDialog(
        context,
        message: '无法打开项目目录',
        detail: '$error',
        buttons: const ['确定'],
      );
    }
    return null;
  }
}
