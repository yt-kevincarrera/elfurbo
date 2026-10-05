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
import '../widgets/guest_dialog.dart';
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
            : 'Cuando termine la jornada, aquí pones tus goles y asistencias.',
      );
    }

    final reports = ref.watch(reportsForMatchProvider(match.id));
    final users = ref.watch(usersByIdProvider);
    final myUid = ref.watch(myUidProvider);
    final isAdmin = ref.watch(isAdminProvider);
    final isStaff = ref.watch(isStaffProvider);
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
                    'Todavía no has puesto nada de esta jornada.',
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
                      'Falta que lo confirmen ${myReport.confirmationsMissing} '
                      '${myReport.confirmationsMissing == 1 ? 'compañero' : 'compañeros'} o el admin.',
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
                          myReport == null ? 'Poner goles' : 'Editar',
                        ),
                      ),
                    if (myReport != null &&
                        myReport.authorCanEdit &&
                        !closed) ...[
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed: () => fireAndForget(
                          ref.read(repoProvider).deleteReport(match.id),
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
        if (isStaff && !closed)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: () => _loadForOther(context, ref, reports),
                icon: const Icon(Icons.person_add_alt),
                label: const Text('Poner goles de otro'),
              ),
            ),
          ),
        if (others.isEmpty)
          Padding(
            padding: const EdgeInsets.all(20),
            child: Text(
              'Nadie más ha puesto nada todavía.',
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
            canLoadFor: isStaff && !closed,
            confirmerNames: r.confirmations
                .map((u) => users[u]?.name ?? '?')
                .toList(),
          ),
      ],
    );
  }

  /// El staff elige a quién le pone los goles (con o sin cuenta).
  Future<void> _loadForOther(
    BuildContext context,
    WidgetRef ref,
    List<MatchReport> reports,
  ) async {
    final withReport = reports.map((r) => r.uid).toSet();
    final present = ref.read(presentUidsProvider(match.id));
    final candidates =
        ref
            .read(activeUsersProvider)
            .where((u) => !withReport.contains(u.uid))
            .toList()
          ..sort((a, b) {
            // Primero los que jugaron.
            final pa = present.contains(a.uid) ? 0 : 1;
            final pb = present.contains(b.uid) ? 0 : 1;
            return pa != pb ? pa - pb : a.name.compareTo(b.name);
          });
    final chosen = await showModalBottomSheet<AppUser>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              title: Text(
                '¿De quién?',
                style: Theme.of(ctx).textTheme.titleMedium,
              ),
            ),
            ListTile(
              leading: const Icon(Icons.person_add_alt),
              title: const Text('Uno nuevo, sin cuenta'),
              subtitle: const Text('Lo creas y le pones los goles'),
              onTap: () => Navigator.pop(ctx, _newGuest),
            ),
            for (final u in candidates)
              ListTile(
                leading: PlayerAvatar(user: u, radius: 16),
                title: Text(u.name),
                subtitle: Text(
                  [
                    if (present.contains(u.uid)) 'Jugó',
                    if (u.isGuest) 'Sin cuenta',
                  ].join(' · '),
                ),
                onTap: () => Navigator.pop(ctx, u),
              ),
          ],
        ),
      ),
    );
    if (chosen == null || !context.mounted) return;
    var member = chosen;
    if (identical(chosen, _newGuest)) {
      final name = await askGuestName(context);
      if (name == null || !context.mounted) return;
      // Se crea en la cola antes que sus goles: el servidor los aplica en orden.
      final id = await ref.read(repoProvider).createGuest(name);
      if (!context.mounted) return;
      member = AppUser(
        uid: id,
        displayName: name,
        role: UserRole.guest,
        status: UserStatus.active,
      );
    }
    await showReportFormSheet(context, match: match, forMember: member);
  }
}

/// Marca de "crear uno nuevo" en el selector de jugadores.
const _newGuest = AppUser(
  uid: '',
  displayName: '',
  role: UserRole.guest,
  status: UserStatus.active,
);

class _ReportTile extends ConsumerWidget {
  const _ReportTile({
    required this.report,
    required this.name,
    required this.user,
    required this.canConfirm,
    required this.alreadyConfirmed,
    required this.isAdmin,
    required this.canLoadFor,
    required this.confirmerNames,
  });

  final MatchReport report;
  final String name;
  final AppUser? user;
  final bool canConfirm;
  final bool alreadyConfirmed;
  final bool isAdmin;
  final bool canLoadFor;
  final List<String> confirmerNames;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.read(repoProvider);
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
                      repo.confirmReport(report.matchId, report.uid),
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
                // El anotador vuelve a poner los números de otro (salvo que el
                // admin ya los haya corregido o rechazado); el admin, corrige.
                if (canLoadFor &&
                    !isAdmin &&
                    !report.isRejected &&
                    !report.correctedByAdmin)
                  OutlinedButton.icon(
                    onPressed: () {
                      final match = ref.read(matchByIdProvider(report.matchId));
                      if (match == null || user == null) return;
                      showReportFormSheet(
                        context,
                        match: match,
                        existing: report,
                        forMember: user,
                      );
                    },
                    icon: const Icon(Icons.edit_note, size: 18),
                    label: const Text('Cambiar'),
                  ),
                if (isAdmin) ...[
                  OutlinedButton.icon(
                    onPressed: () {
                      final match = ref.read(matchByIdProvider(report.matchId));
                      if (match == null || user == null) return;
                      showReportFormSheet(
                        context,
                        match: match,
                        existing: report,
                        forMember: user,
                        correction: true,
                      );
                    },
                    icon: const Icon(Icons.edit_note, size: 18),
                    label: const Text('Corregir'),
                  ),
                  if (report.adminStatus != ReportStatus.confirmed)
                    OutlinedButton.icon(
                      onPressed: () => fireAndForget(
                        repo.decideReport(
                          report.matchId,
                          report.uid,
                          ReportStatus.confirmed,
                        ),
                      ),
                      icon: const Icon(Icons.verified, size: 18),
                      label: const Text('Confirmar (admin)'),
                    ),
                  if (report.adminStatus != ReportStatus.rejected)
                    OutlinedButton.icon(
                      onPressed: () => fireAndForget(
                        repo.decideReport(
                          report.matchId,
                          report.uid,
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
                        repo.decideReport(report.matchId, report.uid, null),
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

/// Formulario de goles y asistencias: los míos; los de [forMember] cuando los
/// pone alguien del staff; o, con [correction], la corrección de un admin
/// (queda confirmado).
Future<void> showReportFormSheet(
  BuildContext context, {
  required MatchDay match,
  MatchReport? existing,
  AppUser? forMember,
  bool correction = false,
}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _ReportForm(
      match: match,
      existing: existing,
      forMember: forMember,
      correction: correction,
    ),
  );
}

class _ReportForm extends ConsumerStatefulWidget {
  const _ReportForm({
    required this.match,
    this.existing,
    this.forMember,
    this.correction = false,
  });

  final MatchDay match;
  final MatchReport? existing;

  /// De quién son los números, si no son míos.
  final AppUser? forMember;
  final bool correction;

  bool get isCorrection => correction && existing != null;

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
    final other = widget.forMember;
    if (widget.isCorrection) {
      fireAndForget(
        repo.correctReport(
          widget.match.id,
          widget.existing!.uid,
          goals: _goals,
          assists: _assists,
        ),
        success:
            'Reporte de ${other?.name ?? 'Jugador'} corregido y confirmado',
      );
      Navigator.of(context).pop();
      return;
    }
    if (other != null) {
      fireAndForget(
        repo.loadReportFor(
          matchId: widget.match.id,
          memberId: other.uid,
          goals: _goals,
          assists: _assists,
          note: _note.text,
        ),
        success: 'Listo, goles de ${other.name} puestos',
      );
      Navigator.of(context).pop();
      return;
    }
    // Reportar también me marca "Jugué" (lo hace el servidor con el reporte).
    fireAndForget(
      repo.submitReport(
        matchId: widget.match.id,
        goals: _goals,
        assists: _assists,
        note: _note.text,
      ),
      success:
          ref.read(isStaffProvider) ||
              ref.read(clubSettingsProvider).reportValidation == 'trust'
          ? 'Listo, tus goles ya cuentan.'
          : widget.existing == null
          ? 'Listo, reporte enviado. Ahora te lo tienen que confirmar.'
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
                ? 'Corregir reporte de ${widget.forMember?.name ?? 'Jugador'}'
                : widget.forMember != null
                ? 'Goles de ${widget.forMember!.name}'
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
          else if (widget.forMember != null)
            Text(
              'Lo que pone el staff cuenta al momento, sin confirmaciones.',
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
