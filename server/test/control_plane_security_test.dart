import 'package:test/test.dart';

import '../lib/features/control_plane/domain/control_plane_security.dart';

void main() {
  group('PasswordHasher', () {
    test('hash verifies the original password and rejects a different one',
        () {
      final hasher = PasswordHasher(iterations: 100000);
      final encoded = hasher.hash(
        'a-long-test-password',
        salt: List<int>.generate(16, (index) => index),
      );

      expect(hasher.verify('a-long-test-password', encoded), isTrue);
      expect(hasher.verify('another-long-password', encoded), isFalse);
      expect(encoded, isNot(contains('a-long-test-password')));
    });

    test('rejects weak password and malformed or excessive-cost hashes', () {
      final hasher = PasswordHasher(iterations: 100000);
      expect(() => hasher.hash('short'), throwsArgumentError);
      expect(hasher.verify('password', 'not-a-hash'), isFalse);
      expect(
        hasher.verify('password',
            'pbkdf2-sha256\$999999999\$c2FsdA\$a2V5'),
        isFalse,
      );
    });
  });

  test('opaque session tokens are unique and persist only a digest', () {
    final first = OpaqueSessionToken.generate();
    final second = OpaqueSessionToken.generate();

    expect(first.value, isNot(first.hashHex));
    expect(first.hashHex, hasLength(64));
    expect(second.value, isNot(first.value));
    expect(second.hashHex, isNot(first.hashHex));
  });
}
