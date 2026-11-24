import 'package:test/test.dart';
import '../lib/features/control_plane/data/store_database_connection_resolver.dart';
import '../lib/features/control_plane/domain/control_plane_sessions.dart';

void main() {
  test('resolves credentials only through the trusted store database key', () async {
    final resolver = StoreDatabaseConnectionResolver(
      bindings: _Bindings({'store-a': 'secret-a', 'store-b': 'secret-b'}),
      credentialsProvider: EnvironmentStoreDatabaseCredentialsProvider(
        '{"secret-a":{"host":"db-a.internal","database":"tenant_a","username":"tenant_a_app","password":"secret-a-value","ssl":true},'
        '"secret-b":{"host":"db-b.internal","database":"tenant_b","username":"tenant_b_app","password":"secret-b-value","ssl":false}}',
      ),
    );
    final a = await resolver.resolveCredentialsForStore('store-a');
    final b = await resolver.resolveCredentialsForStore('store-b');
    expect(a.host, 'db-a.internal');
    expect(a.database, 'tenant_a');
    expect(a.username, 'tenant_a_app');
    expect(a.useSsl, isTrue);
    expect(b.host, 'db-b.internal');
    expect(b.database, 'tenant_b');
    expect(b.username, 'tenant_b_app');
    expect(b.useSsl, isFalse);
    expect(a.database, isNot(b.database));
  });

  test('fails closed when no READY binding exists', () async {
    final resolver = StoreDatabaseConnectionResolver(
      bindings: _Bindings(const {}),
      credentialsProvider: EnvironmentStoreDatabaseCredentialsProvider('{}'),
    );
    await expectLater(resolver.resolveCredentialsForStore('store-x'),
      throwsA(isA<StoreDatabaseUnavailableException>()));
  });

  test('fails closed when the secret manager has no matching key', () async {
    final resolver = StoreDatabaseConnectionResolver(
      bindings: _Bindings({'store-a': 'missing-secret'}),
      credentialsProvider: EnvironmentStoreDatabaseCredentialsProvider('{}'),
    );
    await expectLater(resolver.resolveCredentialsForStore('store-a'),
      throwsA(isA<StoreDatabaseUnavailableException>()));
  });

  test('fails closed for incomplete credentials', () async {
    final resolver = StoreDatabaseConnectionResolver(
      bindings: _Bindings({'store-a': 'incomplete'}),
      credentialsProvider: EnvironmentStoreDatabaseCredentialsProvider(
        '{"incomplete":{"host":"db.internal","database":"tenant","username":"app","password":""}}',
      ),
    );
    await expectLater(resolver.resolveCredentialsForStore('store-a'),
      throwsA(isA<StoreDatabaseUnavailableException>()));
  });
}

final class _Bindings implements StoreDatabaseBindingRepository {
  _Bindings(this.keys);
  final Map<String, String> keys;
  @override
  Future<String?> readyDatabaseKeyForStore(String storeId) async => keys[storeId];
}
