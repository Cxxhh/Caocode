import '../../kernel/agent_kernel.dart';
import '../../kernel/kernel_types.dart';
import '../../l10n/l10n.dart';

/// [option], one of [kernel]'s approvals or model settings, in the app's
/// language. Unknown choices keep the names reported by the kernel.
KernelOption localizedKernelOption(
  AppLocalizations l10n,
  String kernel,
  KernelChoiceKind kind,
  KernelOption option,
) {
  final text = switch ((kernel, kind, option.id)) {
    ('codex', KernelChoiceKind.permission, 'default') => (
      l10n.composerCodexApprovalDefault,
      l10n.composerCodexApprovalDefaultDetail,
    ),
    ('codex', KernelChoiceKind.permission, 'auto') => (
      l10n.composerCodexApprovalAuto,
      l10n.composerCodexApprovalAutoDetail,
    ),
    ('codex', KernelChoiceKind.permission, 'full-access') => (
      l10n.composerCodexApprovalFullAccess,
      l10n.composerCodexApprovalFullAccessDetail,
    ),
    ('codex', KernelChoiceKind.permission, 'custom') => (
      l10n.composerCodexApprovalCustom,
      l10n.composerCodexApprovalCustomDetail,
    ),
    ('codex', KernelChoiceKind.effort, 'none') => (
      l10n.composerEffortNone,
      option.description,
    ),
    ('codex', KernelChoiceKind.effort, 'minimal') => (
      l10n.composerEffortMinimal,
      option.description,
    ),
    ('codex', KernelChoiceKind.effort, 'low') => (
      l10n.composerEffortLow,
      option.description,
    ),
    ('codex', KernelChoiceKind.effort, 'medium') => (
      l10n.composerEffortMedium,
      option.description,
    ),
    ('codex', KernelChoiceKind.effort, 'high') => (
      l10n.composerEffortHigh,
      option.description,
    ),
    ('codex', KernelChoiceKind.effort, 'xhigh') => (
      l10n.composerEffortExtraHigh,
      option.description,
    ),
    ('codex', KernelChoiceKind.effort, 'ultra') => (
      l10n.composerEffortUltra,
      option.description,
    ),
    ('codex', KernelChoiceKind.effort, 'max') => (
      l10n.composerEffortMaximum,
      option.description,
    ),
    ('claude-code', KernelChoiceKind.permission, 'default') => (
      l10n.composerApprovalDefault,
      l10n.composerApprovalDefaultDetail,
    ),
    ('claude-code', KernelChoiceKind.permission, 'acceptEdits') => (
      l10n.composerApprovalAcceptEdits,
      l10n.composerApprovalAcceptEditsDetail,
    ),
    ('claude-code', KernelChoiceKind.permission, 'auto') => (
      l10n.composerApprovalAuto,
      l10n.composerApprovalAutoDetail,
    ),
    ('claude-code', KernelChoiceKind.permission, 'dontAsk') => (
      l10n.composerApprovalDontAsk,
      l10n.composerApprovalDontAskDetail,
    ),
    ('claude-code', KernelChoiceKind.permission, 'bypassPermissions') => (
      l10n.composerApprovalFullAccess,
      l10n.composerApprovalFullAccessDetail,
    ),
    _ => null,
  };
  if (text == null) return option;
  return KernelOption(
    option.id,
    text.$1,
    option.icon,
    text.$2,
    caution: option.caution,
    iconBuilder: option.iconBuilder,
  );
}
