import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

/// Cliente HTTP con Cronet (la pila de red de Chrome) en Android: HTTP/3 y
/// nombre cifrado (ECH). Desde Cuba es lo que deja llegar a `*.workers.dev`.
///
/// Lee la respuesta entera antes de devolverla: vale para la API (JSON), no
/// para descargas grandes.
class Http3Client extends http.BaseClient {
  Http3Client({this.quicHosts = const []});

  /// Servidores a los que se habla HTTP/3 de entrada, sin probar antes TCP.
  final List<String> quicHosts;

  static const _channel = MethodChannel('app.elfurbo/http3');

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = await request.finalize().toBytes();
    final Map<String, Object?>? reply;
    try {
      reply = await _channel.invokeMapMethod<String, Object?>('send', {
        'url': '${request.url}',
        'method': request.method,
        'headers': request.headers,
        'body': body.isEmpty ? null : body,
        'quicHosts': quicHosts,
      });
    } on PlatformException catch (e) {
      throw http.ClientException(e.message ?? e.code, request.url);
    }
    final bytes = reply!['body']! as Uint8List;
    return http.StreamedResponse(
      Stream.value(bytes),
      reply['status']! as int,
      contentLength: bytes.length,
      request: request,
      headers: Map<String, String>.from(reply['headers']! as Map),
      reasonPhrase: '${reply['protocol']}',
    );
  }
}
