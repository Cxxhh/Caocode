import 'dart:typed_data';

import '../protocol.dart';
import '../review/review_store.dart';
import '../rpc/rpc_peer.dart';

/// [ReviewStore] of a project on the remote host: its folder there (in
/// the server's `checkpoints/`), every call a request.
class RemoteReviewStore implements ReviewStore {
  RemoteReviewStore(this._peer, this._id, this.root);

  final RpcPeer _peer;
  final int _id;

  @override
  final String root;

  Future<Object?> _call(
    String method, [
    Map<String, Object?> args = const {},
  ]) => _peer.request(RemoteProtocol.reviewCall, {
    'id': _id,
    'method': method,
    'args': args,
  });

  static ReviewBlob? _blob(Object? json) => ReviewBlob.fromJson(json);

  @override
  Future<bool> exists(String path) async =>
      await _call('exists', {'path': path}) as bool;

  @override
  Future<ReviewBlob?> current(String path) async =>
      _blob(await _call('current', {'path': path}));

  @override
  Future<ReviewBlob?> take(String session, String path) async =>
      _blob(await _call('take', {'session': session, 'path': path}));

  @override
  Future<ReviewBlob> store(
    String session,
    Uint8List bytes, {
    required String mode,
  }) async => _blob(
    await _call('store', {
      'session': session,
      'bytes': encodeBytes(bytes),
      'mode': mode,
    }),
  )!;

  @override
  Future<Uint8List> read(String session, ReviewBlob blob) async => decodeBytes(
    await _call('read', {'session': session, 'blob': blob.toJson()}),
  );

  @override
  Future<void> restore(String session, String path, ReviewBlob? blob) => _call(
    'restore',
    {'session': session, 'path': path, 'blob': blob?.toJson()},
  );

  @override
  Future<Uint8List?> merge(
    String session,
    String path,
    ReviewBlob from,
    ReviewBlob to,
  ) async {
    final merged = await _call('merge', {
      'session': session,
      'path': path,
      'from': from.toJson(),
      'to': to.toJson(),
    });
    return merged == null ? null : decodeBytes(merged);
  }

  @override
  Future<void> write(String path, Uint8List bytes) =>
      _call('write', {'path': path, 'bytes': encodeBytes(bytes)});

  @override
  Future<Map<String, ({int added, int removed})?>> lineCounts(
    String session,
    Map<String, ReviewBlob?> bases,
  ) async => {
    for (final MapEntry(:key, :value) in (await _call('lineCounts', {
      'session': session,
      'bases': {
        for (final MapEntry(:key, :value) in bases.entries)
          key: value?.toJson(),
      },
    }) as Map).cast<String, Object?>().entries)
      key: switch (value) {
        [final int added, final int removed] => (
          added: added,
          removed: removed,
        ),
        _ => null,
      },
  };

  @override
  Future<String?> load(String session) async =>
      await _call('load', {'session': session}) as String?;

  @override
  Future<void> save(
    String session,
    String data, {
    required Iterable<ReviewBlob> blobs,
  }) => _call('save', {
    'session': session,
    'data': data,
    'blobs': [for (final blob in blobs) blob.toJson()],
  });

  @override
  Future<void> forget(String session) => _call('forget', {'session': session});
}
