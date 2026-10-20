import 'claude_code_transport.dart';
import 'dart_core_transport_stub.dart'
    if (dart.library.io) 'dart_core_transport_io.dart'
    as platform;

/// Starts a session on Caocode's own core (package:bao_agent), on this
/// machine; on the web, where it cannot run, fails saying so.
Future<ClaudeCodeTransport> startDartCore(ClaudeLaunch launch) =>
    platform.DartCoreTransport.start(launch);
