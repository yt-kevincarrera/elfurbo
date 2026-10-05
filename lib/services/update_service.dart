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
/// Lo usan la app (`UpdateController`) y el worker de segundo plano.
class UpdateService {
  UpdateService({http.Client? client}) : _client = client ?? http.Client();

  static const repo = 'yt-kevincarrera/elfurbo';
  static const latestReleaseUrl =
      'https://api.github.com/repos/$repo/releases/latest';

  /// Cada cuánto se vuelve a preguntar a GitHub (en primer y segundo plano).
  static const checkInterval = Duration(hours: 12);

  static const _lastCheckKey = 'update.lastCheckMillis';
  static const _latestJsonKey = 'update.latestJson';

  final http.Client _client;

  /// Última release publicada, o null si no hay ninguna. Se guarda en el
  /// teléfono para saber que hay una versión nueva aunque no haya señal.
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
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_latestJsonKey, res.body);
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

  /// La última release que se vio, si es más nueva que la instalada. Sin red.
  Future<AppRelease?> lastKnown() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_latestJsonKey);
    if (raw == null) return null;
    try {
      final release = AppRelease.fromGitHubJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
      return release.isNewerThan(await installedVersion()) ? release : null;
    } catch (_) {
      return null;
    }
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

  /// El APK de esta release para este teléfono, o null si no hay.
  Future<ReleaseAsset?> assetForDevice(AppRelease release) async =>
      release.assetFor(await supportedAbis());

  static Future<Directory> _updatesDir() async {
    final dir = Directory(
      '${(await getApplicationSupportDirectory()).path}/updates',
    );
    await dir.create(recursive: true);
    return dir;
  }

  /// El APK ya descargado (completo), o null.
  Future<File?> cachedApk(ReleaseAsset asset) async {
    final file = File('${(await _updatesDir()).path}/${asset.name}');
    if (!await file.exists()) return null;
    if (asset.size > 0 && await file.length() != asset.size) return null;
    return file;
  }

  /// Descarga el APK a la carpeta de actualizaciones (si ya está, no repite).
  /// [onProgress] recibe 0..1 (o -1 si el servidor no informa el tamaño).
  /// Se escribe a un `.part` y se renombra al final: un corte no deja un APK
  /// a medias que parezca bueno. Borra los APK de versiones anteriores.
  Future<File> download(
    ReleaseAsset asset, {
    void Function(double progress)? onProgress,
  }) async {
    final cached = await cachedApk(asset);
    if (cached != null) {
      onProgress?.call(1);
      return cached;
    }
    final dir = await _updatesDir();
    for (final old in dir.listSync().whereType<File>()) {
      await old.delete();
    }
    final part = File('${dir.path}/${asset.name}.part');
    final req = http.Request('GET', Uri.parse(asset.url))
      ..headers['User-Agent'] = 'elfurbo-app';
    final res = await _client.send(req).timeout(const Duration(seconds: 30));
    if (res.statusCode != 200) {
      throw HttpException('Descarga falló (${res.statusCode})');
    }
    final total = res.contentLength ?? asset.size;
    var received = 0;
    final sink = part.openWrite();
    try {
      await for (final chunk in res.stream) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(total > 0 ? received / total : -1);
      }
    } finally {
      await sink.close();
    }
    return part.rename('${dir.path}/${asset.name}');
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

  /// Marca que ya se avisó de esta versión ([kind]: 'available' o 'ready'),
  /// para no repetir el mismo aviso. Devuelve false si ya se había avisado.
  static Future<bool> markNotified(String tag, {required String kind}) async {
    final prefs = await SharedPreferences.getInstance();
    final key = 'update.notified.$kind';
    if (prefs.getString(key) == tag) return false;
    await prefs.setString(key, tag);
    return true;
  }

  void dispose() => _client.close();
}
