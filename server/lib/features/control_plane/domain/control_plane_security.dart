import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// PBKDF2-HMAC-SHA256 password hashes for control-plane accounts.
///
/// Keep the iteration count versioned in the stored hash. Authentication
/// endpoints must additionally enforce per-account and per-IP rate limits.
final class PasswordHasher {
  PasswordHasher({this.iterations = 600000}) {
    if (iterations < 100000 || iterations > 1000000) {
      throw ArgumentError.value(iterations, 'iterations');
    }
  }

  final int iterations;
  static const int _saltLength = 16;
  static const int _keyLength = 32;

  String hash(String password, {List<int>? salt}) {
    if (password.length < 12) {
      throw ArgumentError.value(password.length, 'password.length',
          'Passwords must contain at least 12 characters.');
    }
    final actualSalt = salt ?? _secureBytes(_saltLength);
    if (actualSalt.length != _saltLength) {
      throw ArgumentError.value(actualSalt.length, 'salt.length');
    }
    final derived = _derive(password, actualSalt, iterations, _keyLength);
    return 'pbkdf2-sha256\$$iterations\$'
        '${base64Url.encode(actualSalt).replaceAll('=', '')}\$'
        '${base64Url.encode(derived).replaceAll('=', '')}';
  }

  bool verify(String password, String encoded) {
    final parts = encoded.split('\$');
    if (parts.length != 4 || parts[0] != 'pbkdf2-sha256') return false;
    final rounds = int.tryParse(parts[1]);
    if (rounds == null || rounds < 100000 || rounds > 1000000) return false;
    try {
      final salt = base64Url.decode(base64Url.normalize(parts[2]));
      final expected = base64Url.decode(base64Url.normalize(parts[3]));
      if (salt.length != _saltLength || expected.length != _keyLength) {
        return false;
      }
      final actual = _derive(password, salt, rounds, _keyLength);
      return _constantTimeEquals(actual, expected);
    } on FormatException {
      return false;
    }
  }

  List<int> _derive(
      String password, List<int> salt, int rounds, int length) {
    final key = utf8.encode(password);
    final blockInput = <int>[...salt, 0, 0, 0, 1];
    final hmac = Hmac(sha256, key);
    var u = hmac.convert(blockInput).bytes;
    final output = List<int>.from(u);
    for (var round = 1; round < rounds; round++) {
      u = hmac.convert(u).bytes;
      for (var i = 0; i < output.length; i++) {
        output[i] ^= u[i];
      }
    }
    return output.sublist(0, length);
  }

  List<int> _secureBytes(int length) {
    final random = Random.secure();
    return List<int>.generate(length, (_) => random.nextInt(256));
  }

  bool _constantTimeEquals(List<int> left, List<int> right) {
    if (left.length != right.length) return false;
    var difference = 0;
    for (var i = 0; i < left.length; i++) {
      difference |= left[i] ^ right[i];
    }
    return difference == 0;
  }
}

/// A high-entropy bearer token and its SHA-256 database representation.
///
/// Persist only [hashHex]. Return [value] once to the caller over TLS.
final class OpaqueSessionToken {
  OpaqueSessionToken._(this.value, this.hashHex);

  factory OpaqueSessionToken.generate() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    final value = base64Url.encode(bytes).replaceAll('=', '');
    final hashHex = sha256.convert(utf8.encode(value)).toString();
    return OpaqueSessionToken._(value, hashHex);
  }

  final String value;
  final String hashHex;
}
