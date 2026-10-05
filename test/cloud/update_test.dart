import 'dart:io';

import 'package:elfurbo/data/providers.dart';
import 'package:elfurbo/data/update_controller.dart';
import 'package:elfurbo/domain/app_update.dart';
import 'package:elfurbo/services/update_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _asset = ReleaseAsset(
  name: 'app-arm64-v8a-release.apk',
  url: 'https://example.test/app.apk',
  size: 100,
);
const _release = AppRelease(
  tag: 'v0.4.0',
  title: 'El Furbo 0.4.0',
  notes: 'Cosas nuevas',
  assets: [_asset],
);

/// Un servicio sin red ni plataforma: cada test decide qué responde.
class _FakeService extends UpdateService {
  AppRelease? known;
  AppRelease? remote;
  File? cached;
  Object? downloadError;
  final installed = <String>[];

  @override
  Future<AppRelease?> lastKnown() async => known;

  @override
  Future<AppRelease?> checkForUpdate({bool force = false}) async => remote;

  @override
  Future<ReleaseAsset?> assetForDevice(AppRelease release) async => _asset;

  @override
  Future<File?> cachedApk(ReleaseAsset asset) async => cached;

  @override
  Future<File> download(
    ReleaseAsset asset, {
    void Function(double progress)? onProgress,
  }) async {
    if (downloadError != null) throw downloadError!;
    for (final p in [0.25, 0.5, 1.0]) {
      onProgress?.call(p);
    }
    return cached = File('descargado.apk');
  }

  @override
  Future<void> install(File apk) async => installed.add(apk.path);
}

class _Alerts extends UpdateAlerts {
  final log = <String>[];

  @override
  Future<void> progress(AppRelease r, double p) async => log.add('progreso');
  @override
  Future<void> ready(AppRelease r) async => log.add('lista ${r.version}');
  @override
  Future<void> cancel() async => log.add('cancelar');
}

void main() {
  late _FakeService service;
  late _Alerts alerts;
  late ProviderContainer c;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    service = _FakeService();
    alerts = _Alerts();
    c = ProviderContainer(
      overrides: [
        updateServiceProvider.overrideWithValue(service),
        updateAlertsProvider.overrideWithValue(alerts),
      ],
    );
  });
  tearDown(() => c.dispose());

  UpdateState state() => c.read(updateProvider);
  UpdateController ctl() => c.read(updateProvider.notifier);

  test('la versión nueva que ya se conocía se ofrece sin red', () async {
    service.known = _release;
    await ctl().check();
    expect(state().phase, UpdatePhase.available);
    expect(state().pending, isTrue);
    expect(state().asset?.size, 100);
  });

  test(
    'descargar avanza hasta "lista", avisa y no depende de ningún diálogo',
    () async {
      service.remote = _release;
      await ctl().check(force: true);
      final seen = <double?>[];
      c.listen(updateProvider, (_, s) => seen.add(s.progress));
      await ctl().download();
      expect(state().phase, UpdatePhase.ready);
      expect(state().file?.path, 'descargado.apk');
      expect(seen, containsAllInOrder([0.25, 0.5, 1.0]));
      expect(alerts.log, contains('lista 0.4.0'));
      await ctl().install();
      expect(service.installed, ['descargado.apk']);
    },
  );

  test('si la descarga falla, se puede reintentar', () async {
    service.remote = _release;
    await ctl().check(force: true);
    service.downloadError = const SocketException('sin señal');
    await ctl().download();
    expect(state().phase, UpdatePhase.failed);
    expect(state().pending, isTrue, reason: 'el punto sigue');
    service.downloadError = null;
    await ctl().download();
    expect(state().phase, UpdatePhase.ready);
  });

  test(
    'si el worker ya la descargó, sale directo como "lista para instalar"',
    () async {
      service.known = _release;
      service.cached = File('de_fondo.apk');
      await ctl().check();
      expect(state().phase, UpdatePhase.ready);
      await ctl().install();
      expect(service.installed, ['de_fondo.apk']);
    },
  );

  test('sin versión nueva, nada pendiente', () async {
    await ctl().check(force: true);
    expect(state().pending, isFalse);
  });
}
