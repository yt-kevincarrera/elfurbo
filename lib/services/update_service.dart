import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/app_update.dart';

/// Actualizaciones de la app desde GitHub Releases.
///
/// El repo es público, así que la API se consulta sin token. Los APK son los
/// de `flutter build apk --split-per-abi`; se elige el de la ABI del teléfono.
class UpdateService {
  UpdateService({http.Client? client}) : _client = client ?? http.Client();

  static const repo = 'yt-kevincarrera/elfurbo';
  static const latestReleaseUrl =
      'https://api.github.com/repos/$repo/releases/latest';

  /// Cada cuánto se vuelve a preguntar a GitHub (en primer y segundo plano).
  static const checkInterval = Duration(hours: 12);

  static const _lastCheckKey = 'update.lastCheckMillis';
  static const _notifiedTagKey = 'update.notifiedTag';

  final http.Client _client;

  /// Última release publicada, o null si no hay ninguna o falla la red.
  /// Es estático porque también lo usa el worker de segundo plano.
  static Future<AppRelease?> fetchLatest({http.Client? client}) async {
    final c = client ?? http.Client();
    try {
      final res = await c
          .get(
            Uri.parse(latestReleaseUrl),
            headers: const {
              'Accept': 'application/vnd.github+json',
              'User-Agent': 'elfurbo-app',
            },
          )
          .timeout(const Duration(seconds: 15));
      if (res.statusCode == 404) return null; // sin releases todavía
      if (res.statusCode != 200) {
        throw HttpException('GitHub respondió ${res.statusCode}');
      }
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      if (json['draft'] == true) return null;
      return AppRelease.fromGitHubJson(json);
    } finally {
      if (client == null) c.close();
    }
  }

  static Future<String> installedVersion() async =>
      (await PackageInfo.fromPlatform()).version;

  /// ABIs del teléfono en orden de preferencia (`arm64-v8a` primero, etc.).
  static Future<List<String>> supportedAbis() async {
    if (!Platform.isAndroid) return const [];
    final info = await DeviceInfoPlugin().androidInfo;
    return info.supportedAbis;
  }

  /// Devuelve la release si hay una versión más nueva que la instalada.
  ///
  /// Sin [force] respeta [checkInterval] para no pegarle a GitHub en cada
  /// apertura. Los errores de red se tragan (null): actualizar es secundario.
  Future<AppRelease?> checkForUpdate({bool force = false}) async {
    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!force) {
      final last = prefs.getInt(_lastCheckKey) ?? 0;
      if (now - last < checkInterval.inMilliseconds) return null;
    }
    try {
      final release = await fetchLatest(client: _client);
      await prefs.setInt(_lastCheckKey, now);
      if (release == null) return null;
      final installed = await installedVersion();
      return release.isNewerThan(installed) ? release : null;
    } catch (e) {
      debugPrint('Update: no se pudo consultar GitHub: $e');
      if (force) rethrow;
      return null;
    }
  }

  /// Descarga el APK a la carpeta temporal de la app. [onProgress] recibe
  /// 0..1 (o -1 si el servidor no informa el tamaño).
  Future<File> download(
    ReleaseAsset asset, {
    void Function(double progress)? onProgress,
  }) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/${asset.name}');
    final req = http.Request('GET', Uri.parse(asset.url))
      ..headers['User-Agent'] = 'elfurbo-app';
    final res = await _client.send(req).timeout(const Duration(seconds: 30));
    if (res.statusCode != 200) {
      throw HttpException('Descarga falló (${res.statusCode})');
    }
    final total = res.contentLength ?? asset.size;
    var received = 0;
    final sink = file.openWrite();
    try {
      await for (final chunk in res.stream) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(total > 0 ? received / total : -1);
      }
    } finally {
      await sink.close();
    }
    return file;
  }

  /// Abre el instalador de Android con el APK descargado.
  Future<void> install(File apk) async {
    final result = await OpenFilex.open(
      apk.path,
      type: 'application/vnd.android.package-archive',
    );
    if (result.type != ResultType.done) {
      throw Exception('No se pudo abrir el instalador: ${result.message}');
    }
  }

  /// Marca que ya se avisó (notificación) de esta versión, para no repetir.
  static Future<bool> markNotified(String tag) async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString(_notifiedTagKey) == tag) return false;
    await prefs.setString(_notifiedTagKey, tag);
    return true;
  }

  void dispose() => _client.close();
}
