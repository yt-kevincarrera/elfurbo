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

  group('AppRelease.fromGitHubJson', () {
    final json = <String, dynamic>{
      'tag_name': 'v0.2.0',
      'name': 'El Furbo 0.2.0',
      'body': 'Notas de la versión',
      'html_url': 'https://github.com/x/y/releases/tag/v0.2.0',
      'draft': false,
      'prerelease': false,
      'assets': [
        {
          'name': 'app-arm64-v8a-release.apk',
          'browser_download_url': 'https://dl/arm64.apk',
          'size': 100,
        },
        {
          'name': 'app-armeabi-v7a-release.apk',
          'browser_download_url': 'https://dl/v7a.apk',
          'size': 90,
        },
        {
          'name': 'app-x86_64-release.apk',
          'browser_download_url': 'https://dl/x64.apk',
          'size': 110,
        },
        {
          'name': 'app-release.apk.sha1',
          'browser_download_url': 'https://dl/sha',
          'size': 1,
        },
      ],
    };

    test('parsea versión, notas y solo assets .apk', () {
      final r = AppRelease.fromGitHubJson(json);
      expect(r.version, '0.2.0');
      expect(r.notes, 'Notas de la versión');
      expect(r.assets.map((a) => a.name), [
        'app-arm64-v8a-release.apk',
        'app-armeabi-v7a-release.apk',
        'app-x86_64-release.apk',
      ]);
    });

    test('isNewerThan compara con la versión instalada', () {
      final r = AppRelease.fromGitHubJson(json);
      expect(r.isNewerThan('0.1.0+1'), isTrue);
      expect(r.isNewerThan('0.2.0+3'), isFalse);
      expect(r.isNewerThan('0.3.0'), isFalse);
    });

    test('elige el APK de la primera ABI soportada que exista', () {
      final r = AppRelease.fromGitHubJson(json);
      expect(
        r.assetFor(['arm64-v8a', 'armeabi-v7a'])?.url,
        'https://dl/arm64.apk',
      );
      expect(r.assetFor(['armeabi-v7a'])?.url, 'https://dl/v7a.apk');
      expect(r.assetFor(['x86_64', 'x86'])?.url, 'https://dl/x64.apk');
    });

    test(
      'si no hay APK para la ABI usa el universal, y si no hay nada null',
      () {
        final universal = AppRelease.fromGitHubJson({
          ...json,
          'assets': [
            {
              'name': 'app-release.apk',
              'browser_download_url': 'https://dl/universal.apk',
              'size': 300,
            },
          ],
        });
        expect(
          universal.assetFor(['arm64-v8a'])?.url,
          'https://dl/universal.apk',
        );

        final none = AppRelease.fromGitHubJson({...json, 'assets': []});
        expect(none.assetFor(['arm64-v8a']), isNull);
      },
    );
  });
}
