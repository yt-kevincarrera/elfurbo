import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../cloud/ui/home_screens.dart';
import '../../core/app_messenger.dart';
import '../../data/providers.dart';
import '../../data/update_controller.dart';
import '../admin/admin_screen.dart';
import '../matches/matches_screen.dart';
import '../profile/player_profile_screen.dart';
import '../stats/leaderboard_screen.dart';
import '../tournament/tournament_shell.dart';
import '../../cloud/state/providers.dart';

class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  /// Índice de la pestaña Admin (solo para owner y admin del servidor).
  static const adminTab = 3;

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    requestedHomeTab.addListener(_onTabRequested);
    _onTabRequested();
  }

  @override
  void dispose() {
    requestedHomeTab.removeListener(_onTabRequested);
    super.dispose();
  }

  /// Una notificación pidió mostrar una pestaña (por ejemplo Admin).
  void _onTabRequested() {
    final tab = requestedHomeTab.value;
    if (tab == null) return;
    requestedHomeTab.value = null;
    if (tab == HomeShell.adminTab && !ref.read(isAdminProvider)) return;
    setState(() => _index = tab);
  }

  @override
  Widget build(BuildContext context) {
    // Un torneo tiene sus propias pestañas.
    if (ref.watch(
      currentClubProvider.select((c) => c?.isTournament ?? false),
    )) {
      return TournamentShell(
        key: const ValueKey('torneo'),
        initialIndex: _index,
      );
    }
    final isAdmin = ref.watch(isAdminProvider);
    final updatePending = ref.watch(updateProvider.select((u) => u.pending));
    final myUid = ref.watch(myUidProvider);

    final pages = <Widget>[
      const MatchesScreen(),
      const LeaderboardScreen(),
      PlayerProfileScreen(uid: myUid, embedded: true),
      if (isAdmin) const AdminScreen(),
    ];
    final index = _index.clamp(0, pages.length - 1);

    return Scaffold(
      body: Column(
        children: [
          const ClubBar(),
          Expanded(
            // La barra del servidor ya ocupa la zona de la barra de estado.
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
            icon: Icon(Icons.calendar_month_outlined),
            selectedIcon: Icon(Icons.calendar_month),
            label: 'Jornadas',
          ),
          const NavigationDestination(
            icon: Icon(Icons.leaderboard_outlined),
            selectedIcon: Icon(Icons.leaderboard),
            label: 'Tabla',
          ),
          // El punto: hay una versión nueva (se actualiza desde Perfil o la barra).
          NavigationDestination(
            icon: Badge(
              isLabelVisible: updatePending,
              smallSize: 9,
              child: const Icon(Icons.person_outline),
            ),
            selectedIcon: Badge(
              isLabelVisible: updatePending,
              smallSize: 9,
              child: const Icon(Icons.person),
            ),
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
