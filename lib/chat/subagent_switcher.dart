import 'dart:async';

import 'package:flutter/material.dart';

import '../ide/ide_button.dart';
import '../ide/ide_menu.dart';
import '../l10n/l10n.dart';
import '../theme/app_theme.dart';
import '../theme/codicons.dart';
import 'chat_models.dart';
import 'chat_session.dart';

/// A persistent way back to the parent and across sibling/nested agents, even
/// after the card that launched one has scrolled out of view.
class SubagentSwitcher extends StatelessWidget {
  const SubagentSwitcher({
    super.key,
    required this.session,
    required this.onSelect,
    this.selected,
  });
  final ChatSession session;
  final String? selected;
  final ValueChanged<List<String>> onSelect;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    builder: (context, _) {
      final agents = session.subagents;
      if (agents.isEmpty) return const SizedBox.shrink();
      if (session.subagentHistory(agents.first.agent.id!) == null) {
        return const SizedBox.shrink();
      }
      final zh = Localizations.localeOf(context).languageCode == 'zh';
      final running = agents
          .where((entry) => entry.agent.status == CommandStatus.running)
          .length;
      final current = agents
          .where((entry) => entry.agent.id == selected)
          .firstOrNull;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
        child: Row(
          children: [
            Expanded(
              child: Text(
                current?.agent.description ?? context.l10n.chatConversation,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: AppColors.textMuted, fontSize: 12),
              ),
            ),
            const SizedBox(width: 12),
            Builder(
              builder: (anchor) => IdeButton(
                key: const ValueKey('subagent-switcher'),
                label: zh
                    ? '子代理 ${agents.length}${running > 0 ? ' · $running 运行中' : ''}'
                    : 'Subagents ${agents.length}${running > 0 ? ' · $running active' : ''}',
                icon: Codicons.organization,
                secondary: true,
                onPressed: () {
                  final box = anchor.findRenderObject()! as RenderBox;
                  final ordered = [...agents]
                    ..sort(
                      (a, b) =>
                          (a.agent.status == CommandStatus.running ? 0 : 1)
                              .compareTo(
                                b.agent.status == CommandStatus.running ? 0 : 1,
                              ),
                    );
                  unawaited(
                    showIdeMenu(
                      context,
                      anchor: box.localToGlobal(Offset.zero) & box.size,
                      entries: [
                        IdeMenuAction(
                          context.l10n.chatConversation,
                          checked: selected == null,
                          onSelected: () => onSelect(const []),
                        ),
                        const IdeMenuSeparator(),
                        for (final entry in ordered)
                          IdeMenuAction(
                            '${entry.path.length > 1 ? '› ' * (entry.path.length - 1) : ''}${entry.agent.description} · ${switch (entry.agent.status) {
                              CommandStatus.running => zh ? '运行中' : 'Running',
                              CommandStatus.succeeded => zh ? '已完成' : 'Completed',
                              CommandStatus.failed => zh ? '已停止 / 失败' : 'Stopped / Failed',
                            }}',
                            checked: entry.agent.id == selected,
                            onSelected: () => onSelect(entry.path),
                          ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      );
    },
  );
}
