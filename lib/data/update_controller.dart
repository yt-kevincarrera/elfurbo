import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/app_update.dart';
import '../services/local_notifications.dart';
import '../services/update_service.dart';
import 'providers.dart';

/// En qué va la actualización de la app.
enum UpdatePhase {
  /// Estás en la última (o todavía no se sabe).
  none,

  /// Hay una versión nueva sin descargar.
  available,

  /// Descargándose (sigue aunque cierres el aviso).
  downloading,

  /// Descargada: falta instalarla.
  ready,

  /// Falló la descarga; se puede reintentar.
  failed,
}

@immutable
class UpdateState {
  const UpdateState({
    this.phase = UpdatePhase.none,
    this.release,
    this.asset,
    this.progress,
    this.file,
    this.error,
  });

  final UpdatePhase phase;
  final AppRelease? release;

  /// El APK para este teléfono (para decir cuánto pesa).
  final ReleaseAsset? asset;

  /// 0..1 mientras descarga; negativo si no se sabe el tamaño.
  final double? progress;
  final File? file;
  final Object? error;

  /// Hay algo que hacer (para el punto rojo y el aviso de la barra).
  bool get pending => phase != UpdatePhase.none;
}

/// Avisos del sistema de la actualización (en tests, uno que no hace nada).
class UpdateAlerts {
  const UpdateAlerts();

  Future<void> progress(AppRelease r, double p) =>
      LocalNotifications.showUpdateProgress(r, p);
  Future<void> ready(AppRelease r) => LocalNotifications.showUpdateReady(r);
  Future<void> cancel() => LocalNotifications.cancelUpdate();
}

final updateAlertsProvider = Provider<UpdateAlerts>(
  (ref) => const UpdateAlerts(),
);

/// La actualización de la app, para toda la app: el aviso de la barra, el
/// punto en Perfil y el diálogo leen de aquí, y la descarga no depende de que
/// el diálogo siga abierto.
class UpdateController extends Notifier<UpdateState> {
  @override
  UpdateState build() => const UpdateState();

  UpdateService get _service => ref.read(updateServiceProvider);
  UpdateAlerts get _alerts => ref.read(updateAlertsProvider);

  /// Mira si hay versión nueva: primero lo último que se supo (al instante y
  /// sin red) y, si toca o con [force], pregunta al servidor. Con [force] los
  /// errores de red llegan a quien llama.
  Future<void> check({bool force = false}) async {
    if (state.phase == UpdatePhase.downloading) return;
    final known = await _service.lastKnown();
    if (known != null && !state.pending) await _offer(known);
    final fresh = await _service.checkForUpdate(force: force);
    if (fresh != null) {
      await _offer(fresh);
    } else if (force && known == null) {
      state = const UpdateState();
    }
  }

  Future<void> _offer(AppRelease release) async {
    if (state.phase == UpdatePhase.downloading) return;
    final asset = await _service.assetForDevice(release);
    final cached = asset == null ? null : await _service.cachedApk(asset);
    state = cached != null
        ? UpdateState(
            phase: UpdatePhase.ready,
            release: release,
            asset: asset,
            file: cached,
          )
        : UpdateState(
            phase: UpdatePhase.available,
            release: release,
            asset: asset,
          );
  }

  /// Descarga la versión nueva, con su notificación de progreso. Si ya se
  /// está descargando, no hace nada.
  Future<void> download() async {
    final release = state.release;
    if (release == null || state.phase == UpdatePhase.downloading) return;
    final asset0 = state.asset;
    state = UpdateState(
      phase: UpdatePhase.downloading,
      release: release,
      asset: asset0,
      progress: 0,
    );
    try {
      final asset = await _service.assetForDevice(release);
      if (asset == null) {
        throw Exception('La versión nueva no trae un APK para este teléfono.');
      }
      var lastPct = -1;
      final file = await _service.download(
        asset,
        onProgress: (p) {
          state = UpdateState(
            phase: UpdatePhase.downloading,
            release: release,
            asset: asset,
            progress: p,
          );
          // La notificación, como mucho una vez por cada 1 %.
          final pct = (p * 100).floor();
          if (pct != lastPct) {
            lastPct = pct;
            unawaited(_quietly(() => _alerts.progress(release, p)));
          }
        },
      );
      state = UpdateState(
        phase: UpdatePhase.ready,
        release: release,
        asset: asset,
        file: file,
      );
      await _quietly(() => _alerts.ready(release));
      // Que el worker no vuelva a avisar "lista" de esta misma versión.
      await _quietly(
        () => UpdateService.markNotified(release.tag, kind: 'ready'),
      );
    } catch (e) {
      state = UpdateState(
        phase: UpdatePhase.failed,
        release: release,
        asset: asset0,
        error: e,
      );
      await _quietly(_alerts.cancel);
    }
  }

  /// Abre el instalador de Android (descarga antes si hace falta).
  Future<void> install() async {
    if (state.phase != UpdatePhase.ready) await download();
    final file = state.file;
    if (state.phase != UpdatePhase.ready || file == null) return;
    await _quietly(_alerts.cancel);
    await _service.install(file);
  }

  static Future<void> _quietly(Future<void> Function() f) async {
    try {
      await f();
    } catch (e) {
      debugPrint('Actualización: aviso no mostrado: $e');
    }
  }
}

final updateProvider = NotifierProvider<UpdateController, UpdateState>(
  UpdateController.new,
);
