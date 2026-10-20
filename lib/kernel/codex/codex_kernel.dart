import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../chat/chat_models.dart';
import '../agent_kernel.dart';
import '../kernel_event.dart';
import '../kernel_types.dart';
import 'codex_catalog.dart';
import 'codex_choices.dart';
import 'codex_process.dart';
import 'codex_rpc.dart';
import 'codex_transport.dart';

/// Adapts `codex app-server` to [AgentKernel]. Codex keeps no background
/// commands and cannot put files back, so it does not declare
/// [RunsBackgroundTasks] or [RevertsChanges]: those parts of the UI are not
/// shown for it.
class CodexKernel
    with KernelEventSource
    implements
        AgentKernel,
        SelectsModel,
        SelectsPermission,
        SelectsEffort,
        TogglesFastMode,
        QueuesMessages,
        ProvidesCommands,
        ReportsContext,
        RewindsConversation,
        RenamesSession,
        AcceptsImages {
  CodexKernel(
    this.descriptor,
    this._transport, {
    KernelContext context = const KernelContext(),
    this.reconnect,
  }) : _context = context {
    _threadId = context.resume?.id;
    model.reported = context.settings['model'];
    if (codexPermissionOptions.any(
      (option) => option.id == context.settings['permission'],
    )) {
      permission.reported = context.settings['permission'];
    }
    _connect();
  }

  @override
  final KernelDescriptor descriptor;
  CodexTransport _transport;
  final KernelContext _context;
  final CodexTransport Function()? reconnect;
  late CodexRpcClient _rpc;
  late StreamSubscription<Map<String, Object?>> _subscription;

  @override
  late final LocalChoice model = LocalChoice(
    const [
      KernelOption(
        'default',
        'CLI 默认',
        Icons.bolt_rounded,
        '使用 Codex CLI 的模型配置',
      ),
    ],
    onChanged: (_) {
      if (fastEnabled) _serviceTierOverride = _fastTier ?? 'default';
      emitInfoChanged();
    },
  );

  @override
  late final LocalChoice permission = LocalChoice(
    codexPermissionOptions,
    onChanged: (_) => emitInfoChanged(),
  );

  @override
  late final CodexEffort effort = CodexEffort(
    model,
    _context.settings,
    emitInfoChanged,
  );
  Map _config = const {};
  final Map<String, Map> _modelsById = {};
  String? _serviceTierOverride;
  String? _reportedServiceTier;
  String? _reportedModelProvider;
  Future<void>? _fastChange;

  @override
  bool get fastAvailable => _fastTier != null;

  @override
  bool get fastChanging => _fastChange != null;

  String? get _fastTier {
    if ((_config['features'] as Map?)?['fast_mode'] == false) return null;
    final selected = _modelsById[effort.resolvedModel];
    final serviceTiers = selected?['serviceTiers'];
    final speedTiers = selected?['additionalSpeedTiers'];
    if (serviceTiers case final List tiers) {
      for (final tier in tiers.whereType<Map>()) {
        if (tier['id'] is String &&
            (tier['id'] as String).isNotEmpty &&
            ({
                  'fast',
                  'priority',
                }.contains(tier['name'].toString().trim().toLowerCase()) ||
                tier['id'] == 'fast' ||
                tier['id'] == 'priority')) {
          return tier['id'] as String;
        }
      }
    }
    if (speedTiers case final List tiers) {
      if (tiers.contains('fast')) return 'fast';
      if (tiers.contains('priority')) return 'priority';
    }
    if (serviceTiers is List || speedTiers is List) {
      final hasCustomProvider =
          [_config['model_provider'], _reportedModelProvider]
              .whereType<String>()
              .any((provider) => provider.toLowerCase() != 'openai');
      final hasAdvertisedTiers =
          (serviceTiers is List && serviceTiers.isNotEmpty) ||
          (speedTiers is List && speedTiers.isNotEmpty);
      // Custom-provider catalogs may return empty lists for every model,
      // even when service_tier is configured. Let the provider validate Fast.
      if (hasCustomProvider && !hasAdvertisedTiers) {
        return 'fast';
      }
      return null;
    }
    // Older CLI catalogs and custom providers may omit tier metadata.
    return 'fast';
  }

  @override
  bool get fastEnabled {
    final tier =
        _serviceTierOverride ??
        _reportedServiceTier ??
        _config['service_tier'] ??
        _modelsById[effort.resolvedModel]?['defaultServiceTier'];
    return tier == 'fast' ||
        tier == 'priority' ||
        (tier != null && tier == _fastTier);
  }

  @override
  KernelHealth get health => _health;
  KernelHealth _health = KernelHealth.idle;
  bool _disposed = false;
  bool _released = false;
  bool _historyLoaded = false;
  bool _replaying = false;
  List<KernelEvent>? _replayEvents;
  String? _pendingName;
  final List<KernelTurn> _queue = [];
  bool _startingTurn = false;
  Future<void>? _preparing;
  Future<void>? _openingThread;
  Future<void> _shutdown = Future.value();
  int _generation = 0;

  void _connect() {
    final generation = ++_generation;
    _rpc = CodexRpcClient(_transport);
    _subscription = _rpc.messages.listen(
      (message) {
        if (generation == _generation) _receive(message);
      },
      onError: (Object error, StackTrace stack) {
        if (generation == _generation) _failed(error, stack);
      },
    );
  }

  @override
  String? get sessionId => _threadId;

  @override
  Future<void> get stopped => _shutdown;

  @override
  void prepare() {
    // A chat attaches while Flutter mounts its view. Notify the workspace only
    // after that build finishes, so starting the CLI cannot invalidate it.
    unawaited(Future<void>.microtask(_ready).catchError((Object _) {}));
  }

  @override
  void release() {
    if (_turn != null || _disposed || _released || reconnect == null) return;
    _released = true;
    _generation++;
    _rpc.close();
    _shutdown = _rpc.stopped;
    unawaited(_subscription.cancel());
    _preparing = null;
    _openingThread = null;
    _health = KernelHealth.idle;
    _serverTurn = null;
    emitInfoChanged();
  }

  @override
  void restart() {
    if (_disposed || reconnect == null) return;
    cancel();
    release();
    prepare();
  }

  Future<void> _ready() async {
    if (_disposed) throw const CodexRpcException('会话已关闭');
    if (_released) {
      await _shutdown;
      if (_disposed) return;
      if (_released) {
        _released = false;
        _transport = reconnect!();
        _connect();
      }
    }
    final generation = _generation;
    await (_preparing ??= _prepare(generation, _rpc).catchError((
      Object error,
      StackTrace stack,
    ) {
      if (generation == _generation) _failed(error, stack);
      throw error;
    }));
  }

  Future<void> _prepare(int generation, CodexRpcClient rpc) async {
    _health = const KernelHealth(KernelHealthStatus.starting);
    emitInfoChanged();
    await rpc.initialize();
    if (_disposed || _released || generation != _generation) return;
    // Fetching model metadata must not hold up the saved conversation.
    await Future.wait([
      _resumeThread(generation, rpc),
      _loadModels(generation, rpc),
      _loadConfig(generation, rpc),
    ]);
    if (_disposed || _released || generation != _generation) return;
    _health = KernelHealth.ready;
    emitInfoChanged();
    _takeNext();
  }

  Future<void> _loadModels(int generation, CodexRpcClient rpc) async {
    final models = await rpc.request('model/list', {'limit': 100});
    if (_disposed || _released || generation != _generation) return;
    final data = (models['data'] as List? ?? const []).whereType<Map>();
    _modelsById
      ..clear()
      ..addEntries([
        for (final raw in data)
          if (raw['model'] case final String id) MapEntry(id, raw),
      ]);
    effort.loadModels(data);
    model.options = [
      const KernelOption(
        'default',
        'CLI 默认',
        Icons.bolt_rounded,
        '使用 Codex CLI 的模型配置',
      ),
      for (final raw in data)
        if (raw['model'] is String)
          KernelOption(
            raw['model'] as String,
            raw['displayName'] as String? ?? raw['model'] as String,
            Icons.bolt_rounded,
            raw['description'] as String? ?? '',
          ),
    ];
    emitInfoChanged();
  }

  Future<Map> _readConfig() async {
    final result = await _request('config/read', {
      'includeLayers': false,
      if (_context.cwd != null) 'cwd': codexServerPath(_context.cwd),
    });
    return result['config'] as Map? ?? const {};
  }

  Future<void> _loadConfig(int generation, CodexRpcClient rpc) async {
    final result = await rpc.request('config/read', {
      'includeLayers': false,
      if (_context.cwd != null) 'cwd': codexServerPath(_context.cwd),
    });
    if (_disposed || _released || generation != _generation) return;
    _config = result['config'] as Map? ?? const {};
    effort.configure(_config);
  }

  Future<void> _resumeThread(int generation, CodexRpcClient rpc) async {
    if (_threadId case final id?) {
      final resumed = await rpc.request('thread/resume', {
        'threadId': id,
        'serviceTier': ?_serviceTierOverride,
        if (_context.cwd != null) 'cwd': codexServerPath(_context.cwd),
      });
      if (_disposed || _released || generation != _generation) return;
      _reportedModelProvider = resumed['modelProvider'] as String?;
      if (resumed.containsKey('serviceTier')) {
        _reportedServiceTier = resumed['serviceTier'] as String? ?? 'default';
      }
      if (!_historyLoaded) {
        _replay((resumed['thread'] as Map?) ?? const {});
        _historyLoaded = true;
      }
    }
  }

  void _failed(Object error, [StackTrace? stack]) {
    if (_disposed || _released) return;
    _health = KernelHealth(KernelHealthStatus.failed, message: '$error');
    emitInfoChanged();
    if (_turn case final turn?) {
      emit(
        ItemUpserted(
          nextSeq,
          'error:$turn',
          NoticeItem(NoticeKind.error, '$error'),
        ),
      );
      _endTurn(turn, interrupted: false);
    }
  }

  void _replay(Map thread) {
    final events = _replayEvents = <KernelEvent>[];
    _replaying = true;
    try {
      for (final raw in thread['turns'] as List? ?? const []) {
        final turn = raw as Map;
        final id = turn['id'] as String;
        emit(TurnStarted(nextSeq, id));
        for (final rawItem in turn['items'] as List? ?? const []) {
          final item = (rawItem as Map).cast<String, Object?>();
          if (item['type'] == 'userMessage') {
            final text = <String>[];
            for (final rawContent in item['content'] as List? ?? const []) {
              final content = rawContent as Map;
              if (content['type'] == 'text' &&
                  content['text'] is String &&
                  !(content['text'] as String).startsWith(
                    '<caocode_context>',
                  )) {
                text.add(content['text'] as String);
              }
            }
            emit(
              ItemUpserted(nextSeq, id, UserMessageItem(text: text.join('\n'))),
            );
          } else if (item['type'] == 'reasoning') {
            // A saved reasoning item has its final summary, but no recorded
            // duration. Replaying a start would time the replay itself.
            _itemCompleted(item);
          } else {
            _itemStarted(item);
            _itemCompleted(item);
          }
        }
        emit(
          TurnEnded(nextSeq, id, interrupted: turn['status'] == 'interrupted'),
        );
      }
    } finally {
      _replaying = false;
      _replayEvents = null;
    }
    if (events.isNotEmpty) {
      emit(HistoryReplayed(nextSeq, List.unmodifiable(events)));
    }
  }

  @override
  void emit(KernelEvent event) {
    final replay = _replayEvents;
    if (replay != null) {
      replay.add(event);
    } else {
      super.emit(event);
    }
  }

  @override
  List<KernelCommand> get commands => [
    KernelCommand(
      'fast',
      'Fast ${fastEnabled ? 'on' : 'off'} · /fast on 开启，/fast off 关闭',
      Icons.speed_rounded,
      argumentHint: '[on|off]',
    ),
    const KernelCommand(
      'review',
      'Review uncommitted changes',
      Icons.rate_review_outlined,
    ),
    const KernelCommand(
      'compact',
      'Summarize the conversation',
      Icons.compress_rounded,
    ),
    const KernelCommand(
      'init',
      'Write an AGENTS.md for this project',
      Icons.description_outlined,
    ),
    const KernelCommand('diff', 'Show the git diff', Icons.difference_outlined),
  ];

  @override
  int get contextWindow => 272000;

  String? _threadId;

  /// Ours, and the server's for the same turn once it says.
  String? _turn;
  String? _serverTurn;

  /// When [_turn] began, to time it.
  DateTime? _turnStarted;
  final Set<String> _sentTurns = {};

  final Map<String, int> _textLength = {};
  final Map<String, StringBuffer> _reasoning = {};
  final Map<String, Stopwatch> _reasoningClock = {};

  /// The part of each summary streaming in.
  final Map<String, int> _reasoningPart = {};
  final Map<String, DateTime> _startedAt = {};

  /// Commands started and not completed yet, as they started.
  final Map<String, Map<String, Object?>> _commands = {};

  /// Pending approvals: our request id → the server's JSON-RPC id.
  final Map<String, Object?> _approvals = {};
  final Map<String, List<String>> _questions = {};
  final Map<String, Map<String, Object?>> _permissions = {};

  // --- Commands -------------------------------------------------------------

  Future<Map<String, Object?>> _request(
    String method,
    Map<String, Object?> params,
  ) => _rpc.request(method, params);

  @override
  void send(KernelTurn turn) {
    if (_disposed) return;
    if (!_sentTurns.add(turn.id)) return;
    if (_turn != null || _serverTurn != null || _startingTurn) {
      if (turn.now) {
        _queue.insert(0, turn);
      } else {
        _queue.add(turn);
      }
      emit(
        ItemUpserted(
          nextSeq,
          turn.id,
          UserMessageItem(text: turn.text, images: turn.images, queued: true),
        ),
      );
      if (turn.now) cancel();
      return;
    }
    _begin(turn);
  }

  void _begin(KernelTurn turn) {
    _turn = turn.id;
    _turnStarted = DateTime.now();
    emit(TurnStarted(nextSeq, turn.id));
    emit(
      ItemUpserted(
        nextSeq,
        turn.id,
        UserMessageItem(text: turn.text, images: turn.images),
      ),
    );
    _startingTurn = true;
    unawaited(
      _start(turn)
          .catchError((Object error, StackTrace stack) {
            if (_turn == turn.id) _failed(error, stack);
          })
          .whenComplete(() {
            _startingTurn = false;
            _takeNext();
          }),
    );
  }

  void _takeNext() {
    if (_disposed ||
        _turn != null ||
        _serverTurn != null ||
        _startingTurn ||
        _health.status == KernelHealthStatus.failed ||
        _queue.isEmpty) {
      return;
    }
    _begin(_queue.removeAt(0));
  }

  @override
  Future<bool> cancelQueued(String turnId) async {
    final index = _queue.indexWhere((turn) => turn.id == turnId);
    if (index < 0) return false;
    _queue.removeAt(index);
    emit(ItemRemoved(nextSeq, turnId));
    return true;
  }

  @override
  void sendQueuedNow(String turnId) {
    final index = _queue.indexWhere((turn) => turn.id == turnId);
    if (index < 0) return;
    _queue.insert(0, _queue.removeAt(index));
    cancel();
    _takeNext();
  }

  Future<void> _start(KernelTurn turn) async {
    await _ready();
    // A toolbar choice made before Send must reach this turn. A rejected
    // change leaves the previous choice in place and does not fail the turn.
    await _fastChange?.catchError((Object _) {});
    if (_turn != turn.id || _disposed) return;
    if (RegExp(
      r'^/fast(?:\s|$)',
      caseSensitive: false,
    ).hasMatch(turn.text.trim())) {
      await _fastCommand(turn);
      return;
    }
    if (_threadId == null) {
      await (_openingThread ??= _openThread());
    }
    if (_turn != turn.id || _disposed) return;
    if (turn.text.trim() == '/compact') {
      await _request('thread/compact/start', {'threadId': _threadId});
      return;
    }
    final readOnly = ['/review', '/diff'].contains(turn.text.trim());
    if (!readOnly && permission.selected == 'custom') {
      _config = await _readConfig();
      effort.configure(_config);
      emitInfoChanged();
    }
    if (_turn != turn.id || _disposed) return;
    final started = await _request('turn/start', {
      'threadId': _threadId,
      'summary': 'auto',
      'input': [
        {
          'type': 'text',
          'text': switch (turn.text.trim()) {
            '/review' => 'Review the uncommitted changes in this project. Do not modify files.',
            '/diff' =>
              'Show and explain the uncommitted Git diff. Do not modify files.',
            '/init' =>
              'Inspect this project and write an appropriate AGENTS.md.',
            _ => turn.text,
          },
        },
        for (final note in turn.notes)
          {
            'type': 'text',
            'text': '<caocode_context>\n$note\n</caocode_context>',
          },
        for (final image in turn.images)
          {
            'type': 'image',
            'url':
                'data:${image.mediaType};base64,${base64Encode(image.bytes)}',
          },
      ],
      'model': ?effort.resolvedModel,
      'effort': ?effort.selected,
      'serviceTier': ?_serviceTierOverride,
      if (_context.cwd != null) 'cwd': codexServerPath(_context.cwd),
      ...readOnly
          ? {
              'approvalPolicy': 'never',
              'approvalsReviewer': 'user',
              'sandboxPolicy': {'type': 'readOnly'},
            }
          : codexPermissionParams(permission.selected, [
              if (_context.cwd != null) codexServerPath(_context.cwd)!,
              for (final path
                  in _context.workspace?.call()?.folders ?? const <String>[])
                codexServerPath(path)!,
            ], _config),
    });
    _serverTurn ??= (started['turn'] as Map)['id'] as String;
    // Stopped before the server knew the turn: stop it there too.
    if (_turn != turn.id) _interrupt();
  }

  Future<void> _fastCommand(KernelTurn turn) async {
    final parts = turn.text.trim().toLowerCase().split(RegExp(r'\s+'));
    var message =
        'Fast 当前${fastEnabled ? '已开启' : '已关闭'}。使用 /fast on 或 /fast off 切换。';
    var kind = NoticeKind.info;
    if (turn.images.isNotEmpty ||
        parts.length > 2 ||
        (parts.length == 2 && !{'on', 'off'}.contains(parts[1]))) {
      message = '用法：/fast on 开启，/fast off 关闭，/fast 查看状态。请单独发送命令。';
    } else if (parts.length == 2) {
      if (parts[1] == 'on' && !fastAvailable) {
        message = '当前模型或 CLI 配置不支持 Fast。';
        kind = NoticeKind.warning;
      } else {
        try {
          await _changeFastMode(parts[1] == 'on');
          if (_turn != turn.id || _disposed) return;
          message = fastEnabled
              ? 'Fast 已开启，从下一条消息生效。实际支持与计费由供应商决定。'
              : 'Fast 已关闭，后续消息使用标准速度。';
        } catch (error) {
          message = 'Fast 切换失败：$error';
          kind = NoticeKind.error;
        }
      }
    }
    if (_turn != turn.id || _disposed) return;
    emit(ItemUpserted(nextSeq, 'fast:${turn.id}', NoticeItem(kind, message)));
    _endTurn(turn.id, interrupted: false);
  }

  @override
  Future<void> setFastMode(bool enabled) async {
    if (_disposed || fastChanging) return;
    try {
      await _changeFastMode(enabled);
    } catch (error) {
      if (_disposed) return;
      final seq = nextSeq;
      emit(
        ItemUpserted(
          seq,
          'fast:setting:$seq',
          NoticeItem(NoticeKind.error, 'Fast 切换失败：$error'),
        ),
      );
    }
  }

  Future<void> _changeFastMode(bool enabled) async {
    final change = _applyFastMode(enabled);
    _fastChange = change;
    emitInfoChanged();
    try {
      await change;
    } finally {
      if (identical(_fastChange, change)) _fastChange = null;
      if (!_disposed) emitInfoChanged();
    }
  }

  Future<void> _applyFastMode(bool enabled) async {
    await _ready();
    if (_disposed) return;
    final tier = enabled ? _fastTier : 'default';
    if (tier == null) throw const CodexRpcException('当前模型或 CLI 配置不支持 Fast。');
    if (_threadId != null) {
      try {
        await _request('thread/settings/update', {
          'threadId': _threadId,
          'model': ?effort.resolvedModel,
          'effort': ?effort.selected,
          'serviceTier': tier,
        });
      } on CodexRpcException catch (error) {
        // Older servers can still apply the choice on turn/start.
        if (error.code != -32601) rethrow;
      }
    }
    if (_disposed) return;
    // The model picker can change while the server acknowledges the choice.
    // Resolve again so the next turn never inherits the previous model's tier.
    _serviceTierOverride = enabled ? _fastTier ?? 'default' : 'default';
  }

  Future<void> _openThread() async {
    try {
      final started = await _request('thread/start', {
        if (_context.cwd != null) 'cwd': codexServerPath(_context.cwd),
        'model': ?effort.resolvedModel,
        'serviceTier': ?_serviceTierOverride,
        if (_context.workspace?.call()?.instructions case final instructions?
            when instructions.isNotEmpty)
          'developerInstructions': instructions,
      });
      final thread = started['thread'] as Map;
      _threadId = thread['id'] as String;
      _reportedModelProvider = started['modelProvider'] as String?;
      if (started.containsKey('serviceTier')) {
        _reportedServiceTier = started['serviceTier'] as String? ?? 'default';
      }
      _historyLoaded = true;
      CodexCatalog.remember(
        _threadId!,
        _context.cwd ?? thread['cwd'] as String?,
      );
      if (_pendingName case final name?) {
        await _request('thread/name/set', {
          'threadId': _threadId,
          'name': name,
        });
        _pendingName = null;
      }
      emitInfoChanged();
    } finally {
      _openingThread = null;
    }
  }

  void _interrupt() {
    final generation = _generation;
    final serverTurn = _serverTurn;
    if (serverTurn == null || _threadId == null) return;
    unawaited(
      _request('turn/interrupt', {
        'threadId': _threadId,
        'turnId': serverTurn,
      }).catchError((Object error) {
        if (generation == _generation) _failed(error);
        return <String, Object?>{};
      }),
    );
  }

  @override
  void answer(String requestId, InteractionAnswer answer) {
    if (!_approvals.containsKey(requestId)) return;
    final rpcId = _approvals.remove(requestId);
    emit(InteractionResolved(nextSeq, requestId));
    if (_questions.remove(requestId) case final keys?) {
      final picks = answer is QuestionAnswer && !answer.skipped
          ? answer.picks
          : const <List<String>>[];
      _transport.write({
        'id': rpcId,
        'result': {
          'answers': {
            for (final (index, key) in keys.indexed)
              key: {
                'answers': index < picks.length ? picks[index] : <String>[],
              },
          },
        },
      });
      return;
    }
    if (_permissions.remove(requestId) case final permissions?) {
      final allowed =
          answer is ApprovalAnswer && answer.decision != ApprovalDecision.deny;
      _transport.write({
        'id': rpcId,
        'result': {
          'permissions': allowed ? permissions : <String, Object?>{},
          'scope':
              answer is ApprovalAnswer &&
                  answer.decision == ApprovalDecision.allowAlways
              ? 'session'
              : 'turn',
        },
      });
      return;
    }
    final decision = switch (answer) {
      ApprovalAnswer(decision: ApprovalDecision.allowOnce) => 'accept',
      ApprovalAnswer(decision: ApprovalDecision.allowAlways) =>
        'acceptForSession',
      _ => 'decline',
    };
    _transport.write({
      'id': rpcId,
      'result': {'decision': decision},
    });
  }

  @override
  void rename(String title) {
    _pendingName = title;
    if (_threadId == null) return;
    unawaited(() async {
      try {
        await _ready();
        await _request('thread/name/set', {
          'threadId': _threadId,
          'name': title,
        });
        if (_pendingName == title) _pendingName = null;
      } on Object catch (error) {
        if (!_disposed) {
          emit(
            ItemUpserted(
              nextSeq,
              'rename-error',
              NoticeItem(NoticeKind.error, '无法重命名会话：$error'),
            ),
          );
        }
      }
    }());
  }

  @override
  void cancel() {
    final turn = _turn;
    if (turn == null) return;
    _interrupt();
    _endTurn(turn, interrupted: true);
  }

  @override
  Future<bool> rewind({
    required String itemId,
    required int index,
    required int turns,
    String? lastSeen,
  }) async {
    if (_threadId case final threadId? when turns > 0) {
      try {
        await _ready();
        await _request('thread/rollback', {
          'threadId': threadId,
          'numTurns': turns,
        });
      } on Object catch (error) {
        emit(
          ItemUpserted(
            nextSeq,
            'rewind-error',
            NoticeItem(NoticeKind.error, '无法回退会话：$error'),
          ),
        );
        return false;
      }
    }
    emit(Rewound(nextSeq, itemId: itemId, index: index));
    return true;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(_subscription.cancel());
    _rpc.close();
    _shutdown = _rpc.stopped;
    closeEvents();
  }

  // --- Translation ------------------------------------------------------------

  void _receive(Map<String, Object?> message) {
    final method = message['method'] as String?;
    final params = (message['params'] as Map?)?.cast<String, Object?>();
    if (method == null) {
      return;
    }
    if (params?['threadId'] case final String threadId
        when _threadId != null && threadId != _threadId) {
      return;
    }
    if (message.containsKey('id')) {
      _serverRequest(message['id'], method, params ?? const {});
      return;
    }
    switch (method) {
      case 'turn/started':
        _serverTurn = (params!['turn'] as Map)['id'] as String;
        if (_turn == null) _interrupt();
      case 'turn/completed':
        final turn = params!['turn'] as Map;
        if (turn['id'] != _serverTurn) return;
        _serverTurn = null;
        if (_turn case final ours?) {
          if (turn['status'] == 'failed') {
            final error = turn['error'] as Map?;
            emit(
              ItemUpserted(
                nextSeq,
                'error:$ours',
                NoticeItem(
                  NoticeKind.error,
                  error?['message'] as String? ?? 'Codex 回合执行失败',
                ),
              ),
            );
          }
          _endTurn(ours, interrupted: turn['status'] == 'interrupted');
        }
        _takeNext();
      case 'error':
        if (params?['willRetry'] != true) {
          _failed(
            CodexRpcException(
              (params?['error'] as Map?)?['message'] as String? ??
                  'Codex CLI 执行失败',
            ),
          );
        }
      case 'serverRequest/resolved':
        final rpcId = params?['requestId'];
        for (final id
            in _approvals.keys
                .where((id) => _approvals[id] == rpcId)
                .toList()) {
          _approvals.remove(id);
          _questions.remove(id);
          _permissions.remove(id);
          emit(InteractionResolved(nextSeq, id));
        }
      case 'item/commandExecution/outputDelta':
        final id = params?['itemId'] as String?;
        final command = _commands[id];
        if (command != null) {
          final updated = {
            ...command,
            'aggregatedOutput':
                '${command['aggregatedOutput'] ?? ''}${params?['delta'] ?? ''}',
          };
          _commands[id!] = updated;
          emit(ItemUpserted(nextSeq, id, _commandItem(updated)));
        }
      case 'item/started':
        _itemStarted((params!['item'] as Map).cast<String, Object?>());
      case 'item/completed':
        final item = (params!['item'] as Map).cast<String, Object?>();
        _itemCompleted(item);
        if (item['type'] == 'contextCompaction' &&
            _serverTurn == null &&
            _turn != null) {
          _endTurn(_turn!, interrupted: false);
          _takeNext();
        }
      case 'thread/compacted':
        if (_serverTurn == null && _turn != null) {
          _endTurn(_turn!, interrupted: false);
          _takeNext();
        }
      case 'item/reasoning/summaryTextDelta':
        final id = params!['itemId'] as String;
        final buffer = _reasoning[id];
        if (buffer == null) return;
        // Each part of the summary (its own bold title and text) apart from
        // the one before.
        final part = params['summaryIndex'] as int?;
        final separate =
            part != null && buffer.isNotEmpty && part != _reasoningPart[id];
        if (part != null) _reasoningPart[id] = part;
        final delta = '${separate ? '\n\n' : ''}${params['delta'] as String}';
        final offset = buffer.length;
        buffer.write(delta);
        emit(TextDelta(nextSeq, id, offset, delta, tokens: buffer.length));
      case 'item/agentMessage/delta':
        final id = params!['itemId'] as String;
        final offset = _textLength[id];
        if (offset == null) return;
        final delta = params['delta'] as String;
        _textLength[id] = offset + delta.length;
        emit(TextDelta(nextSeq, id, offset, delta));
      case 'thread/tokenUsage/updated':
        final usage = params!['tokenUsage'] as Map;
        emit(
          UsageReported(
            nextSeq,
            ContextUsage(
              window: usage['modelContextWindow'] as int? ?? contextWindow,
              // The last request's, which is what the context holds; the
              // total adds up every request, and never drops on compacting.
              used: (usage['last'] as Map)['totalTokens'] as int,
            ),
          ),
        );
    }
  }

  void _serverRequest(
    Object? rpcId,
    String method,
    Map<String, Object?> params,
  ) {
    if (method == 'item/tool/requestUserInput') {
      final id = 'question:$rpcId';
      final questions = [
        for (final raw in params['questions'] as List? ?? const [])
          (raw as Map).cast<String, Object?>(),
      ];
      _approvals[id] = rpcId;
      _questions[id] = [
        for (final question in questions) question['id'] as String,
      ];
      emit(
        InteractionRequested(
          nextSeq,
          QuestionRequest(
            id: id,
            title: 'Codex 需要你的选择',
            questions: [
              for (final question in questions)
                Question(
                  prompt: question['question'] as String,
                  header: question['header'] as String? ?? '',
                  allowOther: question['isOther'] as bool? ?? true,
                  options: [
                    for (final raw in question['options'] as List? ?? const [])
                      QuestionOption(
                        (raw as Map)['label'] as String,
                        description: raw['description'] as String? ?? '',
                      ),
                  ],
                ),
            ],
          ),
        ),
      );
      return;
    }
    if (method == 'item/permissions/requestApproval') {
      final id = 'permission:$rpcId';
      _approvals[id] = rpcId;
      _permissions[id] =
          (params['permissions'] as Map?)?.cast<String, Object?>() ?? {};
      emit(
        InteractionRequested(
          nextSeq,
          ApprovalRequest(
            id: id,
            toolName: 'permissions',
            title: 'Codex 请求权限',
            reason: params['reason'] as String?,
            preview: CommandPreview(jsonEncode(params['permissions'])),
            alwaysAllowLabel: '本次会话允许',
          ),
        ),
      );
      return;
    }
    final (title, preview) = switch (method) {
      'item/commandExecution/requestApproval' => (
        'Run command',
        CommandPreview('${params['command']}') as ApprovalPreview?,
      ),
      'item/fileChange/requestApproval' => ('Apply changes', null),
      _ => (null, null),
    };
    if (title == null) {
      _transport.write({
        'id': rpcId,
        'error': {'code': -32601, 'message': 'Caocode 尚未支持此请求：$method'},
      });
      return;
    }
    final id = 'approval:$rpcId';
    _approvals[id] = rpcId;
    emit(
      InteractionRequested(
        nextSeq,
        ApprovalRequest(
          id: id,
          title: title,
          toolName: method.split('/')[1],
          reason: params['reason'] as String?,
          preview: preview,
          alwaysAllowLabel: 'Approve for this session',
        ),
      ),
    );
  }

  void _itemStarted(Map<String, Object?> item) {
    final id = item['id'] as String;
    switch (item['type']) {
      case 'reasoning':
        _reasoning[id] = StringBuffer();
        _reasoningClock[id] = Stopwatch()..start();
        emit(
          ItemUpserted(
            nextSeq,
            id,
            ThinkingItem(
              text: '',
              tokens: 0,
              startedAt: DateTime.now(),
              summarized: true,
            ),
            streaming: true,
          ),
        );
      case 'agentMessage':
        _textLength[id] = 0;
        emit(
          ItemUpserted(
            nextSeq,
            id,
            const AssistantTextItem(''),
            streaming: true,
          ),
        );
      case 'commandExecution':
        _startedAt[id] = DateTime.now();
        _commands[id] = item;
        emit(ItemUpserted(nextSeq, id, _commandItem(item)));
    }
  }

  void _itemCompleted(Map<String, Object?> item) {
    final id = item['id'] as String;
    switch (item['type']) {
      case 'reasoning':
        final buffer = _reasoning.remove(id);
        final clock = _reasoningClock.remove(id)?..stop();
        _reasoningPart.remove(id);
        // Completed items are authoritative. An empty streaming buffer must
        // not overwrite a restored summary; interrupted items can still use
        // what arrived before the completion notification was lost.
        final summary = item['summary'];
        final text = summary is List
            ? summary.whereType<String>().join('\n\n')
            : buffer?.toString() ?? '';
        if (text.trim().isEmpty) {
          emit(ItemRemoved(nextSeq, id));
          break;
        }
        emit(
          ItemCompleted(
            nextSeq,
            id,
            item: ThinkingItem(
              text: text,
              tokens: text.length,
              seconds: clock == null
                  ? null
                  : (clock.elapsedMilliseconds / 1000).round(),
              streaming: false,
              summarized: true,
            ),
          ),
        );
      case 'agentMessage':
        _textLength.remove(id);
        emit(
          ItemCompleted(
            nextSeq,
            id,
            item: AssistantTextItem(item['text'] as String),
          ),
        );
      case 'commandExecution':
        emit(ItemUpserted(nextSeq, id, _commandItem(item)));
        _startedAt.remove(id);
        _commands.remove(id);
      case 'fileChange':
        final changes = item['changes'] as List<Object?>;
        for (final (index, raw) in changes.indexed) {
          final change = raw as Map;
          _fileChange(
            '$id:$index',
            change['path'] as String,
            change['diff'] as String,
            kind: (change['kind'] as Map?)?['type'] as String?,
          );
        }
    }
  }

  /// A command as the history shows it: reads and searches as tool rows,
  /// anything else as a terminal.
  ChatItem _commandItem(Map<String, Object?> item) {
    final actions = [
      for (final action in item['commandActions'] as List<Object?>? ?? const [])
        (action as Map).cast<String, Object?>(),
    ];
    final output = item['aggregatedOutput'] as String?;
    final done = ['completed', 'failed', 'declined'].contains(item['status']);
    if (actions.isNotEmpty && actions.every((a) => a['type'] == 'read')) {
      final path = codexClientPath(
        actions.first['path'] as String,
        _context.cwd,
      );
      return ToolCallItem(
        kind: ToolKind.read,
        target: path.split('/').last,
        path: path,
      );
    }
    if (actions.isNotEmpty && actions.every((a) => a['type'] == 'search')) {
      final matches = [
        for (final line in (output ?? '').split('\n'))
          if (line.isNotEmpty) line.split(':').take(2).join(':'),
      ];
      return ToolCallItem(
        kind: ToolKind.grep,
        target: actions.first['query'] as String,
        detail: done ? '${matches.length} results' : null,
        results: matches,
      );
    }
    return TerminalItem(
      command: item['command'] as String,
      output: output ?? '',
      status: !done
          ? CommandStatus.running
          : item['exitCode'] == 0
          ? CommandStatus.succeeded
          : CommandStatus.failed,
      startedAt: _startedAt[item['id']],
    );
  }

  /// A unified diff as a diff card and a pending change. A file added or
  /// deleted ([kind]) has its whole text for a diff.
  void _fileChange(String id, String path, String diff, {String? kind}) {
    final lines = <DiffLine>[];
    var added = 0;
    var removed = 0;
    var oldLine = 1;
    var newLine = 1;
    final hunk = RegExp(r'^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@');
    for (final line in diff.split('\n')) {
      if (line.startsWith('+++ ') ||
          line.startsWith('--- ') ||
          line.startsWith('diff ') ||
          line.startsWith('index ') ||
          line.startsWith('\\ No newline')) {
        continue;
      }
      if (hunk.firstMatch(line) case final match?) {
        oldLine = int.parse(match.group(1)!);
        newLine = int.parse(match.group(2)!);
        continue;
      }
      if (line.isEmpty) continue;
      final text = line.substring(1);
      switch (line[0]) {
        case '+':
          lines.add(DiffLine(DiffLineType.added, newLine++, text));
          added++;
        case '-':
          lines.add(DiffLine(DiffLineType.removed, oldLine++, text));
          removed++;
        default:
          lines.add(DiffLine(DiffLineType.context, newLine++, text));
          oldLine++;
      }
    }
    final displayPath = codexClientPath(
      path,
      _context.cwd,
    ).replaceAll('\\', '/');
    final slash = displayPath.lastIndexOf('/');
    emit(
      ItemUpserted(
        nextSeq,
        id,
        CodeDiffItem(
          fileName: displayPath.substring(slash + 1),
          directory: slash < 0 ? '' : displayPath.substring(0, slash),
          lines: lines,
        ),
      ),
    );
    if (!_replaying) {
      emit(
        FileEdited(
          nextSeq,
          FileChange(
            path: codexClientPath(path, _context.cwd),
            added: added,
            removed: removed,
          ),
          turnId: _turn,
          original: switch (kind) {
            'add' => const OriginalText(null),
            'delete' => OriginalText(diff),
            _ => OriginalByPatch(diff),
          },
        ),
      );
    }
  }

  void _endTurn(String turn, {required bool interrupted}) {
    _turn = null;
    for (final id in [..._reasoning.keys]) {
      _itemCompleted({'type': 'reasoning', 'id': id});
    }
    for (final id in [..._textLength.keys]) {
      _textLength.remove(id);
      emit(ItemCompleted(nextSeq, id));
    }
    // A command stopped with its turn: it will not report its end.
    for (final item in [..._commands.values]) {
      _itemCompleted({...item, 'status': 'failed'});
    }
    for (final id in _approvals.keys) {
      emit(InteractionResolved(nextSeq, id));
    }
    _approvals.clear();
    _questions.clear();
    _permissions.clear();
    emit(
      TurnEnded(
        nextSeq,
        turn,
        interrupted: interrupted,
        worked: switch (_turnStarted) {
          final started? => DateTime.now().difference(started),
          null => null,
        },
      ),
    );
  }
}
