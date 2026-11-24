import 'dart:convert';
import 'dart:io';

import '../domain/control_plane_domain.dart';
import '../domain/control_plane_sessions.dart';

/// Verifies Google ID tokens against Google's tokeninfo endpoint and pins the
/// expected OAuth audience. Use HTTPS only; never trust decoded JWT claims.
final class GoogleIdentityTokenVerifier implements AccountIdentityTokenVerifier {
  GoogleIdentityTokenVerifier({
    required this.clientId,
    HttpClient? client,
  }) : _client = client ?? HttpClient();

  final String clientId;
  final HttpClient _client;

  @override
  Future<VerifiedAccountIdentity> verify({
    required String provider,
    required String idToken,
  }) async {
    if (provider != 'google') {
      throw const FormatException('Only the Google identity provider is configured.');
    }
    if (idToken.trim().isEmpty || idToken.length > 16384) {
      throw const FormatException('A valid Google ID token is required.');
    }
    final uri = Uri.https('oauth2.googleapis.com', '/tokeninfo', {'id_token': idToken});
    final request = await _client.getUrl(uri).timeout(const Duration(seconds: 10));
    final response = await request.close().timeout(const Duration(seconds: 10));
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode != HttpStatus.ok) {
      throw const FormatException('Google rejected the supplied ID token.');
    }
    final claims = jsonDecode(body);
    if (claims is! Map<String, dynamic> ||
        claims['aud'] != clientId ||
        !const {'accounts.google.com', 'https://accounts.google.com'}.contains(claims['iss']) ||
        claims['email_verified']?.toString() != 'true' ||
        claims['sub'] is! String ||
        claims['email'] is! String) {
      throw const FormatException('Google ID token claims are invalid for this application.');
    }
    final expiry = int.tryParse(claims['exp']?.toString() ?? '');
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (expiry == null || expiry <= now) {
      throw const FormatException('Google ID token has expired.');
    }
    return VerifiedAccountIdentity(
      provider: 'google',
      subject: claims['sub'] as String,
      email: claims['email'] as String,
      emailVerified: true,
      displayName: claims['name'] is String ? claims['name'] as String : null,
    );
  }
}
