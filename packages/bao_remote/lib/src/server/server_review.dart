import '../protocol.dart';
import '../review/local_review_store.dart';
import '../review/review_store.dart';
import '../rpc/rpc_peer.dart';
import 'remote_server.dart';

/// The reviews of the remote projects: one [LocalReviewStore] a project,
/// its folder under [checkpoints] on this machine, answering
/// [RemoteProtocol.reviewCall] by method.
class ServerReview {
  ServerReview(RpcPeer peer, {required this.checkpoints}) {
    peer.handlers[RemoteProtocol.reviewOpen] = (params, _) async {
      final root = paramsOf(params)['root'] as String;
      final store = await LocalReviewStore.open(root, checkpoints: checkpoints);
      if (store == null) return null;
      final id = ++_nextId;
      _stores[id] = store;
      return {'id': id, 'root': store.root};
    };
    peer.handlers[RemoteProtocol.reviewCall] = (params, _) {
      final args = paramsOf(params);
      final store = _stores[args['id']];
      if (store == null) throw const ReviewUnavailable('No such store');
      return call(store, args['method'] as String, paramsOf(args['args']));
    };
  }

  final String checkpoints;
  final Map<int, ReviewStore> _stores = {};
  int _nextId = 0;

  static ReviewBlob? _blob(Object? json) => ReviewBlob.fromJson(json);

  /// [method] of [store] with [args], as JSON.
  static Future<Object?> call(
    ReviewStore store,
    String method,
    Map<String, Object?> args,
  ) async {
    String string(String name) => args[name] as String;
    switch (method) {
      case 'exists':
        return store.exists(string('path'));
      case 'current':
        return (await store.current(string('path')))?.toJson();
      case 'take':
        return (await store.take(string('session'), string('path')))?.toJson();
      case 'store':
        final blob = await store.store(
          string('session'),
          decodeBytes(args['bytes']),
          mode: string('mode'),
        );
        return blob.toJson();
      case 'read':
        return encodeBytes(
          await store.read(string('session'), _blob(args['blob'])!),
        );
      case 'restore':
        await store.restore(
          string('session'),
          string('path'),
          _blob(args['blob']),
        );
        return null;
      case 'merge':
        final merged = await store.merge(
          string('session'),
          string('path'),
          _blob(args['from'])!,
          _blob(args['to'])!,
        );
        return merged == null ? null : encodeBytes(merged);
      case 'write':
        await store.write(string('path'), decodeBytes(args['bytes']));
        return null;
      case 'lineCounts':
        final counts = await store.lineCounts(string('session'), {
          for (final MapEntry(:key, :value) in paramsOf(args['bases']).entries)
            key: _blob(value),
        });
        return {
          for (final MapEntry(:key, :value) in counts.entries)
            key: value == null ? null : [value.added, value.removed],
        };
      case 'load':
        return store.load(string('session'));
      case 'save':
        await store.save(
          string('session'),
          string('data'),
          blobs: [for (final blob in args['blobs'] as List) ?_blob(blob)],
        );
        return null;
      case 'forget':
        await store.forget(string('session'));
        return null;
    }
    throw ArgumentError.value(method, 'method', 'not a review method');
  }
}
