import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../cloud/state/providers.dart';
import '../../cloud/ui/home_screens.dart';
import '../../data/providers.dart';
import '../../data/tournament_providers.dart';
import '../../models/tournament.dart';
import '../profile/global_stats.dart';
import '../widgets/common.dart';
import 'teams_screen.dart';
import 'tournament_admin.dart';

/// Lo que se ve con un torneo elegido: Partidos, Equipos, Perfil y (para los
/// organizadores) Admin. Las pestañas van en el mismo orden que las de un
/// servidor, así un aviso que pide "Admin" cae en la misma posición.
class TournamentShell extends ConsumerStatefulWidget {
  const TournamentShell({super.key, this.initialIndex = 0});

  final int initialIndex;

  @override
  ConsumerState<TournamentShell> createState() => _TournamentShellState();
}

class _TournamentShellState extends ConsumerState<TournamentShell> {
  late int _index = widget.initialIndex;

  @override
  Widget build(BuildContext context) {
    final isAdmin = ref.watch(isAdminProvider);
    final pages = <Widget>[
      const FixturesPlaceholder(),
      const TeamsScreen(),
      const TournamentProfileTab(),
      if (isAdmin) const TournamentAdminScreen(),
    ];
    final index = _index.clamp(0, pages.length - 1);
    return Scaffold(
      body: Column(
        children: [
          const ClubBar(),
          Expanded(
            child: MediaQuery.removePadding(
              context: context,
              removeTop: true,
              child: IndexedStack(index: index, children: pages),
            ),
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: [
          const NavigationDestination(
            icon: Icon(Icons.sports_soccer_outlined),
            selectedIcon: Icon(Icons.sports_soccer),
            label: 'Partidos',
          ),
          const NavigationDestination(
            icon: Icon(Icons.groups_outlined),
            selectedIcon: Icon(Icons.groups),
            label: 'Equipos',
          ),
          const NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: 'Perfil',
          ),
          if (isAdmin)
            const NavigationDestination(
              icon: Icon(Icons.admin_panel_settings_outlined),
              selectedIcon: Icon(Icons.admin_panel_settings),
              label: 'Admin',
            ),
        ],
      ),
    );
  }
}

/// Partidos: el calendario llega cuando el organizador lo genera.
class FixturesPlaceholder extends ConsumerWidget {
  const FixturesPlaceholder({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(tournamentProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Partidos')),
      body: EmptyState(
        icon: Icons.calendar_month_outlined,
        title: 'Todavía no hay calendario',
        subtitle: switch (t?.status) {
          TournamentStatus.draft ||
          TournamentStatus.registration => 'Sale cuando cierre la inscripción.',
          _ => 'El organizador lo genera desde Admin.',
        },
      ),
    );
  }
}

/// Mi perfil en el torneo: mi equipo y lo que llevo en toda la app.
class TournamentProfileTab extends ConsumerWidget {
  const TournamentProfileTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(meProvider).value?.user;
    final myTeam = ref.watch(myTeamProvider);
    final club = ref.watch(currentClubProvider);
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Mi perfil')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          ListTile(
            contentPadding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            title: Text(
              me?.displayName ?? '',
              style: text.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
            ),
            subtitle: Text(roleLabel(club?.role ?? 'player')),
          ),
          const SectionTitle('Mi equipo'),
          if (myTeam == null)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                'Todavía no estás en ningún equipo. Inscribe el tuyo en '
                'Equipos, o pídele a un capitán que te invite.',
              ),
            )
          else
            ListTile(
              leading: TeamBadge(team: myTeam),
              title: Text(myTeam.name),
              subtitle: Text(myTeam.status.label),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => TeamDetailScreen.open(context, myTeam.id),
            ),
          if (me != null) GlobalStatsSection(userId: me.id, isMe: true),
        ],
      ),
    );
  }
}
