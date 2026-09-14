import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_messenger.dart';
import '../../core/formatters.dart';
import '../../data/providers.dart';
import '../../models/match_day.dart';
import '../widgets/common.dart';
import 'attendance_tab.dart';
import 'match_form_sheet.dart';
import 'mvp_tab.dart';
import 'reports_tab.dart';
import 'summary_tab.dart';
import 'teams_tab.dart';

class MatchDetailScreen extends ConsumerWidget {
  const MatchDetailScreen({super.key, required this.matchId});

  final String matchId;

  static Future<void> open(BuildContext context, String matchId) {
    return Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => MatchDetailScreen(matchId: matchId)),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final match = ref.watch(matchByIdProvider(matchId));
    final isAdmin = ref.watch(isAdminProvider);
    if (match == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const EmptyState(
          icon: Icons.event_busy,
          title: 'Esta jornada ya no existe',
        ),
      );
    }
    final now = DateTime.now();
    final played = match.isPlayed(now);
    final closed = ref.watch(matchClosedProvider(matchId));
    final season = ref.watch(seasonByIdProvider(match.seasonId));
    final scheme = Theme.of(context).colorScheme;
    // Antes de la jornada lo importante es la asistencia y los equipos;
    // después, cargar goles y votar.
    final initialTab = played ? 1 : 0;

    return DefaultTabController(
      length: 5,
      initialIndex: initialTab,
      child: Scaffold(
        appBar: AppBar(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                match.isInProgress(now)
                    ? 'En curso'
                    : Fmt.relative(match.date, now: now),
                style: const TextStyle(fontSize: 18),
              ),
              Text(
                [
                  Fmt.dayMonth(match.date),
                  Fmt.time(match.date),
                  if (match.place != null) match.place!,
                ].join(' · '),
                style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
          actions: [
            if (isAdmin)
              PopupMenuButton<_AdminAction>(
                onSelected: (a) => _onAdminAction(context, ref, match, a),
                itemBuilder: (_) => [
                  const PopupMenuItem(
                    value: _AdminAction.edit,
                    child: ListTile(
                      leading: Icon(Icons.edit),
                      title: Text('Editar'),
                    ),
                  ),
                  if (!match.isCancelled)
                    PopupMenuItem(
                      value: _AdminAction.toggleClose,
                      child: ListTile(
                        leading: Icon(
                          closed ? Icons.lock_open : Icons.lock_outline,
                        ),
                        title: Text(
                          closed ? 'Reabrir jornada' : 'Cerrar jornada',
                        ),
                        subtitle: closed && (season?.isClosed ?? false)
                            ? const Text('La temporada está cerrada')
                            : null,
                        enabled: !(closed && (season?.isClosed ?? false)),
                      ),
                    ),
                  PopupMenuItem(
                    value: _AdminAction.toggleCancel,
                    child: ListTile(
                      leading: Icon(
                        match.isCancelled
                            ? Icons.event_available
                            : Icons.event_busy,
                      ),
                      title: Text(
                        match.isCancelled ? 'Reactivar' : 'Cancelar jornada',
                      ),
                    ),
                  ),
                  const PopupMenuItem(
                    value: _AdminAction.delete,
                    child: ListTile(
                      leading: Icon(Icons.delete_outline),
                      title: Text('Eliminar'),
                    ),
                  ),
                ],
              ),
          ],
          bottom: const TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(text: 'Asistencia'),
              Tab(text: 'Goles'),
              Tab(text: 'MVP'),
              Tab(text: 'Equipos'),
              Tab(text: 'Resumen'),
            ],
          ),
        ),
        body: Column(
          children: [
            if (match.isCancelled)
              MaterialBanner(
                content: const Text('Esta jornada está cancelada.'),
                leading: const Icon(Icons.event_busy),
                actions: const [SizedBox.shrink()],
              )
            else if (closed)
              MaterialBanner(
                content: Text(
                  (season?.isClosed ?? false)
                      ? 'Temporada cerrada: esta jornada ya no acepta cambios.'
                      : 'Jornada cerrada: ya no se pueden cargar goles, confirmar ni votar.',
                ),
                leading: const Icon(Icons.lock_outline),
                actions: const [SizedBox.shrink()],
              ),
            if (match.notes != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Row(
                  children: [
                    Icon(Icons.notes, size: 16, color: scheme.onSurfaceVariant),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        match.notes!,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: TabBarView(
                children: [
                  AttendanceTab(match: match),
                  ReportsTab(match: match),
                  MvpTab(match: match),
                  TeamsTab(match: match),
                  SummaryTab(match: match),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _onAdminAction(
    BuildContext context,
    WidgetRef ref,
    MatchDay match,
    _AdminAction action,
  ) async {
    final repo = ref.read(repoProvider);
    switch (action) {
      case _AdminAction.edit:
        await showMatchFormSheet(context, existing: match);
      case _AdminAction.toggleClose:
        final closed = ref.read(matchClosedProvider(match.id));
        fireAndForget(
          repo.setMatchStatus(
            match.id,
            closed ? MatchStatus.reopened : MatchStatus.closed,
          ),
          success: closed
              ? 'Jornada reabierta: se cierra cuando la vuelvas a cerrar'
              : 'Jornada cerrada',
        );
      case _AdminAction.toggleCancel:
        fireAndForget(
          repo.setMatchStatus(
            match.id,
            match.isCancelled ? MatchStatus.scheduled : MatchStatus.cancelled,
          ),
          success: match.isCancelled
              ? 'Jornada reactivada'
              : 'Jornada cancelada',
        );
      case _AdminAction.delete:
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('¿Eliminar jornada?'),
            content: const Text(
              'Se borran también sus asistencias, reportes y votos. Si solo se suspendió, mejor cancélala.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Volver'),
              ),
              FilledButton.tonal(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Eliminar'),
              ),
            ],
          ),
        );
        if (ok == true && context.mounted) {
          final attendance = ref.read(attendanceForMatchProvider(match.id));
          final reports = ref.read(reportsForMatchProvider(match.id));
          final votes = ref.read(votesForMatchProvider(match.id));
          fireAndForget(
            repo.deleteMatchCascade(
              match.id,
              attendanceIds: attendance.values.map(
                (a) => '${a.matchId}_${a.uid}',
              ),
              reportIds: reports.map((r) => r.id),
              voteIds: votes.map((v) => '${v.matchId}_${v.voterUid}'),
            ),
            success: 'Jornada eliminada',
          );
          Navigator.of(context).pop();
        }
    }
  }
}

enum _AdminAction { edit, toggleClose, toggleCancel, delete }
