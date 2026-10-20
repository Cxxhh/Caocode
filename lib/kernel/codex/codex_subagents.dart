part of 'codex_kernel.dart';

/// Owns the delegated thread tree. Reading a child never resumes it or starts
/// another writer. Notifications are immediate; the visible child's persisted
/// history is refreshed while it runs, including on CLIs that don't forward
/// all descendant deltas to the parent's connection.
class _CodexSubagents {
  _CodexSubagents(this.owner);
  final CodexKernel owner;
  final Map<String, _CodexChild> children = {};
  final Map<String, InteractionRequest> requests = {};
  String? viewed;
  Timer? _poll;
  bool _disposed = false;
  bool get hasRunning => children.values.any(
    (child) => child.item.status == CommandStatus.running,
  );

  SubagentHistoryState history(String id) =>
      children[id]?.history ?? const SubagentHistoryState();

  void view(String? id) {
    viewed = id;
    _poll?.cancel();
    if (id == null || !children.containsKey(id) || _disposed) return;
    unawaited(refresh(id));
    _schedule();
  }

  void _schedule() {
    _poll?.cancel();
    final current = children[viewed];
    if (_disposed ||
        owner._released ||
        current == null ||
        current.item.status != CommandStatus.running ||
        current.error != null) {
      return;
    }
    _poll = Timer(const Duration(seconds: 2), () async {
      final child = children[viewed];
      if (child != null &&
          child.item.status == CommandStatus.running &&
          child.error == null) {
        await refresh(child.id, quiet: true);
      }
      _schedule();
    });
  }

  void suspend() => _poll?.cancel();
  void resume() {
    if (viewed != null) view(viewed);
  }

  _CodexChild? _ensure(String id, String? parent) {
    if (id == owner._threadId ||
        parent == null ||
        (parent != owner._threadId && !children.containsKey(parent))) {
      return null;
    }
    final existing = children[id];
    if (existing != null) return existing;
    final child = _CodexChild(id, parent, this);
    children[id] = child;
    return child;
  }

  void started(Map thread) {
    final source = thread['source'];
    if (source is! Map) return;
    final sub = source['subAgent'] ?? source['sub_agent'];
    final spawn = sub is Map
        ? (sub['thread_spawn'] ?? sub['threadSpawn']) as Map?
        : null;
    final parent = spawn?['parent_thread_id'] ?? spawn?['parentThreadId'];
    final id = thread['id'];
    if (id is! String || parent is! String) return;
    final child = _ensure(id, parent);
    if (child == null) return;
    _metadata(child, thread);
    publish(child);
  }

  void _metadata(_CodexChild child, Map thread) {
    child.item = child.item.copyWith(
      description:
          thread['agentNickname'] as String? ?? thread['name'] as String?,
      agentType: thread['agentRole'] as String?,
    );
  }

  void activity(Map item, String? sender) {
    final id = item['agentThreadId'];
    if (id is! String) return;
    final child = children[id] ?? _ensure(id, sender);
    if (child == null) return;
    child.item = child.item.copyWith(
      description: item['agentPath'] as String?,
      model: item['model'] as String?,
    );
    if (item['kind'] == 'started' || item['kind'] == 'interacted') {
      _status(child, 'running');
    }
    if (item['kind'] == 'interrupted') _status(child, 'interrupted');
    if (item['kind'] == 'completed') _status(child, 'completed');
    publish(child);
    if (viewed == id && item['kind'] == 'completed') unawaited(refresh(id));
  }

  void tool(Map item, String? sender) {
    final tool = item['tool'];
    final parent = item['senderThreadId'] as String? ?? sender;
    final receivers = <String>{
      ...?(item['receiverThreadIds'] as List?)?.whereType<String>(),
      if (item['newThreadId'] case final String id) id,
      if (item['receiverThreadId'] case final String id) id,
      ...?(item['agentsStates'] as Map?)?.keys.whereType<String>(),
    };
    for (final id in receivers) {
      final child =
          children[id] ?? (tool == 'spawnAgent' ? _ensure(id, parent) : null);
      if (child == null) continue;
      final state = (item['agentsStates'] as Map?)?[id] as Map?;
      final legacyState = item['agentStatus'];
      final status =
          state?['status'] ?? (legacyState is String ? legacyState : null);
      child.item = child.item.copyWith(
        prompt: tool == 'spawnAgent' ? item['prompt'] as String? : null,
        model: item['model'] as String?,
      );
      // Completion of spawn/send/wait is completion of the tool call, not of
      // the agent. Only an agent state can finish its card.
      if (status is String) {
        _status(child, status, state?['message'] as String?);
      }
      publish(child);
    }
  }

  void _status(_CodexChild child, String state, [String? message]) {
    child.revision++;
    final status = switch (state) {
      'completed' => CommandStatus.succeeded,
      'shutdown' when child.item.status == CommandStatus.succeeded =>
        CommandStatus.succeeded,
      'errored' ||
      'interrupted' ||
      'shutdown' ||
      'notFound' => CommandStatus.failed,
      _ => CommandStatus.running,
    };
    child.item = child.item.copyWith(
      status: status,
      result: status == CommandStatus.running
          ? ''
          : state == 'completed' && child.renderer.transcript.length == 0
          ? message
          : null,
    );
  }

  void receive(Map<String, Object?> message, String id) {
    final child = children[id];
    if (child == null || _disposed) {
      if (message.containsKey('id')) {
        owner._transport.write({
          'id': message['id'],
          'error': {'code': -32601, 'message': '未知子线程，无法处理交互请求'},
        });
      }
      return;
    }
    final method = message['method'];
    final params =
        (message['params'] as Map?)?.cast<String, Object?>() ??
        const <String, Object?>{};
    if (message.containsKey('id')) {
      final prefix = switch (method) {
        'item/tool/requestUserInput' => 'question',
        'item/permissions/requestApproval' => 'permission',
        _ => 'approval',
      };
      final requestId = '$prefix:${message['id']}';
      owner._approvalThreads[requestId] = id;
      owner._serverRequest(
        message['id'],
        method as String,
        params,
        agent: child.item.description,
      );
      return;
    }
    switch (method) {
      case 'turn/started':
        child.item = child.item.copyWith(
          status: CommandStatus.running,
          result: '',
        );
      case 'turn/completed':
        final turn = params['turn'] as Map;
        _status(
          child,
          turn['status'] == 'failed' ? 'errored' : turn['status'] as String,
        );
        resolveRequests(id);
      case 'thread/status/changed':
        final status = params['status'] as Map?;
        if (status?['type'] == 'active') _status(child, 'running');
        if (status?['type'] == 'systemError') _status(child, 'errored');
      case 'serverRequest/resolved':
        final rpcId = params['requestId'];
        for (final requestId
            in owner._approvals.keys
                .where((key) => owner._approvals[key] == rpcId)
                .toList()) {
          owner._approvals.remove(requestId);
          owner._approvalThreads.remove(requestId);
          owner._questions.remove(requestId);
          owner._permissions.remove(requestId);
          owner.emit(InteractionResolved(owner.nextSeq, requestId));
        }
      case 'item/started':
        child.renderer._itemStarted(
          (params['item'] as Map).cast<String, Object?>(),
        );
      case 'item/completed':
        child.renderer._itemCompleted(
          (params['item'] as Map).cast<String, Object?>(),
        );
      case 'item/agentMessage/delta':
      case 'item/reasoning/summaryTextDelta':
      case 'item/commandExecution/outputDelta':
        child.renderer._receive(message);
    }
    child.revision++;
    publish(child);
  }

  void interaction(KernelEvent event) {
    if (event case InteractionRequested(:final request)
        when owner._approvalThreads.containsKey(request.id)) {
      requests[request.id] = request;
    } else if (event case InteractionResolved(:final requestId)) {
      requests.remove(requestId);
    }
  }

  void resolveRequests(String thread) {
    for (final id
        in owner._approvalThreads.keys
            .where((key) => owner._approvalThreads[key] == thread)
            .toList()) {
      owner._approvals.remove(id);
      owner._questions.remove(id);
      owner._permissions.remove(id);
      owner._approvalThreads.remove(id);
      owner.emit(InteractionResolved(owner.nextSeq, id));
    }
  }

  void restoreRequests() {
    for (final request in requests.values.toList()) {
      owner.emit(InteractionRequested(owner.nextSeq, request));
    }
  }

  Future<void> refresh(
    String id, {
    bool earlier = false,
    bool quiet = false,
  }) async {
    final child = children[id];
    if (child == null || child.loading || _disposed || owner._released) return;
    child.loading = true;
    child.error = null;
    if (!quiet) owner.emitInfoChanged();
    final generation = owner._generation;
    final revision = child.revision;
    try {
      final read = await owner._request('thread/read', {
        'threadId': id,
        'includeTurns': false,
      });
      if (_disposed || generation != owner._generation) return;
      final thread = read['thread'] as Map;
      _metadata(child, thread);
      List<Map> turns;
      String? cursor;
      try {
        final page = await owner._request('thread/turns/list', {
          'threadId': id,
          'limit': 30,
          'sortDirection': 'desc',
          'itemsView': 'full',
          if (earlier) 'cursor': child.cursor,
        });
        if (_disposed || generation != owner._generation) return;
        turns = (page['data'] as List)
            .whereType<Map>()
            .toList()
            .reversed
            .toList();
        cursor = page['nextCursor'] as String?;
      } on CodexRpcException catch (error) {
        if (error.code != -32601) rethrow;
        final full = await owner._request('thread/read', {
          'threadId': id,
          'includeTurns': true,
        });
        if (_disposed || generation != owner._generation) return;
        turns = ((full['thread'] as Map)['turns'] as List? ?? const [])
            .whereType<Map>()
            .toList();
      }
      // A newer notification wins over a read begun before it. It will be
      // reconciled at the next visible refresh, never appended twice.
      if (revision == child.revision) {
        if (earlier || !child.loadedEarlier) child.cursor = cursor;
        if (earlier) child.loadedEarlier = true;
        if (earlier) {
          final newer = Map<String, Map>.of(child.turns);
          child.turns.clear();
          for (final turn in turns) {
            child.turns[turn['id'] as String] = turn;
          }
          child.turns.addAll(newer);
        } else {
          for (final turn in turns) {
            child.turns[turn['id'] as String] = turn;
          }
        }
        child.renderer.hydrate(child.turns.values.toList());
        final status = (thread['status'] as Map?)?['type'];
        if (status == 'active') {
          _status(child, 'running');
        } else if (turns.isNotEmpty) {
          _status(
            child,
            turns.last['status'] == 'failed'
                ? 'errored'
                : turns.last['status'] == 'inProgress'
                ? 'running'
                : turns.last['status'] as String,
          );
        }
        if (status != 'active' && child.item.status != CommandStatus.running) {
          resolveRequests(id);
        }
      }
      publish(child);
    } on Object catch (error) {
      if (!_disposed && generation == owner._generation) child.error = '$error';
    } finally {
      child.loading = false;
      if (!_disposed) {
        owner.emitInfoChanged();
        if (viewed == id) _schedule();
      }
    }
  }

  void publish(_CodexChild child) {
    if (_disposed) return;
    var root = child;
    while (children.containsKey(root.parent)) {
      root = children[root.parent]!;
    }
    AgentItem build(_CodexChild current) {
      final transcript = current.renderer.transcript;
      final own = transcript.liveItems.map((entry) => entry.$2).toList();
      return current.item.copyWith(
        prompt: own.any((item) => item is UserMessageItem)
            ? ''
            : current.item.prompt,
        children: [
          ...own,
          for (final nested in children.values.where(
            (entry) => entry.parent == current.id,
          ))
            build(nested),
        ],
        result: own.isEmpty ? current.item.result : '',
        toolUses: own
            .where((item) => item is ToolCallItem || item is TerminalItem)
            .length,
      );
    }

    owner.emit(
      ItemUpserted(owner.nextSeq, 'codex-agent:${root.id}', build(root)),
    );
  }

  void dispose() {
    _disposed = true;
    _poll?.cancel();
    for (final child in children.values) {
      child.renderer.dispose();
    }
  }
}

class _CodexChild {
  _CodexChild(this.id, this.parent, this.registry)
    : item = AgentItem(
        id: id,
        description: 'Codex · ${id.substring(0, id.length.clamp(0, 8))}',
      ) {
    renderer = _CodexChildRenderer(this);
  }
  final String id;
  final String parent;
  final _CodexSubagents registry;
  late final _CodexChildRenderer renderer;
  AgentItem item;
  final Map<String, Map> turns = {};
  bool loading = false;
  bool loadedEarlier = false;
  String? error;
  String? cursor;
  int revision = 0;
  SubagentHistoryState get history => SubagentHistoryState(
    loading: loading,
    error: error,
    hasEarlier: cursor != null,
  );
}

/// Reuses the Codex item translator with an inert transport: no process,
/// initialization, resume, turn/start, settings writes or permissions changes.
class _CodexChildRenderer extends CodexKernel {
  _CodexChildRenderer(this.child)
    : super(
        child.registry.owner.descriptor,
        const _CodexReadOnlyTransport(),
        context: KernelContext(cwd: child.registry.owner._context.cwd),
      ) {
    _threadId = child.id;
    _listener = events.listen((event) {
      transcript.apply(event);
    });
  }
  final _CodexChild child;
  Transcript transcript = Transcript();
  late final StreamSubscription<KernelEvent> _listener;

  @override
  void _itemStarted(Map<String, Object?> item) {
    if (item['type'] == 'subAgentActivity') {
      child.registry.activity(item, child.id);
    } else if ({
      'collabAgentToolCall',
      'collabToolCall',
    }.contains(item['type'])) {
      child.registry.tool(item, child.id);
    } else {
      super._itemStarted(item);
    }
  }

  @override
  void _itemCompleted(Map<String, Object?> item) {
    if (item['type'] == 'subAgentActivity') {
      child.registry.activity(item, child.id);
    } else if ({
      'collabAgentToolCall',
      'collabToolCall',
    }.contains(item['type'])) {
      child.registry.tool(item, child.id);
    } else if (item['type'] == 'userMessage') {
      final text = (item['content'] as List? ?? const [])
          .whereType<Map>()
          .where((content) => content['type'] == 'text')
          .map((content) => content['text'])
          .join('\n');
      emit(
        ItemUpserted(
          nextSeq,
          item['id'] as String,
          UserMessageItem(text: text),
        ),
      );
    } else {
      super._itemCompleted(item);
    }
  }

  void hydrate(List<Map> turns) {
    transcript = Transcript();
    _textLength.clear();
    _reasoning.clear();
    _commands.clear();
    for (final clock in _reasoningClock.values) {
      clock.stop();
    }
    _reasoningClock.clear();
    _reasoningPart.clear();
    _startedAt.clear();
    for (final turn in turns) {
      for (final raw in turn['items'] as List? ?? const []) {
        final item = (raw as Map).cast<String, Object?>();
        _itemCompleted(item);
        if (turn['status'] == 'inProgress') {
          final id = item['id'] as String;
          if (item['type'] == 'commandExecution' &&
              item['status'] == 'inProgress') {
            _commands[id] = item;
          }
          if (item['type'] == 'reasoning') {
            _reasoning[id] = StringBuffer(
              (item['summary'] as List? ?? const []).join('\n\n'),
            );
          }
        }
      }
    }
    // Text snapshots may still be in progress; subsequent deltas append from
    // that snapshot's length, using the same translator as the main thread.
    for (final (id, item) in transcript.liveItems) {
      if (item is AssistantTextItem) _textLength[id] = item.text.length;
    }
  }

  @override
  void dispose() {
    unawaited(_listener.cancel());
    super.dispose();
  }
}

class _CodexReadOnlyTransport implements CodexTransport {
  const _CodexReadOnlyTransport();
  @override
  Stream<Map<String, Object?>> get messages => const Stream.empty();
  @override
  void write(Map<String, Object?> message) => throw StateError('子代理查看不能发送请求');
  @override
  void close() {}
}
