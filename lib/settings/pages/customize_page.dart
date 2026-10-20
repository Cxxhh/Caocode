import 'package:flutter/material.dart';

import '../../customize/customization_store.dart';
import '../../customize/customizations.dart';
import '../../customize/customize_view.dart';
import '../../workspace/workspace.dart';

/// Claude Code's customizations, as a settings page: skills, subagents,
/// commands and rules edited in place, the other files (MCP servers, hooks,
/// plugins) shown and edited whole. The same view as Customize beside the
/// chat (⌘⇧K, or the sidebar's), reached here from the settings' search too.
class CustomizeSettingsPage extends StatelessWidget {
  const CustomizeSettingsPage({
    super.key,
    required this.customizations,
    this.workspace,
  });

  /// Claude Code's customizations; none where there are no files (the web).
  final CustomizationStore? customizations;

  /// The projects whose customizations show beside the user's.
  final Workspace? workspace;

  @override
  Widget build(BuildContext context) {
    final store = customizations ?? CustomizationStore();
    final projects = workspace?.projects ?? const <Project>[];
    return CustomizeView(
      store: store,
      projects: projects,
      project: projects.firstOrNull,
      showTitleBar: false,
      kind: CustomizationKind.skills,
      onClose: () {},
    );
  }
}
