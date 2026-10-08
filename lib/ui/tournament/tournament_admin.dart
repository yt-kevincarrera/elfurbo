import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_messenger.dart';
import '../../core/formatters.dart';
import '../../data/providers.dart';
import '../../data/tournament_providers.dart';
import '../../domain/club_roles.dart';
import '../../models/tournament.dart';
import '../admin/club_profile.dart';
import '../admin/invites.dart';
import '../admin/join_requests.dart';
import '../widgets/common.dart';
import '../widgets/expressive.dart';
import 'teams_screen.dart';

/// Admin de un torneo (organizadores): en qué va, las inscripciones, las
/// reglas y la gente. Todo menos invitar va por la cola de sync.
class TournamentAdminScreen extends ConsumerWidget {
  const TournamentAdminScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(tournamentProvider);
    final myRole = ref.watch(myRoleProvider);
    if (t == null) {
      return const Scaffold(body: LoadingView(message: 'Un momentico…'));
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Admin del torneo')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          _StatusSection(tournament: t),
          const _PendingTeams(),
          _RulesSection(tournament: t),
          if (canManageInvites(myRole)) const JoinRequestsSection(),
          if (canManageInvites(myRole)) const InvitesSection(),
          if (canManageClub(myRole)) const ClubProfileSection(),
        ],
      ),
    );
  }
}

class _StatusSection extends ConsumerWidget {
  const _StatusSection({required this.tournament});

  final Tournament tournament;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = tournament;
    final approved = ref
        .watch(teamsProvider)
        .where((x) => x.status == TeamStatus.approved)
        .length;
    final readOnly = ref.watch(clubReadOnlyProvider);
    final repo = ref.read(repoProvider);
    final text = Theme.of(context).textTheme;
    final (help, action, next) = switch (t.status) {
      TournamentStatus.draft => (
        'Prepara las reglas y, cuando quieras, abre la inscripción: '
            'cualquiera con la app podrá inscribir su equipo.',
        'Abrir inscripción',
        'registration',
      ),
      TournamentStatus.registration => (
        'Aprueba los equipos que van a jugar. Al empezar, los capitanes ya no '
            'tocan sus plantillas.',
        'Empezar el torneo',
        'in_progress',
      ),
      TournamentStatus.inProgress => (
        'En juego. El calendario y los resultados se manejan desde Partidos.',
        null,
        null,
      ),
      TournamentStatus.finished => ('Terminado.', null, null),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionTitle(t.status.label),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Text(
            '${t.format.label} · $approved de ${t.maxTeams} equipos aprobados'
            '${t.startsOn == null ? '' : ' · empieza ${Fmt.dayMonth(t.startsOn!)}'}\n$help',
            style: text.bodyMedium,
          ),
        ),
        if (action != null && !readOnly)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: FilledButton(
              onPressed: next == 'in_progress' && approved < 2
                  ? null
                  : () => fireAndForget(
                      repo.updateTournament(status: next),
                      success: next == 'registration'
                          ? '¡Inscripción abierta!'
                          : '¡A jugar!',
                    ),
              child: Text(action),
            ),
          ),
        if (next == 'in_progress' && approved < 2)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 6, 20, 0),
            child: Text(
              'Hacen falta al menos 2 equipos aprobados.',
              style: text.bodySmall,
            ),
          ),
      ],
    );
  }
}

class _PendingTeams extends ConsumerWidget {
  const _PendingTeams();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pending = ref
        .watch(teamsProvider)
        .where((t) => t.status == TeamStatus.pending)
        .toList();
    if (pending.isEmpty) return const SizedBox.shrink();
    final repo = ref.read(repoProvider);
    final rosters = ref.watch(rostersProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionTitle('Equipos por aprobar (${pending.length})'),
        GroupedSection(
          children: [
            for (final t in pending)
              ListTile(
                leading: TeamBadge(team: t),
                title: Text(t.name),
                subtitle: Text(
                  Fmt.plural(
                    rosters[t.id]?.length ?? 0,
                    'jugador',
                    'jugadores',
                  ),
                ),
                onTap: () => TeamDetailScreen.open(context, t.id),
                trailing: FilledButton(
                  onPressed: () => fireAndForget(
                    repo.setTeamStatus(t.id, 'approved'),
                    success: 'Listo, ${t.name} aprobado',
                  ),
                  child: const Text('Aprobar'),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// Formato, fechas, plantillas y reglas. Cada cambio se guarda al momento.
class _RulesSection extends ConsumerWidget {
  const _RulesSection({required this.tournament});

  final Tournament tournament;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = tournament;
    final r = t.rules;
    final readOnly =
        ref.watch(clubReadOnlyProvider) ||
        t.status == TournamentStatus.finished;
    final hasFixtures =
        (ref.watch(clubDataProvider).value?.all('fixture').isNotEmpty) ?? false;
    final repo = ref.read(repoProvider);
    final text = Theme.of(context).textTheme;

    void rules(Map<String, Object?> change) =>
        fireAndForget(repo.updateTournament(rules: change));

    Widget counter(
      String label,
      int value,
      int min,
      int max,
      void Function(int) onChanged,
    ) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: CounterField(
        label: label,
        value: value,
        min: min,
        max: max,
        onChanged: readOnly ? (_) {} : onChanged,
      ),
    );

    Future<void> pickDate(
      DateTime? current,
      void Function(DateTime) onPicked,
    ) async {
      final now = DateTime.now();
      final picked = await showDatePicker(
        context: context,
        initialDate: current ?? now,
        firstDate: now.subtract(const Duration(days: 1)),
        lastDate: now.add(const Duration(days: 365)),
      );
      if (picked != null) onPicked(picked);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionTitle('Formato y fechas'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SizedBox(
            width: double.infinity,
            child: SegmentedButton<TournamentFormat>(
              showSelectedIcon: false,
              selected: {t.format},
              onSelectionChanged: readOnly || hasFixtures
                  ? null
                  : (s) => fireAndForget(
                      repo.updateTournament(format: s.first.wire),
                    ),
              segments: [
                for (final f in TournamentFormat.values)
                  ButtonSegment(value: f, label: Text(f.label)),
              ],
            ),
          ),
        ),
        if (hasFixtures)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
            child: Text(
              'Ya hay calendario: para cambiar el formato, bórralo antes.',
              style: text.bodySmall,
            ),
          ),
        ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 20),
          title: const Text('Empieza'),
          subtitle: Text(
            t.startsOn == null ? 'Sin fecha' : Fmt.weekdayLong(t.startsOn!),
          ),
          trailing: const Icon(Icons.event),
          onTap: readOnly
              ? null
              : () => pickDate(
                  t.startsOn,
                  (d) => fireAndForget(repo.updateTournament(startsOn: d)),
                ),
        ),
        ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 20),
          title: const Text('La inscripción cierra'),
          subtitle: Text(
            t.registrationClosesAt == null
                ? 'Cuando empiece el torneo'
                : Fmt.weekdayLong(t.registrationClosesAt!),
          ),
          trailing: t.registrationClosesAt == null || readOnly
              ? const Icon(Icons.event_busy)
              : IconButton(
                  tooltip: 'Quitar la fecha',
                  icon: const Icon(Icons.clear),
                  onPressed: () => fireAndForget(
                    repo.updateTournament(clearRegistrationClose: true),
                  ),
                ),
          onTap: readOnly
              ? null
              : () => pickDate(
                  t.registrationClosesAt,
                  // Hasta el final de ese día.
                  (d) => fireAndForget(
                    repo.updateTournament(
                      registrationClosesAt: DateTime(
                        d.year,
                        d.month,
                        d.day,
                        23,
                        59,
                      ),
                    ),
                  ),
                ),
        ),
        const SectionTitle('Equipos y plantillas'),
        counter(
          'Equipos como mucho',
          t.maxTeams,
          2,
          32,
          (v) => fireAndForget(repo.updateTournament(maxTeams: v)),
        ),
        counter(
          'Jugadores mínimo',
          t.minPlayers,
          1,
          t.maxPlayers,
          (v) => fireAndForget(repo.updateTournament(minPlayers: v)),
        ),
        counter(
          'Jugadores máximo',
          t.maxPlayers,
          t.minPlayers,
          30,
          (v) => fireAndForget(repo.updateTournament(maxPlayers: v)),
        ),
        const SectionTitle('Reglas'),
        counter(
          'Puntos por ganar',
          r.pointsWin,
          0,
          10,
          (v) => rules({'pointsWin': v}),
        ),
        counter(
          'Puntos por empatar',
          r.pointsDraw,
          0,
          10,
          (v) => rules({'pointsDraw': v}),
        ),
        if (t.format != TournamentFormat.cup)
          counter('Vueltas', r.legs, 1, 2, (v) => rules({'legs': v})),
        if (t.format == TournamentFormat.groupsCup) ...[
          counter('Grupos', r.groups, 1, 8, (v) => rules({'groups': v})),
          counter(
            'Pasan por grupo',
            r.advancePerGroup,
            1,
            4,
            (v) => rules({'advancePerGroup': v}),
          ),
        ],
        if (t.format != TournamentFormat.league)
          SwitchListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 20),
            title: const Text('Partido por el tercer puesto'),
            value: r.thirdPlace,
            onChanged: readOnly ? null : (v) => rules({'thirdPlace': v}),
          ),
        counter(
          'Amarillas para suspender',
          r.yellowsForBan,
          0,
          10,
          (v) => rules({'yellowsForBan': v}),
        ),
        counter(
          'Partidos de suspensión por roja',
          r.redBanMatches,
          0,
          5,
          (v) => rules({'redBanMatches': v}),
        ),
        counter(
          'Jugadores en el terreno',
          r.playersOnField,
          3,
          11,
          (v) => rules({'playersOnField': v}),
        ),
        counter(
          'Minutos por partido',
          r.matchMinutes,
          10,
          120,
          (v) => rules({'matchMinutes': v}),
        ),
      ],
    );
  }
}
