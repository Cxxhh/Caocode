import 'dart:convert';
import 'dart:typed_data';

import 'package:pinenacl/digests.dart';
import 'package:pinenacl/tweetnacl.dart';

/// An end's lasting key pair (X25519): a desktop's, or a phone's. What is
/// paired is its public key; the private one never leaves the device.
class LinkIdentity {
  LinkIdentity._(this.privateKey, this.publicKey);

  /// A new key pair.
  factory LinkIdentity.generate() =>
      LinkIdentity.fromPrivateKey(TweetNaCl.randombytes(32));

  factory LinkIdentity.fromPrivateKey(Uint8List privateKey) {
    if (privateKey.length != 32) {
      throw ArgumentError.value(
        privateKey.length,
        'privateKey',
        'not 32 bytes',
      );
    }
    final public = Uint8List(32);
    TweetNaCl.crypto_scalarmult_base(public, privateKey);
    return LinkIdentity._(Uint8List.fromList(privateKey), public);
  }

  /// As [toJson] wrote it.
  factory LinkIdentity.fromJson(Map<String, Object?> json) =>
      LinkIdentity.fromPrivateKey(decodeKey(json['privateKey']! as String));

  final Uint8List privateKey;
  final Uint8List publicKey;

  Map<String, Object?> toJson() => {'privateKey': encodeKey(privateKey)};

  /// [publicKey] as both screens show it (see [fingerprintOf]).
  String get fingerprint => fingerprintOf(publicKey);
}

/// X25519 of [privateKey] and [publicKey]; throws on a key that would make
/// it all zeros (a point of small order), as Noise does.
Uint8List dh(Uint8List privateKey, Uint8List publicKey) {
  if (publicKey.length != 32) throw const FormatException('Bad public key');
  final out = Uint8List(32);
  TweetNaCl.crypto_scalarmult(out, privateKey, publicKey);
  if (out.every((byte) => byte == 0)) {
    throw const FormatException('Bad public key');
  }
  return out;
}

/// [length] random bytes, from the system's secure generator.
Uint8List randomBytes(int length) => TweetNaCl.randombytes(length);

/// A key as text: base64url, unpadded.
String encodeKey(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

Uint8List decodeKey(String text) =>
    base64Url.decode(base64Url.normalize(text.trim()));

/// SHA-256 of [publicKey], its first 16 bytes in groups of four hex digits
/// (`7F3A 91C2 …`): a key as people read it.
String fingerprintOf(Uint8List publicKey) {
  final hash = Hash.sha256(publicKey);
  final hex = [
    for (final byte in hash.take(16))
      byte.toRadixString(16).padLeft(2, '0').toUpperCase(),
  ].join();
  return [for (var i = 0; i < hex.length; i += 4) hex.substring(i, i + 4)]
      .join(' ');
}

/// A device's id, the same on both ends: its key's fingerprint, unspaced
/// and lower case.
String deviceIdOf(Uint8List publicKey) =>
    fingerprintOf(publicKey).replaceAll(' ', '').toLowerCase();

/// What both screens show while pairing, to be compared: four groups of
/// three digits from the hash of the two public keys (the desktop's first).
/// One in the middle would have had to put a key of its own in place of
/// one of them, and the codes would not match.
List<String> safetyCode(Uint8List desktopKey, Uint8List phoneKey) {
  final hash = Hash.sha256(
    Uint8List.fromList([
      ...utf8.encode('baocode-safety'),
      ...desktopKey,
      ...phoneKey,
    ]),
  );
  return [
    for (var i = 0; i < 4; i++)
      ((hash[i * 3] << 16 | hash[i * 3 + 1] << 8 | hash[i * 3 + 2]) % 1000)
          .toString()
          .padLeft(3, '0'),
  ];
}
