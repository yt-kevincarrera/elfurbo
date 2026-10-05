/// Lógica pura de actualización: qué release publica nuestro servidor
/// (`GET /app/latest`, que la lee de GitHub) y si es más nueva que lo instalado. Sin dependencias de Flutter para poder testearla.
library;

/// Compara dos versiones "x.y.z" (acepta prefijo `v` y sufijo `+build`, que
/// se ignora). Negativo si [a] < [b], 0 si son iguales, positivo si [a] > [b].
int compareVersions(String a, String b) {
  final pa = _parts(a);
  final pb = _parts(b);
  final n = pa.length > pb.length ? pa.length : pb.length;
  for (var i = 0; i < n; i++) {
    final x = i < pa.length ? pa[i] : 0;
    final y = i < pb.length ? pb[i] : 0;
    if (x != y) return x.compareTo(y);
  }
  return 0;
}

List<int> _parts(String version) {
  var v = version.trim();
  if (v.startsWith('v') || v.startsWith('V')) v = v.substring(1);
  final plus = v.indexOf('+');
  if (plus >= 0) v = v.substring(0, plus);
  return v
      .split('.')
      .map((p) => int.tryParse(p.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0)
      .toList();
}

class ReleaseAsset {
  const ReleaseAsset({
    required this.name,
    required this.url,
    required this.size,
    this.tag = '',
    this.sha256,
  });

  final String name;
  final String url;
  final int size;

  /// La versión a la que pertenece (los APK se llaman igual en todas).
  final String tag;

  /// Huella del APK (hex), si GitHub la da: se comprueba al terminar de bajarlo.
  final String? sha256;

  /// Nombre del archivo en el teléfono: con la versión, para que una descarga
  /// a medias de una versión no se continúe con los bytes de otra.
  String get fileName => tag.isEmpty ? name : '$tag-$name';
}

class AppRelease {
  const AppRelease({
    required this.tag,
    required this.title,
    required this.notes,
    required this.assets,
  });

  /// Construye desde `release` de `GET /app/latest`. Los APK se bajan de
  /// nuestro servidor (desde Cuba GitHub no abre).
  factory AppRelease.fromServerJson(Map<String, dynamic> json) {
    final tag = json['tag'] as String? ?? '';
    final rawAssets = (json['assets'] as List<dynamic>? ?? const [])
        .cast<Map<String, dynamic>>();
    return AppRelease(
      tag: tag,
      title: json['title'] as String? ?? '',
      notes: (json['notes'] as String? ?? '').trim(),
      assets: [
        for (final a in rawAssets)
          if ((a['name'] as String? ?? '').toLowerCase().endsWith('.apk'))
            ReleaseAsset(
              name: a['name'] as String,
              url: a['url'] as String? ?? '',
              size: (a['size'] as num?)?.toInt() ?? 0,
              tag: tag,
              sha256: a['sha256'] as String?,
            ),
      ],
    );
  }

  final String tag;
  final String title;
  final String notes;
  final List<ReleaseAsset> assets;

  /// Versión sin el prefijo `v` (lo que muestra la UI).
  String get version =>
      tag.startsWith('v') || tag.startsWith('V') ? tag.substring(1) : tag;

  bool isNewerThan(String installedVersion) =>
      compareVersions(tag, installedVersion) > 0;

  /// APK para el teléfono: primero el de la primera ABI soportada que exista
  /// (nombres de `flutter build apk --split-per-abi`), si no el universal.
  ReleaseAsset? assetFor(List<String> supportedAbis) {
    for (final abi in supportedAbis) {
      final name = 'app-$abi-release.apk';
      for (final a in assets) {
        if (a.name == name) return a;
      }
    }
    for (final a in assets) {
      if (a.name == 'app-release.apk') return a;
    }
    return null;
  }
}
