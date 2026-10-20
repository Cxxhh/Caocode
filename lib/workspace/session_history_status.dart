import 'dart:async';

import 'package:flutter/material.dart';

import '../ide/ide_button.dart';
import '../theme/app_theme.dart';
import '../theme/codicons.dart';
import 'workspace.dart';

/// The same sync feedback stays visible with a chat, without one, and on mobile widths.
class SessionHistoryStatus extends StatelessWidget {
  const SessionHistoryStatus({super.key, required this.workspace});
  final Workspace workspace;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: workspace,
    builder: (context, _) {
      final zh = Localizations.localeOf(context).languageCode == 'zh';
      final state = workspace.history;
      final count = workspace.historyCount;
      final label = state.loading
          ? state.loadingMore
                ? (zh ? '正在读取较早会话…' : 'Loading older chats…')
                : state.received > 0
                ? (zh
                      ? '已读取 ${state.received} 条会话…'
                      : 'Read ${state.received} chats…')
                : count > 0
                ? (zh
                      ? '已显示 $count 条，正在更新…'
                      : 'Showing $count chats, updating…')
                : (zh ? '正在读取会话…' : 'Loading chats…')
          : state.error != null
          ? (zh ? '会话读取失败' : 'Could not load chats')
          : (zh ? '$count 条会话' : '$count ${count == 1 ? 'chat' : 'chats'}');
      return Column(
        key: const ValueKey('session-history-status'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (state.loading) ...[
                const SizedBox.square(
                  dimension: 12,
                  child: CircularProgressIndicator(strokeWidth: 1.5),
                ),
                const SizedBox(width: 7),
              ],
              Expanded(
                child: Tooltip(
                  message: state.error?.toString() ?? label,
                  child: Text(
                    label,
                    style: TextStyle(fontSize: 12, color: AppColors.textMuted),
                  ),
                ),
              ),
              if (state.error != null && !state.loading)
                Tooltip(
                  message: zh ? '重试读取会话' : 'Retry loading chats',
                  child: IdeButton(
                    key: const ValueKey('session-history-refresh'),
                    label: zh ? '重试' : 'Retry',
                    secondary: true,
                    onPressed: () => unawaited(workspace.retryHistory()),
                  ),
                )
              else
                IconButton(
                  key: const ValueKey('session-history-refresh'),
                  tooltip: state.error != null
                      ? (zh ? '重试读取会话' : 'Retry loading chats')
                      : (zh ? '刷新会话' : 'Refresh chats'),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 28,
                    height: 28,
                  ),
                  iconSize: 14,
                  icon: Icon(
                    state.error != null ? Codicons.warning : Codicons.refresh,
                  ),
                  onPressed: state.loading
                      ? null
                      : () => unawaited(
                          state.error == null
                              ? workspace.refresh()
                              : workspace.retryHistory(),
                        ),
                ),
            ],
          ),
          if (state.hasMore)
            Align(
              alignment: Alignment.centerLeft,
              child: IdeButton(
                key: const ValueKey('session-history-more'),
                label: zh ? '加载更早会话' : 'Load older chats',
                secondary: true,
                icon: Codicons.history,
                onPressed: state.loading
                    ? null
                    : () => unawaited(workspace.loadMoreHistory()),
              ),
            ),
        ],
      );
    },
  );
}
