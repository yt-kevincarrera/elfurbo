import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/session.dart';
import '../sync/club_data.dart';
import '../sync/sync_engine.dart';
import 'cloud_controller.dart';

/// El controlador de la cuenta. Se crea en `main.dart` (override).
final cloudProvider = Provider<CloudController>(
  (ref) => throw UnimplementedError('Override en main.dart'),
);

final sessionProvider = StreamProvider<Session?>((ref) async* {
  final cloud = ref.watch(cloudProvider);
  yield cloud.session;
  yield* cloud.sessionChanges;
});

final meProvider = StreamProvider<Me?>((ref) {
  final cloud = ref.watch(cloudProvider);
  ref.watch(sessionProvider);
  return cloud.watchMe();
});

/// El servidor elegido en el selector (el primero, si no se eligió ninguno).
class SelectedClub extends Notifier<String?> {
  @override
  String? build() => null;

  void select(String clubId) => state = clubId;
}

final selectedClubProvider = NotifierProvider<SelectedClub, String?>(
  SelectedClub.new,
);

final currentClubProvider = Provider<MyClub?>((ref) {
  final clubs = ref.watch(meProvider).value?.clubs ?? const [];
  if (clubs.isEmpty) return null;
  final chosen = ref.watch(selectedClubProvider);
  return clubs.where((c) => c.id == chosen).firstOrNull ?? clubs.first;
});

/// La vista de un servidor; se recalcula cada vez que cambia la cola o llega un pull.
final clubViewProvider = StreamProvider.family<ClubData, String>((
  ref,
  clubId,
) async* {
  final cloud = ref.watch(cloudProvider);
  ref.watch(sessionProvider);
  final engine = cloud.engine;
  yield await cloud.view(clubId);
  if (engine == null) return;
  await for (final _ in engine.changed) {
    yield await cloud.view(clubId);
  }
});

final syncStatusProvider = StreamProvider<SyncStatus>((ref) async* {
  final cloud = ref.watch(cloudProvider);
  ref.watch(sessionProvider);
  final engine = cloud.engine;
  if (engine == null) return;
  yield engine.last;
  yield* engine.status;
});
