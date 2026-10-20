import 'package:flutter/foundation.dart';

import 'version.dart';

enum CodexCliUpdateStatus {
  idle,
  loading,
  checking,
  available,
  upToDate,
  updating,
  updated,
  failed,
}

class CodexCliInstallation {
  const CodexCliInstallation({
    required this.path,
    required this.host,
    required this.version,
    required this.canUpdate,
  });

  final String path;
  final String host;
  final AppVersion version;
  final bool canUpdate;
}

abstract interface class CodexCliUpdateBackend {
  Future<CodexCliInstallation> inspect();
  Future<AppVersion> latestVersion();
  Future<void> update(CodexCliInstallation installation, AppVersion version);
}

/// CLI updates are manual and independent of the application's update mode.
class CodexCliUpdateService extends ChangeNotifier {
  CodexCliUpdateService(this.backend);

  final CodexCliUpdateBackend backend;
  CodexCliUpdateStatus status = CodexCliUpdateStatus.idle;
  CodexCliInstallation? installation;
  AppVersion? latest;
  Object? error;
  bool _disposed = false;

  bool get busy => const {
    CodexCliUpdateStatus.loading,
    CodexCliUpdateStatus.checking,
    CodexCliUpdateStatus.updating,
  }.contains(status);

  bool get canUpdate =>
      !busy &&
      installation?.canUpdate == true &&
      latest != null &&
      latest!.compareTo(installation!.version) > 0;

  Future<void> load() => _run(CodexCliUpdateStatus.loading, () async {
    installation = await backend.inspect();
    status = CodexCliUpdateStatus.idle;
  });

  Future<void> check() => _run(CodexCliUpdateStatus.checking, () async {
    latest = null;
    installation = await backend.inspect();
    latest = await backend.latestVersion();
    status = latest!.compareTo(installation!.version) > 0
        ? CodexCliUpdateStatus.available
        : CodexCliUpdateStatus.upToDate;
  });

  Future<void> update() async {
    if (!canUpdate) return;
    await _run(CodexCliUpdateStatus.updating, () async {
      final before = installation!;
      final target = latest!;
      await backend.update(before, target);
      installation = await backend.inspect();
      if (installation!.path != before.path ||
          installation!.host != before.host ||
          installation!.version.compareTo(target) < 0) {
        throw StateError('升级后当前 CLI 尚未达到 $target，请检查安装路径或更新命令的输出。');
      }
      status = CodexCliUpdateStatus.updated;
    });
  }

  Future<void> _run(CodexCliUpdateStatus next, AsyncCallback action) async {
    if (busy || _disposed) return;
    status = next;
    error = null;
    notifyListeners();
    try {
      await action();
    } on Object catch (problem) {
      error = problem;
      status = CodexCliUpdateStatus.failed;
    }
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
