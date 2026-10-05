import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../cloud/api/api_client.dart';
import '../domain/app_update.dart';

/// Actualizaciones de la app desde nuestro servidor (`/app/latest` y
/// `/app/apk/...`). El servidor las lee de GitHub Releases: desde Cuba GitHub
/// no abre, así que el teléfono nunca habla con GitHub.
///
/// Los APK son los de `flutter build apk --split-per-abi`; se elige el de la ABI
/// del teléfono. Lo usan la app (`UpdateController`) y el worker de segundo plano.
class UpdateService {
  UpdateService({http.Client? client, Future<Directory> Function()? updatesDir})
    : _client = client ?? http.Client(),
      _dir = updatesDir ?? _defaultUpdatesDir;

  static const latestUrl = '$apiBaseUrl/app/latest';

  /// Cada cuánto se vuelve a preguntar (en primer y segundo plano).
  static const checkInterval = Duration(hours: 12);

  static const _lastCheckKey = 'update.lastCheckMillis';
  static const _latestKey = 'update.latest';
  static const _minBuildKey = 'update.minSupportedBuild';

  final http.Client _client;
  final Future<Directory> Function() _dir;

  /// Última release publicada, o null si no hay ninguna. Se guarda en el
  /// teléfono para saber que hay una versión nueva aunque no haya señal, y
  /// también el build mínimo con el que se puede seguir sincronizando.
  static Future<AppRelease?> fetchLatest({http.Client? client}) async {
    final c = client ?? http.Client();
    try {
      final res = await c
          .get(
            Uri.parse(latestUrl),
            headers: const {'accept': 'application/json'},
          )
          .timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) {
        throw HttpException('El servidor respondió ${res.statusCode}');
      }
      final json = jsonDecode(utf8.decode(res.bodyBytes));
      if (json is! Map<String, dynamic>) {
        throw const FormatException('Respuesta inesperada');
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
        _minBuildKey,
        (json['minSupportedBuild'] as num?)?.toInt() ?? 0,
      );
      final release = json['release'];
      if (release is! Map<String, dynamic>) {
        await prefs.remove(_latestKey);
        return null; // sin releases todavía
      }
      await prefs.setString(_latestKey, jsonEncode(release));
      return AppRelease.fromServerJson(release);
    } finally {
      if (client == null) c.close();
    }
  }

  static Future<String> installedVersion() async =>
      (await PackageInfo.fromPlatform()).version;

  /// true si esta versión es más vieja que la mínima que admite el servidor:
  /// hay que actualizar para seguir sincronizando (sin conexión sigue todo).
  /// Lee lo que guardó el último [fetchLatest], también el de segundo plano.
  static Future<bool> isOutdated() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final min = prefs.getInt(_minBuildKey) ?? 0;
      if (min <= 0) return false;
      final build = int.tryParse(
        (await PackageInfo.fromPlatform()).buildNumber,
      );
      return build != null && build < min;
    } catch (_) {
      return false;
    }
  }

  /// ABIs del teléfono en orden de preferencia (`arm64-v8a` primero, etc.).
  static Future<List<String>> supportedAbis() async {
    if (!Platform.isAndroid) return const [];
    final info = await DeviceInfoPlugin().androidInfo;
    return info.supportedAbis;
  }

  /// La última release que se vio, si es más nueva que la instalada. Sin red.
  Future<AppRelease?> lastKnown() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_latestKey);
    if (raw == null) return null;
    try {
      final release = AppRelease.fromServerJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
      return release.isNewerThan(await installedVersion()) ? release : null;
    } catch (_) {
      return null;
    }
  }

  /// Devuelve la release si hay una versión más nueva que la instalada.
  ///
  /// Sin [force] respeta [checkInterval] para no preguntar en cada apertura.
  /// Los errores de red se tragan (null): actualizar es secundario.
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
      debugPrint('Update: no se pudo consultar la versión nueva: $e');
      if (force) rethrow;
      return null;
    }
  }

  /// El APK de esta release para este teléfono, o null si no hay.
  Future<ReleaseAsset?> assetForDevice(AppRelease release) async =>
      release.assetFor(await supportedAbis());

  static Future<Directory> _defaultUpdatesDir() async =>
      Directory('${(await getApplicationSupportDirectory()).path}/updates');

  Future<Directory> _updatesDir() async {
    final dir = await _dir();
    await dir.create(recursive: true);
    return dir;
  }

  /// El APK ya descargado (completo), o null.
  Future<File?> cachedApk(ReleaseAsset asset) async {
    final file = File('${(await _updatesDir()).path}/${asset.fileName}');
    if (!await file.exists()) return null;
    if (asset.size > 0 && await file.length() != asset.size) return null;
    return file;
  }

  /// Descarga el APK a la carpeta de actualizaciones (si ya está, no repite).
  /// [onProgress] recibe 0..1 (o -1 si el servidor no informa el tamaño).
  ///
  /// Se escribe a un `.part` y se renombra al final: un corte no deja un APK a
  /// medias que parezca bueno. Si ya había un `.part` de esta versión, sigue
  /// donde se quedó (con la conexión de Cuba, 20 MB de una vez es mucho pedir).
  /// Borra lo de otras versiones.
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
    final part = File('${dir.path}/${asset.fileName}.part');
    for (final old in dir.listSync().whereType<File>()) {
      if (old.uri.pathSegments.last != '${asset.fileName}.part') {
        await old.delete();
      }
    }
    var have = await part.exists() ? await part.length() : 0;
    if (asset.size > 0 && have > asset.size) {
      await part.delete();
      have = 0;
    }
    if (asset.size <= 0 || have < asset.size) {
      final req = http.Request('GET', Uri.parse(asset.url));
      if (have > 0) req.headers['range'] = 'bytes=$have-';
      final res = await _client.send(req).timeout(const Duration(seconds: 30));
      final resumed = res.statusCode == 206 && have > 0;
      final apk = (res.headers['content-type'] ?? '').contains('android');
      if ((res.statusCode != 200 && !resumed) || !apk) {
        await res.stream.drain<void>().catchError((Object _) {});
        if (res.statusCode == 416) await part.delete(); // el .part no cuadra
        // Sin el tipo de un APK suele ser el portal de un wifi: no se guarda.
        throw HttpException('Descarga falló (${res.statusCode})');
      }
      if (!resumed) have = 0; // el servidor mandó el archivo entero
      final total = asset.size > 0
          ? asset.size
          : (res.contentLength == null ? 0 : have + res.contentLength!);
      var received = have;
      final sink = part.openWrite(
        mode: resumed ? FileMode.append : FileMode.write,
      );
      try {
        await for (final chunk in res.stream.timeout(
          const Duration(seconds: 60),
        )) {
          sink.add(chunk);
          received += chunk.length;
          onProgress?.call(total > 0 ? received / total : -1);
        }
      } finally {
        await sink.close();
      }
    }
    final got = await part.length();
    if (asset.size > 0 && got != asset.size) {
      // Cortada: la próxima sigue desde aquí. Más grande de la cuenta: de cero.
      if (got > asset.size) await part.delete();
      throw const HttpException('La descarga se cortó');
    }
    return part.rename('${dir.path}/${asset.fileName}');
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
