import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_messenger.dart';
import '../../data/providers.dart';
import '../admin/admin_screen.dart';
import '../matches/matches_screen.dart';
import '../profile/player_profile_screen.dart';
import '../stats/leaderboard_screen.dart';
import '../widgets/common.dart';

class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  /// Índice de la pestaña Admin (solo existe si el usuario es admin).
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
    final isAdmin = ref.watch(isAdminProvider);
    final pending = ref.watch(pendingUsersProvider).length;
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
          const SyncBanner(),
          Expanded(
            child: IndexedStack(index: index, children: pages),
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
          const NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: 'Perfil',
          ),
          if (isAdmin)
            NavigationDestination(
              icon: Badge(
                isLabelVisible: pending > 0,
                label: Text('$pending'),
                child: const Icon(Icons.admin_panel_settings_outlined),
              ),
              selectedIcon: const Icon(Icons.admin_panel_settings),
              label: 'Admin',
            ),
        ],
      ),
    );
  }
}
