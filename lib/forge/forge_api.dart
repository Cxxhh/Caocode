// What Caocode asks a forge, signed in as the user (see forge_accounts):
// GitHub's REST API (api.github.com, a GitHub Enterprise's /api/v3) and
// GitLab's (/api/v4). Over [ForgeHttp], which tests answer themselves.

import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'forge_ref.dart';

/// A response: its status and its body, as text.
@immutable
class ForgeResponse {
  const ForgeResponse(this.status, this.body);

  final int status;
  final String body;

  bool get ok => status >= 200 && status < 300;

  Object? get json => body.isEmpty ? null : jsonDecode(body);
}

/// Sends a request: [form] as a form, else [json] as JSON. Throws
/// [ForgeException] when there is no answer.
abstract interface class ForgeHttp {
  Future<ForgeResponse> send(
    String method,
    Uri url, {
    Map<String, String> headers = const {},
    Object? json,
    Map<String, String>? form,
  });
}

/// A forge did not do what was asked: no answer ([status] null), a token
/// it does not take (401), something not there or not to be seen (404).
class ForgeException implements Exception {
  const ForgeException(this.message, {this.status});

  final String message;
  final int? status;

  bool get unauthorized => status == 401;

  @override
  String toString() => message;
}

/// The message in a forge's error response, if it has one.
String? forgeErrorMessage(ForgeResponse response) {
  try {
    return switch (response.json) {
      {'error_description': final String message} => message,
      {'message': final String message} => message,
      {'error': final String message} => message,
      _ => null,
    };
  } on FormatException {
    return null;
  }
}

/// Where an issue or pull request is.
enum ForgeState {
  open,

  /// A pull request not ready for review yet.
  draft,
  closed,

  /// A pull request merged.
  merged;

  static ForgeState? parse(Object? value) =>
      values.where((state) => state.name == value).firstOrNull;

  bool get isOpen => this == open || this == draft;
}

/// How a pull request's checks (CI) went, all of them together.
enum ForgeChecks {
  pending,
  success,
  failure;

  static ForgeChecks? parse(Object? value) =>
      values.where((checks) => checks.name == value).firstOrNull;
}

@immutable
class ForgeLabel {
  const ForgeLabel(this.name, {this.color});

  final String name;

  /// `#rrggbb`, when the forge said.
  final String? color;

  @override
  bool operator ==(Object other) =>
      other is ForgeLabel && other.name == name && other.color == color;

  @override
  int get hashCode => Object.hash(name, color);
}

/// An issue or pull request as the forge has it now.
@immutable
class ForgeItem {
  const ForgeItem({
    required this.ref,
    required this.title,
    required this.state,
    this.body = '',
    this.author,
    this.labels = const [],
    this.assignees = const [],
    this.comments = 0,
    this.updated,
    this.checks,
    this.branch,
  });

  final ForgeRef ref;
  final String title;
  final ForgeState state;

  /// Its description, as Markdown.
  final String body;
  final String? author;
  final List<ForgeLabel> labels;
  final List<String> assignees;
  final int comments;
  final DateTime? updated;

  /// A pull request's, when it has any.
  final ForgeChecks? checks;

  /// A pull request's branch.
  final String? branch;
}

/// Whose issues a list is of.
enum ForgeIssueFilter { assigned, created, all }

/// Who the token is of.
@immutable
class ForgeUser {
  const ForgeUser({required this.login, this.name});

  final String login;
  final String? name;
}

/// A forge's API, signed in.
abstract class ForgeApi {
  ForgeApi({required this.host, required this.http, required this.token});

  /// The forge's host (`github.com`, `gitlab.example.com`).
  final String host;
  final ForgeHttp http;

  /// Its token, asked for when needed (it may be refreshed meanwhile).
  final Future<String> Function() token;

  ForgeKind get kind;

  /// Who is signed in.
  Future<ForgeUser> me();

  /// [ref] as it is now.
  Future<ForgeItem> item(ForgeRef ref);

  /// [repo]'s open issues: [filter]'s, matching [query] when given; the
  /// most recently updated first.
  Future<List<ForgeItem>> issues(
    ForgeRepo repo, {
    ForgeIssueFilter filter = ForgeIssueFilter.assigned,
    String query = '',
  });

  /// Comments [body] on [ref].
  Future<void> comment(ForgeRef ref, String body);

  /// Closes the issue [ref].
  Future<void> close(ForgeRef ref);

  Uri get _base;

  Map<String, String> _headers(String token);

  Future<Object?> _call(
    String method,
    String path, {
    Map<String, String>? query,
    Object? json,
  }) async {
    final url = _base.replace(
      path: '${_base.path}$path',
      queryParameters: query,
    );
    final response = await http.send(
      method,
      url,
      headers: _headers(await token()),
      json: json,
    );
    if (!response.ok) {
      throw ForgeException(
        forgeErrorMessage(response) ?? 'HTTP ${response.status}',
        status: response.status,
      );
    }
    return response.json;
  }

  static DateTime? _date(Object? value) =>
      value is String ? DateTime.tryParse(value)?.toLocal() : null;
}

/// GitHub's REST API.
class GitHubApi extends ForgeApi {
  GitHubApi({required super.host, required super.http, required super.token});

  @override
  ForgeKind get kind => ForgeKind.github;

  @override
  Uri get _base => host == 'github.com'
      ? Uri.https('api.github.com', '')
      : Uri.https(host, '/api/v3');

  @override
  Map<String, String> _headers(String token) => {
    'Authorization': 'Bearer $token',
    'Accept': 'application/vnd.github+json',
    'X-GitHub-Api-Version': '2022-11-28',
  };

  @override
  Future<ForgeUser> me() async {
    final json = await _call('GET', '/user') as Map;
    return ForgeUser(
      login: json['login'] as String,
      name: json['name'] as String?,
    );
  }

  @override
  Future<ForgeItem> item(ForgeRef ref) async {
    final repo = '/repos/${ref.repo.path}';
    if (ref.kind == ForgeItemKind.issue) {
      final json = await _call('GET', '$repo/issues/${ref.number}') as Map;
      // A pull request's number, linked as an issue's.
      if (json['pull_request'] != null) {
        return item(
          ForgeRef(
            repo: ref.repo,
            kind: ForgeItemKind.pull,
            number: ref.number,
          ),
        );
      }
      return _issue(ref.repo, json);
    }
    final json = await _call('GET', '$repo/pulls/${ref.number}') as Map;
    final sha = (json['head'] as Map?)?['sha'] as String?;
    return _issue(
      ref.repo,
      json,
      kind: ForgeItemKind.pull,
      state: json['merged_at'] != null
          ? ForgeState.merged
          : json['state'] == 'closed'
          ? ForgeState.closed
          : json['draft'] == true
          ? ForgeState.draft
          : ForgeState.open,
      checks: sha == null ? null : await _checks(repo, sha),
      branch: (json['head'] as Map?)?['ref'] as String?,
    );
  }

  /// The commit [sha]'s check runs, together: failed when any failed,
  /// pending while any runs; none when it has none.
  Future<ForgeChecks?> _checks(String repo, String sha) async {
    try {
      final json = await _call(
        'GET',
        '$repo/commits/$sha/check-runs',
        query: {'per_page': '100'},
      ) as Map;
      final runs = (json['check_runs'] as List?)?.cast<Map>() ?? const [];
      if (runs.isEmpty) return null;
      if (runs.any((run) => run['status'] != 'completed')) {
        return ForgeChecks.pending;
      }
      const failed = {'failure', 'timed_out', 'cancelled', 'action_required'};
      return runs.any((run) => failed.contains(run['conclusion']))
          ? ForgeChecks.failure
          : ForgeChecks.success;
    } on ForgeException {
      // Not to be seen with this token: no checks shown.
      return null;
    }
  }

  ForgeItem _issue(
    ForgeRepo repo,
    Map json, {
    ForgeItemKind kind = ForgeItemKind.issue,
    ForgeState? state,
    ForgeChecks? checks,
    String? branch,
  }) => ForgeItem(
    ref: ForgeRef(repo: repo, kind: kind, number: json['number'] as int),
    title: json['title'] as String? ?? '',
    state:
        state ??
        (json['state'] == 'closed' ? ForgeState.closed : ForgeState.open),
    body: json['body'] as String? ?? '',
    author: (json['user'] as Map?)?['login'] as String?,
    labels: [
      for (final label in (json['labels'] as List?) ?? const [])
        if (label is Map)
          ForgeLabel(
            label['name'] as String? ?? '',
            color: switch (label['color']) {
              final String color when color.isNotEmpty => '#$color',
              _ => null,
            },
          ),
    ],
    assignees: [
      for (final user in (json['assignees'] as List?) ?? const [])
        if (user is Map) ?user['login'] as String?,
    ],
    comments: json['comments'] as int? ?? 0,
    updated: ForgeApi._date(json['updated_at']),
    checks: checks,
    branch: branch,
  );

  @override
  Future<List<ForgeItem>> issues(
    ForgeRepo repo, {
    ForgeIssueFilter filter = ForgeIssueFilter.assigned,
    String query = '',
  }) async {
    final terms = [
      'repo:${repo.path}',
      'is:issue',
      'is:open',
      switch (filter) {
        ForgeIssueFilter.assigned => 'assignee:@me',
        ForgeIssueFilter.created => 'author:@me',
        ForgeIssueFilter.all => '',
      },
      query.trim(),
    ].where((term) => term.isNotEmpty).join(' ');
    final json = await _call(
      'GET',
      '/search/issues',
      query: {'q': terms, 'sort': 'updated', 'order': 'desc', 'per_page': '50'},
    ) as Map;
    return [
      for (final issue in (json['items'] as List?) ?? const [])
        if (issue is Map) _issue(repo, issue),
    ];
  }

  @override
  Future<void> comment(ForgeRef ref, String body) => _call(
    'POST',
    '/repos/${ref.repo.path}/issues/${ref.number}/comments',
    json: {'body': body},
  );

  @override
  Future<void> close(ForgeRef ref) => _call(
    'PATCH',
    '/repos/${ref.repo.path}/issues/${ref.number}',
    json: {'state': 'closed'},
  );
}

/// GitLab's REST API (v4).
class GitLabApi extends ForgeApi {
  GitLabApi({required super.host, required super.http, required super.token});

  @override
  ForgeKind get kind => ForgeKind.gitlab;

  @override
  Uri get _base => Uri.https(host, '/api/v4');

  @override
  Map<String, String> _headers(String token) => {
    'Authorization': 'Bearer $token',
    'Accept': 'application/json',
  };

  /// A project's path as the API takes it in place of its id.
  static String _project(ForgeRepo repo) =>
      '/projects/${Uri.encodeComponent(repo.path)}';

  @override
  Future<ForgeUser> me() async {
    final json = await _call('GET', '/user') as Map;
    return ForgeUser(
      login: json['username'] as String,
      name: json['name'] as String?,
    );
  }

  @override
  Future<ForgeItem> item(ForgeRef ref) async {
    final project = _project(ref.repo);
    if (ref.kind == ForgeItemKind.issue) {
      final json = await _call('GET', '$project/issues/${ref.number}') as Map;
      return _item(ref.repo, json);
    }
    final json =
        await _call('GET', '$project/merge_requests/${ref.number}') as Map;
    return _item(
      ref.repo,
      json,
      kind: ForgeItemKind.pull,
      state: switch (json['state']) {
        'merged' => ForgeState.merged,
        'closed' || 'locked' => ForgeState.closed,
        _ when json['draft'] == true || json['work_in_progress'] == true =>
          ForgeState.draft,
        _ => ForgeState.open,
      },
      checks: switch ((json['head_pipeline'] as Map?)?['status']) {
        'success' => ForgeChecks.success,
        'failed' || 'canceled' => ForgeChecks.failure,
        null || 'skipped' || 'manual' => null,
        _ => ForgeChecks.pending,
      },
      branch: json['source_branch'] as String?,
    );
  }

  ForgeItem _item(
    ForgeRepo repo,
    Map json, {
    ForgeItemKind kind = ForgeItemKind.issue,
    ForgeState? state,
    ForgeChecks? checks,
    String? branch,
  }) => ForgeItem(
    ref: ForgeRef(repo: repo, kind: kind, number: json['iid'] as int),
    title: json['title'] as String? ?? '',
    state:
        state ??
        (json['state'] == 'closed' ? ForgeState.closed : ForgeState.open),
    body: json['description'] as String? ?? '',
    author: (json['author'] as Map?)?['username'] as String?,
    labels: [
      for (final label in (json['labels'] as List?) ?? const [])
        switch (label) {
          final String name => ForgeLabel(name),
          // With_labels_details: their colors too.
          final Map label => ForgeLabel(
            label['name'] as String? ?? '',
            color: label['color'] as String?,
          ),
          _ => const ForgeLabel(''),
        },
    ].where((label) => label.name.isNotEmpty).toList(),
    assignees: [
      for (final user in (json['assignees'] as List?) ?? const [])
        if (user is Map) ?user['username'] as String?,
    ],
    comments: json['user_notes_count'] as int? ?? 0,
    updated: ForgeApi._date(json['updated_at']),
    checks: checks,
    branch: branch,
  );

  @override
  Future<List<ForgeItem>> issues(
    ForgeRepo repo, {
    ForgeIssueFilter filter = ForgeIssueFilter.assigned,
    String query = '',
  }) async {
    final json = await _call(
      'GET',
      '${_project(repo)}/issues',
      query: {
        'state': 'opened',
        'scope': switch (filter) {
          ForgeIssueFilter.assigned => 'assigned_to_me',
          ForgeIssueFilter.created => 'created_by_me',
          ForgeIssueFilter.all => 'all',
        },
        'search': ?(query.trim().isEmpty ? null : query.trim()),
        'with_labels_details': 'true',
        'order_by': 'updated_at',
        'sort': 'desc',
        'per_page': '50',
      },
    ) as List;
    return [
      for (final issue in json)
        if (issue is Map) _item(repo, issue),
    ];
  }

  @override
  Future<void> comment(ForgeRef ref, String body) => _call(
    'POST',
    '${_project(ref.repo)}/${ref.kind == ForgeItemKind.pull ? 'merge_requests' : 'issues'}/${ref.number}/notes',
    json: {'body': body},
  );

  @override
  Future<void> close(ForgeRef ref) => _call(
    'PUT',
    '${_project(ref.repo)}/issues/${ref.number}',
    json: {'state_event': 'close'},
  );
}
