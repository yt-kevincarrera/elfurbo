import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../data/club_repo.dart';
import '../../models/attendance.dart';
import '../../models/notification_payload.dart';
import '../../services/notification_router.dart';
import '../../ui/widgets/club_token.dart';
import '../../ui/widgets/common.dart';
import '../../ui/widgets/expressive.dart';
import '../state/cloud_controller.dart';
import '../state/providers.dart';
import '../sync/agenda.dart';
import '../sync/alerts.dart';
import 'clubs_screens.dart';
import 'home_screens.dart';

/// Las vistas locales de todos mis servidores, para la agenda y los números
/// de pendientes. Las que todavía no llegaron no están.
final _sourcesProvider = Provider<List<AgendaSource>>((ref) {
  final clubs = ref.watch(meProvider).value?.clubs ?? const <MyClub>[];
  return [
    for (final c in clubs)
      if (ref.watch(clubViewProvider(c.id)).value case final data?)
        (data: data, myMemberId: c.memberId),
  ];
});

/// Lo que tengo pendiente en cada servidor (ver `pendingCount`).
final pendingByClubProvider = Provider<Map<String, int>>((ref) {
  final now = DateTime.now();
  return {
    for (final s in ref.watch(_sourcesProvider))
      s.data.clubId: pendingCount(s.data, myMemberId: s.myMemberId, now: now),
  };
});

/// Las jornadas de los próximos 14 días de todos mis servidores.
final agendaProvider = Provider<List<AgendaItem>>(
  (ref) => agendaItems(ref.watch(_sourcesProvider), now: DateTime.now()),
);

/// La hoja "Tus servidores": la agenda común, mis servidores y torneos con lo
/// que tengo pendiente en cada uno, y entrar en otro.
Future<void> showClubPicker(BuildContext context) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => const _ClubPickerSheet(),
);

class _ClubPickerSheet extends ConsumerWidget {
  const _ClubPickerSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final clubs = ref.watch(meProvider).value?.clubs ?? const <MyClub>[];
    final current = ref.watch(currentClubProvider);
    final pending = ref.watch(pendingByClubProvider);
    final agenda = ref.watch(agendaProvider);
    final scheme = Theme.of(context).colorScheme;
    final groups = clubs.where((c) => !c.isTournament).toList();
    final tournaments = clubs.where((c) => c.isTournament).toList();

    Widget tile(MyClub c) {
      final n = pending[c.id] ?? 0;
      final selected = c.id == current?.id;
      return ListTile(
        selected: selected,
        selectedTileColor: scheme.secondaryContainer,
        leading: ClubToken(
          name: c.name,
          color: c.color,
          tournament: c.isTournament,
        ),
        title: Text(c.name, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          [
            roleLabel(c.role),
            if (c.official) 'Oficial',
            if (c.status == 'suspended') 'Suspendido',
          ].join(' · '),
        ),
        trailing: n > 0
            ? Badge.count(count: n, largeSize: 22)
            : selected
            ? const Icon(Icons.check)
            : null,
        onTap: () {
          Navigator.pop(context);
          ref.read(selectedClubProvider.notifier).select(c.id);
        },
      );
    }

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: .6,
      maxChildSize: .92,
      builder: (context, controller) => ListView(
        controller: controller,
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(
              'Tus servidores',
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          GroupedSection(
            children: [
              ListTile(
                leading: const Icon(Icons.event_note),
                title: const Text('Agenda de todos'),
                subtitle: Text(
                  agenda.isEmpty
                      ? 'Nada en los próximos 14 días'
                      : agenda.length == 1
                      ? '1 jornada en los próximos 14 días'
                      : '${agenda.length} jornadas en los próximos 14 días',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  Navigator.pop(context);
                  AgendaScreen.open(context);
                },
              ),
            ],
          ),
          if (groups.isNotEmpty) ...[
            const SectionTitle('Servidores'),
            GroupedSection(children: [for (final c in groups) tile(c)]),
          ],
          if (tournaments.isNotEmpty) ...[
            const SectionTitle('Torneos'),
            GroupedSection(children: [for (final c in tournaments) tile(c)]),
          ],
          const SizedBox(height: 8),
          GroupedSection(
            children: [
              ListTile(
                leading: const Icon(Icons.vpn_key_outlined),
                title: const Text('Unirme con un código'),
                onTap: () {
                  Navigator.pop(context);
                  showJoinWithCode(context);
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Las jornadas de los próximos días de todos mis servidores, con "Voy",
/// "Quizás" y "No voy" ahí mismo. Funciona sin señal.
class AgendaScreen extends ConsumerWidget {
  const AgendaScreen({super.key});

  static Future<void> open(BuildContext context) => Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => const AgendaScreen()));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(agendaProvider);
    final run = ref.read(cloudProvider).run;
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;

    final byDay = <DateTime, List<AgendaItem>>{};
    for (final i in items) {
      final local = i.startsAt.toLocal();
      byDay
          .putIfAbsent(DateTime(local.year, local.month, local.day), () => [])
          .add(i);
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Agenda de todos')),
      body: items.isEmpty
          ? const EmptyState(
              icon: Icons.event_available,
              title: 'Nada a la vista',
              subtitle:
                  'Cuando haya jornadas en tus servidores en los próximos 14 '
                  'días, salen aquí.',
            )
          : ListView(
              padding: const EdgeInsets.only(bottom: 32),
              children: [
                for (final day in byDay.entries) ...[
                  SectionTitle(_dayLabel(day.key)),
                  GroupedSection(
                    children: [
                      for (final i in day.value)
                        ListTile(
                          leading: ClubToken(
                            name: i.clubName,
                            color: i.clubColor,
                            size: 36,
                          ),
                          title: Text(
                            [
                              DateFormat.Hm('es').format(i.startsAt.toLocal()),
                              ?i.place,
                            ].join(' · '),
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${i.clubName} · '
                                '${i.going == 1 ? '1 va' : '${i.going} van'}',
                                style: text.bodySmall?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                              const SizedBox(height: 6),
                              _IntentButtons(
                                value: i.myIntent,
                                onChanged: (v) => ClubRepo(run, i.clubId)
                                    .setIntent(i.matchdayId, v)
                                    .catchError((Object _) {}),
                              ),
                            ],
                          ),
                          isThreeLine: true,
                          onTap: () {
                            Navigator.of(context).pop();
                            NotificationRouter.handle(
                              NotificationPayload(
                                kind: NotificationKind.matchDay,
                                clubId: i.clubId,
                                matchId: i.matchdayId,
                              ),
                            );
                          },
                        ),
                    ],
                  ),
                ],
              ],
            ),
    );
  }

  static String _dayLabel(DateTime day) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final diff = day.difference(today).inDays;
    if (diff == 0) return 'Hoy';
    if (diff == 1) return 'Mañana';
    final s = DateFormat("EEEE d 'de' MMMM", 'es').format(day);
    return s[0].toUpperCase() + s.substring(1);
  }
}

class _IntentButtons extends StatelessWidget {
  const _IntentButtons({required this.value, required this.onChanged});

  final String? value;
  final void Function(AttendanceStatus?) onChanged;

  @override
  Widget build(BuildContext context) {
    Widget chip(AttendanceStatus s, String label) => Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ChoiceChip(
        label: Text(label),
        visualDensity: VisualDensity.compact,
        selected: value == s.name,
        // Tocar la que ya está marcada la quita.
        onSelected: (on) => onChanged(on ? s : null),
      ),
    );
    return Wrap(
      children: [
        chip(AttendanceStatus.yes, 'Voy'),
        chip(AttendanceStatus.maybe, 'Quizás'),
        chip(AttendanceStatus.no, 'No voy'),
      ],
    );
  }
}
