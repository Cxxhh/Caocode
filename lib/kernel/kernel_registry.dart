import 'package:flutter/material.dart';

import 'agent_kernel.dart';
import 'claude_code/claude_code_kernel.dart';
import '../remote/remote_claude.dart';
import 'codex/codex_catalog.dart';
import 'codex/codex_kernel.dart';
import 'codex/codex_process.dart';

/// The kernels the user can pick from. Another kernel is an adapter and a
/// line here.
abstract final class KernelRegistry {
  static final KernelDescriptor claudeCode = KernelDescriptor(
    id: 'claude-code',
    label: 'Claude Code',
    icon: Icons.auto_awesome_rounded,
    description: 'Anthropic’s coding agent',
    create: (context) => ClaudeCodeKernel(
      claudeCode,
      context,
      // On the project's host: this machine, or a remote one's.
      start: startClaude,
      readHistory: readClaudeHistory,
      readGoal: readClaudeGoal,
      forkSession: forkClaudeSession,
      usageOffBy: () => claudeUsageOffByAt(context.cwd),
      rejectTooOld: rejectTooOldClaude,
    ),
    catalog: const ClaudeCatalog(),
  );

  static final KernelDescriptor codex = KernelDescriptor(
    id: 'codex',
    label: 'Codex CLI',
    icon: Icons.bolt_rounded,
    description: '通过 Codex app-server 执行代理任务',
    create: (context) => CodexKernel(
      codex,
      localCodexTransport(cwd: context.cwd),
      context: context,
      reconnect: () => localCodexTransport(cwd: context.cwd),
    ),
    catalog: const CodexCatalog(),
  );

  static List<KernelDescriptor> _all = [codex];

  static List<KernelDescriptor> get all => _all;

  /// Replaces the kernels on offer, e.g. with mock ones under test.
  static void use(List<KernelDescriptor> kernels) => _all = kernels;
}
