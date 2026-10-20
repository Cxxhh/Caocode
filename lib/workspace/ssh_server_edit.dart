import 'package:bao_remote/client.dart';
import 'package:flutter/widgets.dart';

import '../models/secret_store.dart';
import '../remote/ssh_host.dart';
import '../remote/ssh_passwords.dart';
import '../remote/ssh_server_form.dart';
import 'workspace.dart';

/// Shows the form of a server, adding one (at [address], when typed) or
/// editing [host], and saves what it was saved with: the server in
/// [workspace], its password in the keychain (dropped once it signs in
/// otherwise). [configHosts], those of `~/.ssh/config`, may be jumped
/// through besides the workspace's. Null when cancelled; [onWarning] is told
/// what the keychain refused (the password asked for when connecting
/// instead). From the window's picker and sidebar, and Settings → SSH.
Future<SshServerFormResult?> editSshServer(
  BuildContext context,
  Workspace workspace, {
  String? host,
  String? address,
  List<String> configHosts = const [],
  void Function(String message)? onWarning,
}) async {
  final passwords = SshHosts.instance.passwords;
  final kept =
      host != null &&
      await passwords
          .has(SshPasswords.serverId(host))
          .catchError((Object _) => false);
  if (!context.mounted) return null;
  final result = await showSshServerForm(
    context,
    host: host,
    address: address,
    server: host == null ? null : workspace.sshServers[host],
    name: host == null || workspace.hostLabel(host) == host
        ? null
        : workspace.hostLabel(host),
    hasPassword: kept,
    jumps: {...workspace.sshHosts, ...configHosts}.toList(),
    labelOf: workspace.hostLabel,
  );
  if (result == null) return null;
  workspace.saveSshServer(result.host, result.server, name: result.name);
  final id = SshPasswords.serverId(result.host);
  try {
    if (result.password case final password?) {
      await passwords.keep(id, password);
    } else if (kept && result.server.auth != SshAuth.password) {
      await passwords.keep(id, null);
    }
  } on SecretStoreException catch (error) {
    onWarning?.call('$error');
  }
  return result;
}
