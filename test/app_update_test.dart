import 'package:elfurbo/domain/app_update.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('compareVersions', () {
    test('ordena por partes numéricas', () {
      expect(compareVersions('0.1.0', '0.2.0'), lessThan(0));
      expect(compareVersions('1.0.0', '0.9.9'), greaterThan(0));
      expect(compareVersions('0.10.0', '0.9.0'), greaterThan(0));
      expect(compareVersions('1.2.3', '1.2.3'), 0);
    });

    test('ignora prefijo v y número de build', () {
      expect(compareVersions('v1.2.3', '1.2.3+7'), 0);
      expect(compareVersions('v1.3', '1.2.9'), greaterThan(0));
    });
  });

  group('AppRelease.fromServerJson', () {
    // Lo que manda `GET /app/latest` en `release`.
    final json = <String, dynamic>{
      'tag': 'v0.2.0',
      'version': '0.2.0',
      'build': 4,
      'title': 'El Furbo 0.2.0',
      'notes': ' Notas de la versión ',
      'publishedAt': '2026-10-05T12:00:00Z',
      'assets': [
        {
          'abi': 'arm64-v8a',
          'name': 'app-arm64-v8a-release.apk',
          'url': 'https://api/app/apk/v0.2.0/arm64-v8a',
          'size': 100,
        },
        {
          'abi': 'armeabi-v7a',
          'name': 'app-armeabi-v7a-release.apk',
          'url': 'https://api/app/apk/v0.2.0/armeabi-v7a',
          'size': 90,
        },
        {
          'abi': 'x86_64',
          'name': 'app-x86_64-release.apk',
          'url': 'https://api/app/apk/v0.2.0/x86_64',
          'size': 110,
        },
      ],
    };

    test('parsea versión, notas y los APK', () {
      final r = AppRelease.fromServerJson(json);
      expect(r.version, '0.2.0');
      expect(r.notes, 'Notas de la versión');
      expect(r.assets.map((a) => a.name), [
        'app-arm64-v8a-release.apk',
        'app-armeabi-v7a-release.apk',
        'app-x86_64-release.apk',
      ]);
    });

    test(
      'el archivo en el teléfono lleva la versión (los APK se llaman igual)',
      () {
        final a = AppRelease.fromServerJson(json).assets.first;
        expect(a.tag, 'v0.2.0');
        expect(a.fileName, 'v0.2.0-app-arm64-v8a-release.apk');
      },
    );

    test('isNewerThan compara con la versión instalada', () {
      final r = AppRelease.fromServerJson(json);
      expect(r.isNewerThan('0.1.0+1'), isTrue);
      expect(r.isNewerThan('0.2.0+3'), isFalse);
      expect(r.isNewerThan('0.3.0'), isFalse);
    });

    test('elige el APK de la primera ABI soportada que exista', () {
      final r = AppRelease.fromServerJson(json);
      expect(
        r.assetFor(['arm64-v8a', 'armeabi-v7a'])?.url,
        'https://api/app/apk/v0.2.0/arm64-v8a',
      );
      expect(
        r.assetFor(['armeabi-v7a'])?.url,
        'https://api/app/apk/v0.2.0/armeabi-v7a',
      );
      expect(
        r.assetFor(['x86_64', 'x86'])?.url,
        'https://api/app/apk/v0.2.0/x86_64',
      );
    });

    test('sin APK para la ABI, null', () {
      final none = AppRelease.fromServerJson({...json, 'assets': []});
      expect(none.assetFor(['arm64-v8a']), isNull);
    });
  });
}
