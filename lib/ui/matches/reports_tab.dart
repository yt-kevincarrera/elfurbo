import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_messenger.dart';
import '../../core/formatters.dart';
import '../../core/theme.dart';
import '../../data/providers.dart';
import '../../models/app_user.dart';
import '../../models/match_day.dart';
import '../../models/match_report.dart';
import '../widgets/common.dart';
import '../widgets/player_avatar.dart';

class ReportsTab extends ConsumerWidget {
  const ReportsTab({super.key, required this.match});

  final MatchDay match;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = DateTime.now();
    if (!match.isPlayed(now)) {
      return EmptyState(
        icon: Icons.schedule,
        title: match.isCancelled ? 'Jornada cancelada' : 'Todavía no terminó',
        subtitle: match.isCancelled
            ? null
            : 'Cuando termine la jornada, aquí cargas tus goles y asistencias.',
      );
    }

    final reports = ref.watch(reportsForMatchProvider(match.id));
    final users = ref.watch(usersByIdProvider);
    final myUid = ref.watch(myUidProvider);
    final isAdmin = ref.watch(isAdminProvider);
    final closed = ref.watch(matchClosedProvider(match.id));
    final iPlayed = ref.watch(iAmPresentProvider(match.id));
    final myReport = reports.where((r) => r.uid == myUid).firstOrNull;
    final others = reports.where((r) => r.uid != myUid).toList();
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text('Tu reporte', style: text.titleMedium),
                    ),
                    if (myReport != null) ReportStatusChip(report: myReport),
                  ],
                ),
                const SizedBox(height: 8),
                if (myReport == null)
                  Text(
                    'Todavía no cargaste nada de esta jornada.',
                    style: text.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  )
                else
                  Text(
                    '${Fmt.goals(myReport.goals)} · ${Fmt.assists(myReport.assists)}'
                    '${myReport.note != null ? '\n“${myReport.note}”' : ''}',
                    style: text.bodyLarge,
                  ),
                if (myReport != null && myReport.isRejected)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      'El admin rechazó este reporte. Solo el admin puede reabrirlo.',
                      style: text.bodySmall?.copyWith(color: scheme.error),
                    ),
                  ),
                if (myReport != null && myReport.isPending)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      'Falta que lo confirmen ${MatchReport.confirmationsNeeded - myReport.confirmations.length} '
                      '${MatchReport.confirmationsNeeded - myReport.confirmations.length == 1 ? 'compañero' : 'compañeros'} o el admin.',
                      style: text.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    if (myReport == null || myReport.authorCanEdit)
                      FilledButton.icon(
                        onPressed: closed
                            ? null
                            : () => showReportFormSheet(
                                context,
                                match: match,
                                existing: myReport,
                              ),
                        icon: Icon(myReport == null ? Icons.add : Icons.edit),
                        label: Text(
                          myReport == null ? 'Cargar goles' : 'Editar',
                        ),
                      ),
                    if (myReport != null &&
                        myReport.authorCanEdit &&
                        !closed) ...[
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed: () => fireAndForget(
                          ref.read(repoProvider).deleteReport(myReport.id),
                          success: 'Reporte borrado',
                        ),
                        child: const Text('Borrar'),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
        SectionTitle('Compañeros (${others.length})'),
        if (others.isEmpty)
          Padding(
            padding: const EdgeInsets.all(20),
            child: Text(
              'Nadie más cargó todavía.',
              style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        if (!iPlayed && others.isNotEmpty && !closed)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(
              'Para confirmar a otros tienes que marcar "Jugué" en Asistencia.',
              style: text.bodySmall?.copyWith(color: scheme.pending),
            ),
          ),
        for (final r in others)
          _ReportTile(
            report: r,
            name: users[r.uid]?.name ?? 'Jugador',
            user: users[r.uid],
            canConfirm:
                !closed &&
                iPlayed &&
                r.isPending &&
                !r.confirmations.contains(myUid),
            alreadyConfirmed: r.confirmations.contains(myUid),
            isAdmin: isAdmin && !closed,
            confirmerNames: r.confirmations
                .map((u) => users[u]?.name ?? '?')
                .toList(),
          ),
      ],
    );
  }
}

class _ReportTile extends ConsumerWidget {
  const _ReportTile({
    required this.report,
    required this.name,
    required this.user,
    required this.canConfirm,
    required this.alreadyConfirmed,
    required this.isAdmin,
    required this.confirmerNames,
  });

  final MatchReport report;
  final String name;
  final AppUser? user;
  final bool canConfirm;
  final bool alreadyConfirmed;
  final bool isAdmin;
  final List<String> confirmerNames;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.read(repoProvider);
    final myUid = ref.watch(myUidProvider);
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                PlayerAvatar(user: user, radius: 18),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name, style: text.titleMedium),
                      Text(
                        '${Fmt.goals(report.goals)} · ${Fmt.assists(report.assists)}',
                        style: text.bodyMedium,
                      ),
                    ],
                  ),
                ),
                ReportStatusChip(report: report),
              ],
            ),
            if (report.note != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '“${report.note}”',
                  style: text.bodySmall?.copyWith(fontStyle: FontStyle.italic),
                ),
              ),
            if (confirmerNames.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Confirman: ${confirmerNames.join(', ')}',
                  style: text.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                if (canConfirm)
                  FilledButton.tonalIcon(
                    onPressed: () => fireAndForget(
                      repo.confirmReport(report.id, myUid),
                      success: 'Confirmaste a $name',
                    ),
                    icon: const Icon(Icons.thumb_up),
                    label: const Text('Es verdad'),
                  ),
                if (alreadyConfirmed && report.isPending)
                  Chip(
                    avatar: const Icon(Icons.check, size: 16),
                    label: const Text('Ya confirmaste'),
                    visualDensity: VisualDensity.compact,
                  ),
                if (isAdmin) ...[
                  OutlinedButton.icon(
                    onPressed: () {
                      final match = ref.read(matchByIdProvider(report.matchId));
                      if (match == null) return;
                      showReportFormSheet(
                        context,
                        match: match,
                        existing: report,
                        correctFor: name,
                      );
                    },
                    icon: const Icon(Icons.edit_note, size: 18),
                    label: const Text('Corregir'),
                  ),
                  if (report.adminStatus != ReportStatus.confirmed)
                    OutlinedButton.icon(
                      onPressed: () => fireAndForget(
                        repo.adminSetReportStatus(
                          report.id,
                          ReportStatus.confirmed,
                        ),
                      ),
                      icon: const Icon(Icons.verified, size: 18),
                      label: const Text('Confirmar (admin)'),
                    ),
                  if (report.adminStatus != ReportStatus.rejected)
                    OutlinedButton.icon(
                      onPressed: () => fireAndForget(
                        repo.adminSetReportStatus(
                          report.id,
                          ReportStatus.rejected,
                        ),
                      ),
                      icon: const Icon(Icons.block, size: 18),
                      label: const Text('Rechazar'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: scheme.error,
                      ),
                    ),
                  if (report.adminStatus != null)
                    TextButton(
                      onPressed: () => fireAndForget(
                        repo.adminSetReportStatus(report.id, null),
                      ),
                      child: const Text('Quitar decisión'),
                    ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Formulario para cargar/editar goles y asistencias propios, o para que el
/// admin corrija los de otro ([correctFor] = nombre del autor).
Future<void> showReportFormSheet(
  BuildContext context, {
  required MatchDay match,
  MatchReport? existing,
  String? correctFor,
}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) =>
        _ReportForm(match: match, existing: existing, correctFor: correctFor),
  );
}

class _ReportForm extends ConsumerStatefulWidget {
  const _ReportForm({required this.match, this.existing, this.correctFor});

  final MatchDay match;
  final MatchReport? existing;

  /// Si no es null, el admin está corrigiendo el reporte de este jugador.
  final String? correctFor;

  bool get isCorrection => correctFor != null;

  @override
  ConsumerState<_ReportForm> createState() => _ReportFormState();
}

class _ReportFormState extends ConsumerState<_ReportForm> {
  late int _goals = widget.existing?.goals ?? 0;
  late int _assists = widget.existing?.assists ?? 0;
  late final TextEditingController _note = TextEditingController(
    text: widget.existing?.note ?? '',
  );

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  void _save() {
    final repo = ref.read(repoProvider);
    final uid = ref.read(myUidProvider);
    if (widget.isCorrection) {
      fireAndForget(
        repo.adminCorrectReport(
          widget.existing!.id,
          goals: _goals,
          assists: _assists,
          correctedBy: uid,
        ),
        success: 'Reporte de ${widget.correctFor} corregido y confirmado',
      );
      Navigator.of(context).pop();
      return;
    }
    // Si reportas, jugaste: marcamos presencia para que puedas confirmar y votar.
    fireAndForget(repo.setPresence(widget.match.id, uid, true, setBy: uid));
    fireAndForget(
      repo.submitReport(
        matchId: widget.match.id,
        uid: uid,
        goals: _goals,
        assists: _assists,
        note: _note.text,
      ),
      success: widget.existing == null
          ? 'Reporte enviado. Ahora lo tienen que confirmar.'
          : 'Reporte actualizado. Vuelve a pendiente.',
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        0,
        20,
        20 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.isCorrection
                ? 'Corregir reporte de ${widget.correctFor}'
                : '¿Cómo te fue el ${Fmt.short(widget.match.date)}?',
            style: text.titleLarge,
          ),
          const SizedBox(height: 16),
          CounterField(
            label: 'Goles',
            value: _goals,
            icon: Icons.sports_soccer,
            onChanged: (v) => setState(() => _goals = v),
          ),
          const SizedBox(height: 8),
          CounterField(
            label: 'Asistencias',
            value: _assists,
            icon: Icons.handshake_outlined,
            onChanged: (v) => setState(() => _assists = v),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _note,
            decoration: const InputDecoration(
              labelText: 'Comentario (opcional)',
              hintText: 'Ej: uno de chilena',
            ),
            textCapitalization: TextCapitalization.sentences,
            maxLength: 120,
          ),
          if (widget.isCorrection)
            Text(
              'Queda confirmado por el admin con estos números.',
              style: text.bodySmall?.copyWith(color: scheme.primary),
            )
          else if (widget.existing != null && !widget.existing!.isPending)
            Text(
              'Si editas, el reporte vuelve a pendiente y hay que confirmarlo de nuevo.',
              style: text.bodySmall?.copyWith(color: scheme.pending),
            ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.send),
            label: Text(widget.isCorrection ? 'Corregir' : 'Enviar'),
          ),
        ],
      ),
    );
  }
}
