import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// URL del backend propio (Cloudflare Workers). Se cambia al compilar con
/// `--dart-define=API_URL=https://...`; por defecto, staging.
const String apiBaseUrl = String.fromEnvironment(
  'API_URL',
  defaultValue: 'https://furbo-api-staging.furbo-probe.workers.dev',
);

/// Error que devuelve la API: `code` estable para la app y `message` en
/// español para mostrar tal cual.
class ApiException implements Exception {
  const ApiException(this.status, this.code, this.message, [this.details]);

  final int status;
  final String code;
  final String message;
  final Object? details;

  /// Errores por campo de un 400 `invalid_input` (`{campo: [mensajes]}`).
  Map<String, List<String>> get fieldErrors {
    final d = details;
    if (d is! Map) return const {};
    return {
      for (final e in d.entries)
        if (e.value is List)
          '${e.key}': [for (final m in e.value as List) '$m'],
    };
  }

  @override
  String toString() => 'ApiException($status, $code, $message)';
}

/// No se pudo hablar con el servidor (sin señal, DNS, tiempo agotado).
class OfflineException implements Exception {
  const OfflineException(this.cause);

  final Object cause;

  @override
  String toString() => 'OfflineException($cause)';
}

/// Cliente JSON del backend. Un token opcional va en `Authorization`.
class ApiClient {
  ApiClient({
    http.Client? client,
    this.baseUrl = apiBaseUrl,
    this.timeout = const Duration(seconds: 45),
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final String baseUrl;

  /// El push puede tardar ~8 s en el servidor; con la conexión de Cuba, más.
  final Duration timeout;

  /// Token de la sesión actual. Lo pone quien maneja la sesión.
  String? token;

  Future<Map<String, dynamic>?> get(String path) => _send('GET', path);

  Future<Map<String, dynamic>?> post(String path, [Object? body]) =>
      _send('POST', path, body ?? const <String, Object?>{});

  Future<Map<String, dynamic>?> delete(String path, [Object? body]) =>
      _send('DELETE', path, body);

  Future<Map<String, dynamic>?> _send(
    String method,
    String path, [
    Object? body,
  ]) async {
    final request = http.Request(method, Uri.parse('$baseUrl$path'));
    if (token != null) request.headers['authorization'] = 'Bearer $token';
    if (body != null) {
      request.headers['content-type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final http.Response res;
    try {
      res = await http.Response.fromStream(
        await _client.send(request).timeout(timeout),
      ).timeout(timeout);
    } on TimeoutException catch (e) {
      throw OfflineException(e);
    } on SocketException catch (e) {
      throw OfflineException(e);
    } on http.ClientException catch (e) {
      throw OfflineException(e);
    }
    // JSON siempre es UTF-8 (RFC 8259), diga lo que diga la cabecera. Un cuerpo que no sea JSON
    // (p. ej. un 502 de un proxy) no rompe: se trata como vacío.
    final text = utf8.decode(res.bodyBytes, allowMalformed: true);
    Object? json;
    try {
      json = text.isEmpty ? null : jsonDecode(text);
    } on FormatException {
      json = null;
    }
    if (res.statusCode >= 200 && res.statusCode < 300) {
      return json is Map<String, dynamic> ? json : null;
    }
    final error = json is Map && json['error'] is Map
        ? json['error'] as Map
        : const {};
    throw ApiException(
      res.statusCode,
      '${error['code'] ?? 'http_${res.statusCode}'}',
      '${error['message'] ?? 'Error del servidor (${res.statusCode})'}',
      error['details'],
    );
  }

  void close() => _client.close();
}
