import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../cloud/state/providers.dart';
import '../../core/app_messenger.dart';
import '../../core/formatters.dart';
import '../../data/providers.dart';
import '../../data/tournament_providers.dart';
import '../../models/app_user.dart';
import '../../models/tournament.dart';
import '../widgets/chalk.dart';
import '../widgets/common.dart';
import '../widgets/expressive.dart';
import '../widgets/guest_dialog.dart';

/// La ficha de un equipo: su sigla en su color.
class TeamBadge extends StatelessWidget {
  const TeamBadge({super.key, required this.team, this.size = 40});

  final Team team;
  final double size;

  @override
  Widget build(BuildContext context) => ChalkToken(
    label: team.shortName,
    color: Chalk.club(team.color),
    filled: team.status != TeamStatus.withdrawn,
    dashed: team.status == TeamStatus.pending,
    size: size,
  );
}

/// Los equipos del torneo, e "Inscribir mi equipo" si la inscripción está
/// abierta. Funciona sin señal (salvo invitar).
class TeamsScreen extends ConsumerWidget {
  const TeamsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tournament = ref.watch(tournamentProvider);
    final teams = ref.watch(teamsProvider);
    final rosters = ref.watch(rostersProvider);
    final myTeam = ref.watch(myTeamProvider);
    final isAdmin = ref.watch(isAdminProvider);
    final role = ref.watch(myRoleProvider);
    final readOnly = ref.watch(clubReadOnlyProvider);
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    if (tournament == null) {
      return const Scaffold(body: LoadingView(message: 'Un momentico…'));
    }
    final approved = teams.where((t) => t.status == TeamStatus.approved);
    final canRegister =
        !readOnly &&
        myTeam == null &&
        role != UserRole.guest &&
        (isAdmin || tournament.registrationOpen(DateTime.now()));
    return Scaffold(
      appBar: AppBar(title: const Text('Equipos')),
      floatingActionButton: canRegister
          ? FloatingActionButton.extended(
              onPressed: () => showTeamForm(context, ref),
              icon: const Icon(Icons.group_add),
              label: Text(isAdmin ? 'Nuevo equipo' : 'Inscribir mi equipo'),
            )
          : null,
      body: ListView(
        padding: const EdgeInsets.only(bottom: 96),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
            child: Text(
              [
                tournament.status.label,
                '${approved.length} de ${tournament.maxTeams} equipos',
                if (tournament.registrationClosesAt != null &&
                    tournament.status == TournamentStatus.registration)
                  'cierra ${Fmt.short(tournament.registrationClosesAt!)}',
              ].join(' · '),
              style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          if (teams.isEmpty)
            const EmptyState(
              icon: Icons.groups_outlined,
              title: 'Todavía no hay equipos',
              subtitle: 'Cuando se inscriban, salen aquí.',
            )
          else
            GroupedSection(
              children: [
                for (final t in teams)
                  ListTile(
                    leading: TeamBadge(team: t),
                    title: Text(t.name),
                    subtitle: Text(
                      [
                        if (t.status != TeamStatus.approved) t.status.label,
                        Fmt.plural(
                          rosters[t.id]?.length ?? 0,
                          'jugador',
                          'jugadores',
                        ),
                        if (t.id == myTeam?.id) 'Tu equipo',
                      ].join(' · '),
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => TeamDetailScreen.open(context, t.id),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

/// Inscribir un equipo (o, si [team], editarlo). Va por la cola de sync.
Future<void> showTeamForm(BuildContext context, WidgetRef ref, {Team? team}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _TeamForm(team: team),
    );

class _TeamForm extends ConsumerStatefulWidget {
  const _TeamForm({this.team});

  final Team? team;

  @override
  ConsumerState<_TeamForm> createState() => _TeamFormState();
}

class _TeamFormState extends ConsumerState<_TeamForm> {
  late final _name = TextEditingController(text: widget.team?.name ?? '');
  late final _short = TextEditingController(text: widget.team?.shortName ?? '');
  late int _color = widget.team?.color ?? 0;
  final _form = GlobalKey<FormState>();

  @override
  void dispose() {
    _name.dispose();
    _short.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final repo = ref.read(repoProvider);
    final team = widget.team;
    Navigator.pop(context);
    if (team != null) {
      fireAndForget(
        repo.updateTeam(
          team.id,
          name: _name.text,
          shortName: _short.text,
          color: _color,
        ),
        success: 'Listo, equipo guardado',
      );
      return;
    }
    final isAdmin = ref.read(isAdminProvider);
    try {
      final id = await repo.createTeam(
        name: _name.text,
        shortName: _short.text,
        color: _color,
      );
      showMessage(
        isAdmin
            ? 'Listo, equipo creado'
            : '¡Inscrito! Falta que el organizador lo apruebe.',
      );
      // La hoja ya se cerró: se abre desde el navigator de la app.
      final context = rootNavigatorKey.currentContext;
      if (context != null && context.mounted) {
        TeamDetailScreen.open(context, id);
      }
    } catch (e) {
      showError(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        0,
        20,
        20 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.team == null ? 'Inscribir un equipo' : 'Editar el equipo',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _name,
              maxLength: 30,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Nombre'),
              validator: (v) =>
                  (v ?? '').trim().length < 2 ? 'Mínimo 2 caracteres' : null,
            ),
            TextFormField(
              controller: _short,
              maxLength: 4,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(
                labelText: 'Sigla',
                hintText: 'TIG',
              ),
              validator: (v) =>
                  RegExp(
                    r'^[A-Za-z0-9ÁÉÍÓÚÑáéíóúñ]{2,4}$',
                  ).hasMatch((v ?? '').trim())
                  ? null
                  : 'De 2 a 4 letras',
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 4,
              children: [
                for (var i = 0; i < Chalk.clubColors.length; i++)
                  InkResponse(
                    onTap: () => setState(() => _color = i),
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: CircleAvatar(
                        radius: 16,
                        backgroundColor: Chalk.clubColors[i],
                        child: i == _color
                            ? const Icon(Icons.check, color: Chalk.board)
                            : null,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: _save, child: const Text('Guardar')),
          ],
        ),
      ),
    );
  }
}

/// Un equipo: su plantilla con dorsales y capitán, y lo que puede hacer cada
/// uno (el capitán arma la plantilla mientras no empiece el torneo; los
/// organizadores, siempre).
class TeamDetailScreen extends ConsumerWidget {
  const TeamDetailScreen({super.key, required this.teamId});

  final String teamId;

  static Future<void> open(BuildContext context, String teamId) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => TeamDetailScreen(teamId: teamId),
        ),
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final team = ref.watch(teamByIdProvider(teamId));
    final tournament = ref.watch(tournamentProvider);
    final roster = ref.watch(rosterProvider(teamId));
    final users = ref.watch(usersByIdProvider);
    final myUid = ref.watch(myUidProvider);
    final isAdmin = ref.watch(isAdminProvider);
    final readOnly = ref.watch(clubReadOnlyProvider);
    final repo = ref.read(repoProvider);
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    if (team == null || tournament == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const EmptyState(
          icon: Icons.group_off,
          title: 'Ese equipo ya no está',
        ),
      );
    }
    final finished = tournament.status == TournamentStatus.finished;
    final captain = team.captainMemberId == myUid;
    final canEdit = !readOnly && !finished && (isAdmin || captain);
    final canRoster =
        !readOnly &&
        !finished &&
        team.status != TeamStatus.withdrawn &&
        (isAdmin || (captain && tournament.rostersOpen));
    final inTeam = roster.any((p) => p.memberId == myUid);
    final sorted = [...roster]
      ..sort((a, b) {
        if (a.memberId == team.captainMemberId) return -1;
        if (b.memberId == team.captainMemberId) return 1;
        return (a.shirt ?? 999).compareTo(b.shirt ?? 999);
      });

    return Scaffold(
      appBar: AppBar(
        title: Text(team.name),
        actions: [
          if (canEdit)
            IconButton(
              tooltip: 'Editar',
              icon: const Icon(Icons.edit_outlined),
              onPressed: () => showTeamForm(context, ref, team: team),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          ListTile(
            contentPadding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            leading: TeamBadge(team: team, size: 56),
            title: Text(
              team.name,
              style: text.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
            ),
            subtitle: Text(
              [
                team.status.label,
                '${roster.length} de ${tournament.maxPlayers} jugadores',
                if (roster.length < tournament.minPlayers &&
                    team.status != TeamStatus.withdrawn)
                  'faltan ${tournament.minPlayers - roster.length} para el mínimo',
              ].join(' · '),
            ),
          ),
          if (isAdmin && !readOnly && !finished)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
              child: Wrap(
                spacing: 8,
                children: [
                  if (team.status == TeamStatus.pending)
                    FilledButton.icon(
                      onPressed: () => fireAndForget(
                        repo.setTeamStatus(team.id, 'approved'),
                        success: 'Listo, ${team.name} aprobado',
                      ),
                      icon: const Icon(Icons.check),
                      label: const Text('Aprobar'),
                    ),
                  if (team.status != TeamStatus.withdrawn)
                    OutlinedButton(
                      onPressed: () => _withdraw(context, ref, team),
                      child: const Text('Retirar'),
                    ),
                ],
              ),
            ),
          SectionTitle(
            'Plantilla',
            trailing: canRoster
                ? TextButton.icon(
                    onPressed: () => _addPlayer(context, ref, team),
                    icon: const Icon(Icons.person_add_alt),
                    label: const Text('Añadir'),
                  )
                : null,
          ),
          GroupedSection(
            children: [
              for (final p in sorted)
                ListTile(
                  leading: CircleAvatar(
                    child: Text(p.shirt == null ? '–' : '${p.shirt}'),
                  ),
                  title: Text(users[p.memberId]?.name ?? 'Jugador'),
                  subtitle: Text(
                    [
                      if (p.memberId == team.captainMemberId) 'Capitán',
                      if (users[p.memberId]?.isGuest ?? false) 'Sin cuenta',
                      if (p.memberId == myUid) 'Tú',
                    ].join(' · '),
                  ),
                  trailing: (canEdit || p.memberId == myUid) && !finished
                      ? _PlayerMenu(
                          team: team,
                          player: p,
                          canRoster: canRoster,
                          canEdit: canEdit,
                          isMe: p.memberId == myUid,
                          rostersOpen: tournament.rostersOpen,
                        )
                      : null,
                ),
            ],
          ),
          if (canRoster)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
              child: OutlinedButton.icon(
                onPressed: () => _invite(context, ref, team),
                icon: const Icon(Icons.share),
                label: const Text('Invitar a mi equipo'),
              ),
            ),
          if (captain &&
              !isAdmin &&
              tournament.rostersOpen &&
              team.status != TeamStatus.withdrawn)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: TextButton(
                onPressed: () => _withdraw(context, ref, team),
                child: Text(
                  'Retirar el equipo',
                  style: TextStyle(color: scheme.error),
                ),
              ),
            ),
          if (!inTeam && roster.isEmpty)
            Padding(
              padding: const EdgeInsets.all(20),
              child: Text(
                'Todavía no tiene jugadores.',
                style: text.bodyMedium,
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _withdraw(BuildContext context, WidgetRef ref, Team team) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('¿Retirar ${team.name}?'),
        content: const Text(
          'Sale del torneo y su plantilla queda libre. No se puede deshacer.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Retirar'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    fireAndForget(
      ref.read(repoProvider).setTeamStatus(team.id, 'withdrawn'),
      success: 'Listo, ${team.name} se retiró',
    );
  }

  Future<void> _addPlayer(BuildContext context, WidgetRef ref, Team team) =>
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => _AddPlayerSheet(team: team),
      );

  Future<void> _invite(BuildContext context, WidgetRef ref, Team team) async {
    final club = ref.read(currentClubProvider);
    final tournament = ref.read(tournamentProvider);
    if (club == null || tournament == null) return;
    final api = ref.read(clubAdminApiProvider);
    try {
      final invite = await api.createInvite(
        club.id,
        maxUses: tournament.maxPlayers,
        expiresInDays: 14,
        teamId: team.id,
      );
      await SharePlus.instance.share(
        ShareParams(
          text:
              '¿Qué bolá? Te invito a jugar con ${team.name} en ${club.name} '
              '(El Furbo).\nCódigo: ${invite.code}\n'
              '${api.inviteLink(invite.code)}',
        ),
      );
    } catch (e) {
      showError(e);
    }
  }
}

class _PlayerMenu extends ConsumerWidget {
  const _PlayerMenu({
    required this.team,
    required this.player,
    required this.canRoster,
    required this.canEdit,
    required this.isMe,
    required this.rostersOpen,
  });

  final Team team;
  final TeamPlayer player;
  final bool canRoster;
  final bool canEdit;
  final bool isMe;
  final bool rostersOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.read(repoProvider);
    final captain = player.memberId == team.captainMemberId;
    return PopupMenuButton<String>(
      onSelected: (v) async {
        switch (v) {
          case 'shirt':
            final shirt = await _askShirt(context, player.shirt);
            if (shirt == null) return;
            fireAndForget(
              repo.setShirt(team.id, player.memberId, shirt < 0 ? null : shirt),
              success: 'Listo, dorsal guardado',
            );
          case 'captain':
            fireAndForget(
              repo.updateTeam(team.id, captainMemberId: player.memberId),
              success: 'Listo, nuevo capitán',
            );
          case 'remove':
            fireAndForget(
              repo.removeTeamPlayer(team.id, player.memberId),
              success: 'Listo, fuera de la plantilla',
            );
          case 'leave':
            fireAndForget(
              repo.leaveTeam(team.id),
              success: 'Listo, te saliste del equipo',
            );
        }
      },
      itemBuilder: (_) => [
        if (canEdit || isMe)
          const PopupMenuItem(value: 'shirt', child: Text('Poner dorsal')),
        if (canEdit && !captain)
          const PopupMenuItem(value: 'captain', child: Text('Hacer capitán')),
        if (canRoster && !captain)
          const PopupMenuItem(value: 'remove', child: Text('Sacar del equipo')),
        if (isMe && !captain && rostersOpen && !canRoster)
          const PopupMenuItem(value: 'leave', child: Text('Salirme')),
      ],
    );
  }

  /// El dorsal (0–99), -1 para quitarlo, o null si se cancela.
  static Future<int?> _askShirt(BuildContext context, int? current) {
    final controller = TextEditingController(text: current?.toString() ?? '');
    return showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Dorsal'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          maxLength: 2,
          decoration: const InputDecoration(hintText: 'Del 0 al 99'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, -1),
            child: const Text('Sin dorsal'),
          ),
          FilledButton(
            onPressed: () {
              final n = int.tryParse(controller.text.trim());
              if (n != null && n >= 0 && n <= 99) Navigator.pop(ctx, n);
            },
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
  }
}

/// Añadir a la plantilla: un miembro del torneo sin equipo, o un jugador sin
/// cuenta nuevo.
class _AddPlayerSheet extends ConsumerWidget {
  const _AddPlayerSheet({required this.team});

  final Team team;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final members = ref.watch(activeUsersProvider);
    final rosters = ref.watch(rostersProvider);
    final taken = {
      for (final r in rosters.values)
        for (final p in r) p.memberId,
    };
    final free = members.where((m) => !taken.contains(m.uid)).toList();
    final repo = ref.read(repoProvider);
    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.only(bottom: 16),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(
              'Añadir a ${team.name}',
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          // Crear jugadores sin cuenta es del staff.
          if (ref.watch(isStaffProvider))
            ListTile(
              leading: const Icon(Icons.person_add_alt),
              title: const Text('Jugador sin cuenta'),
              subtitle: const Text('Después puede reclamar su perfil'),
              onTap: () async {
                final name = await askGuestName(context);
                if (name == null) return;
                try {
                  final id = await repo.createGuest(name);
                  await repo.addTeamPlayer(team.id, id);
                  showMessage('Listo, $name en la plantilla');
                } catch (e) {
                  showError(e);
                }
                if (context.mounted) Navigator.pop(context);
              },
            ),
          if (free.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Todos los del torneo ya tienen equipo. Invita a más gente con '
                '"Invitar a mi equipo".',
              ),
            ),
          for (final m in free)
            ListTile(
              leading: CircleAvatar(child: Text(m.name.characters.first)),
              title: Text(m.name),
              onTap: () {
                Navigator.pop(context);
                fireAndForget(
                  repo.addTeamPlayer(team.id, m.uid),
                  success: 'Listo, ${m.name} en la plantilla',
                );
              },
            ),
        ],
      ),
    );
  }
}
