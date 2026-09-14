/// Lógica pura de actualización: qué publica GitHub Releases y si es más nuevo
/// que lo instalado. Sin dependencias de Flutter para poder testearla.
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
  });

  final String name;
  final String url;
  final int size;
}

class AppRelease {
  const AppRelease({
    required this.tag,
    required this.title,
    required this.notes,
    required this.htmlUrl,
    required this.assets,
  });

  /// Construye desde el JSON de `GET /repos/{owner}/{repo}/releases/latest`.
  /// Solo conserva los assets `.apk`.
  factory AppRelease.fromGitHubJson(Map<String, dynamic> json) {
    final rawAssets = (json['assets'] as List<dynamic>? ?? const [])
        .cast<Map<String, dynamic>>();
    return AppRelease(
      tag: json['tag_name'] as String? ?? '',
      title: json['name'] as String? ?? '',
      notes: (json['body'] as String? ?? '').trim(),
      htmlUrl: json['html_url'] as String? ?? '',
      assets: [
        for (final a in rawAssets)
          if ((a['name'] as String? ?? '').toLowerCase().endsWith('.apk'))
            ReleaseAsset(
              name: a['name'] as String,
              url: a['browser_download_url'] as String? ?? '',
              size: (a['size'] as num?)?.toInt() ?? 0,
            ),
      ],
    );
  }

  final String tag;
  final String title;
  final String notes;
  final String htmlUrl;
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
