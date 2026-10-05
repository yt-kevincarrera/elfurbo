import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:elfurbo/domain/app_update.dart';
import 'package:elfurbo/services/update_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _apk = 'application/vnd.android.package-archive';
final _bytes = List<int>.generate(100, (i) => i);

final _sha = sha256.convert(_bytes).toString();

ReleaseAsset _asset({String tag = 'v0.6.0', int size = 100, String? sha}) =>
    ReleaseAsset(
      name: 'app-arm64-v8a-release.apk',
      url: 'https://api.test/app/apk/$tag/arm64-v8a',
      size: size,
      tag: tag,
      sha256: sha ?? _sha,
    );

void main() {
  late Directory dir;
  final ranges = <String?>[];

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('updates');
    ranges.clear();
  });
  tearDown(() => dir.delete(recursive: true));

  UpdateService service(
    Future<http.StreamedResponse> Function(http.BaseRequest) f,
  ) => UpdateService(
    client: MockClient.streaming((req, _) {
      ranges.add(req.headers['range']);
      return f(req);
    }),
    updatesDir: () async => dir,
  );

  http.StreamedResponse ok(
    List<int> body, {
    int status = 200,
    String type = _apk,
    String? range,
  }) => http.StreamedResponse(
    Stream.value(body),
    status,
    contentLength: body.length,
    headers: {'content-type': type, 'content-range': ?range},
  );

  File part([String tag = 'v0.6.0']) =>
      File('${dir.path}/$tag-app-arm64-v8a-release.apk.part');

  test(
    'descarga entera, con progreso, y la guarda con la versión en el nombre',
    () async {
      final progress = <double>[];
      final file = await service(
        (_) async => ok(_bytes),
      ).download(_asset(), onProgress: progress.add);
      expect(file.path, endsWith('v0.6.0-app-arm64-v8a-release.apk'));
      expect(await file.readAsBytes(), _bytes);
      expect(progress.last, 1);
      expect(ranges, [null]);
    },
  );

  test('una descarga cortada sigue donde se quedó (Range)', () async {
    await part().writeAsBytes(_bytes.sublist(0, 40));
    final file = await service(
      (_) async =>
          ok(_bytes.sublist(40), status: 206, range: 'bytes 40-99/100'),
    ).download(_asset());
    expect(ranges, ['bytes=40-']);
    expect(await file.readAsBytes(), _bytes);
    expect(part().existsSync(), isFalse);
  });

  test(
    'un 206 que no empieza donde se quedó no se pega al trozo: la próxima, de cero',
    () async {
      await part().writeAsBytes(_bytes.sublist(0, 40));
      await expectLater(
        service(
          (_) async =>
              ok(_bytes.sublist(30), status: 206, range: 'bytes 30-99/100'),
        ).download(_asset()),
        throwsA(isA<HttpException>()),
      );
      expect(part().existsSync(), isFalse);
    },
  );

  test(
    'si la huella no coincide (bytes mezclados), se borra y no se instala',
    () async {
      await expectLater(
        service(
          (_) async => ok(_bytes),
        ).download(_asset(sha: sha256.convert([1]).toString())),
        throwsA(isA<HttpException>()),
      );
      expect(dir.listSync(), isEmpty);
    },
  );

  test(
    'si el servidor ignora el Range y manda todo, se empieza de cero',
    () async {
      await part().writeAsBytes(List.filled(40, 9));
      final file = await service((_) async => ok(_bytes)).download(_asset());
      expect(await file.readAsBytes(), _bytes);
    },
  );

  test('cortada otra vez: queda el trozo para la próxima', () async {
    await expectLater(
      service((_) async => ok(_bytes.sublist(0, 60))).download(_asset()),
      throwsA(isA<HttpException>()),
    );
    expect(await part().length(), 60);
  });

  test('algo que no es un APK (el portal de un wifi) no se guarda', () async {
    await part().writeAsBytes(_bytes.sublist(0, 40));
    await expectLater(
      service(
        (_) async => ok(utf8.encode('<html>'), type: 'text/html'),
      ).download(_asset()),
      throwsA(isA<HttpException>()),
    );
    expect(await part().readAsBytes(), _bytes.sublist(0, 40));
  });

  test('lo de otra versión se borra; no se continúa con sus bytes', () async {
    await part('v0.5.0').writeAsBytes(_bytes.sublist(0, 40));
    await File(
      '${dir.path}/v0.5.0-app-arm64-v8a-release.apk',
    ).writeAsBytes(_bytes);
    await service((_) async => ok(_bytes)).download(_asset());
    expect(ranges, [null]);
    expect(dir.listSync().map((f) => f.uri.pathSegments.last), [
      'v0.6.0-app-arm64-v8a-release.apk',
    ]);
  });

  test('ya descargada: no vuelve a pedirla', () async {
    await File(
      '${dir.path}/v0.6.0-app-arm64-v8a-release.apk',
    ).writeAsBytes(_bytes);
    await service((_) async => ok(_bytes)).download(_asset());
    expect(ranges, isEmpty);
  });

  group('build mínimo', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      PackageInfo.setMockInitialValues(
        appName: 'El Furbo',
        packageName: 'app.elfurbo',
        version: '0.6.0',
        buildNumber: '9',
        buildSignature: '',
      );
    });

    Future<void> latest(int minBuild, {Map<String, Object?>? release}) =>
        UpdateService.fetchLatest(
          client: MockClient(
            (_) async => http.Response(
              jsonEncode({'minSupportedBuild': minBuild, 'release': release}),
              200,
            ),
          ),
        );

    test(
      'por debajo del mínimo que dice el servidor, hay que actualizar',
      () async {
        expect(await UpdateService.isOutdated(), isFalse);
        await latest(9);
        expect(await UpdateService.isOutdated(), isFalse);
        await latest(10);
        expect(await UpdateService.isOutdated(), isTrue);
      },
    );

    test('sin releases: null, y se olvida la que se conocía', () async {
      await latest(0, release: {'tag': 'v0.7.0', 'assets': []});
      expect(await UpdateService().lastKnown(), isNotNull);
      await latest(0);
      expect(await UpdateService().lastKnown(), isNull);
    });
  });
}
