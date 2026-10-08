import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../cloud/state/providers.dart';
import '../../core/app_messenger.dart';
import '../../core/formatters.dart';
import '../../data/providers.dart';
import '../../domain/season_review.dart';
import '../../domain/stats_engine.dart';
import '../../models/season.dart';
import '../../services/share_service.dart';
import '../widgets/tier_chip.dart';

const _accent = Color(0xFFE0B84A);
const _gold = Color(0xFFFFD86A);

/// El marco de las tarjetas para compartir: fondo oscuro, "EL FURBO" y una
/// etiqueta a la derecha.
class ShareCardFrame extends StatelessWidget {
  const ShareCardFrame({super.key, required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 360,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: const LinearGradient(
          colors: [Color(0xFF050505), Color(0xFF1F1A0E)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: DefaultTextStyle(
        style: const TextStyle(
          color: Colors.white,
          fontSize: 14,
          fontFamily: 'Roboto',
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Icon(Icons.sports_soccer, color: _accent, size: 28),
                const SizedBox(width: 8),
                const Text(
                  'EL FURBO',
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    letterSpacing: 2,
                    fontSize: 18,
                    color: _accent,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    label,
                    textAlign: TextAlign.right,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            child,
          ],
        ),
      ),
    );
  }
}

class _Numbers extends StatelessWidget {
  const _Numbers(this.items);

  final List<(String, int)> items;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (final (label, value) in items)
          Expanded(
            child: Column(
              children: [
                Text(
                  '$value',
                  style: const TextStyle(
                    fontSize: 30,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                Text(
                  label,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 11,
                    letterSpacing: 1.2,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// La carta de un jugador (spec 2.0 §8.3): nombre y apodo, nivel del
/// servidor, lo del período, su puesto en la tabla y el Índice Furbo.
class PlayerCard extends StatelessWidget {
  const PlayerCard({
    super.key,
    required this.name,
    this.nickname,
    required this.clubName,
    required this.tier,
    required this.period,
    required this.stats,
    this.position,
    this.index,
  });

  final String name;
  final String? nickname;
  final String clubName;
  final Tier tier;
  final String period;
  final PlayerStats stats;
  final int? position;
  final double? index;

  @override
  Widget build(BuildContext context) {
    return ShareCardFrame(
      label: period,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            nickname ?? name,
            style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w900),
          ),
          if (nickname != null)
            Text(name, style: const TextStyle(color: Colors.white70)),
          const SizedBox(height: 6),
          Row(
            children: [
              Icon(tier.icon, color: tier.color, size: 18),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '$clubName · ${tier.label}',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: tier.color),
                ),
              ),
            ],
          ),
          const Divider(color: Colors.white24, height: 28),
          _Numbers([
            ('PJ', stats.matchesPlayed),
            ('GOLES', stats.goals),
            ('ASIST.', stats.assists),
            ('MVP', stats.mvps),
          ]),
          const Divider(color: Colors.white24, height: 28),
          Row(
            children: [
              if (position != null) ...[
                const Icon(Icons.leaderboard, color: _gold, size: 20),
                const SizedBox(width: 6),
                Text(
                  '#$position en goles',
                  style: const TextStyle(
                    color: _gold,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
              const Spacer(),
              if (index != null)
                Text(
                  'Índice Furbo ${Fmt.decimal(index!)}',
                  style: const TextStyle(
                    color: _accent,
                    fontWeight: FontWeight.bold,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// La carta del jugador en una hoja, con el botón de compartir.
Future<void> showPlayerCard(BuildContext context, String uid) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _CardSheet(uid: uid),
    );

class _CardSheet extends ConsumerStatefulWidget {
  const _CardSheet({required this.uid});

  final String uid;

  @override
  ConsumerState<_CardSheet> createState() => _CardSheetState();
}

class _CardSheetState extends ConsumerState<_CardSheet> {
  final _key = GlobalKey();
  bool _sharing = false;

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(usersByIdProvider)[widget.uid];
    final stats = ref.watch(statsProvider);
    final club = ref.watch(currentClubProvider);
    final info = ref.watch(clubInfoProvider);
    final userId = user?.userId;
    final index = userId == null
        ? null
        : ref.watch(globalProfileProvider(userId)).value?.index;
    final s = stats.statsOf(widget.uid);
    final nick = user?.nickname;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          children: [
            RepaintBoundary(
              key: _key,
              child: PlayerCard(
                name: user?.displayName ?? 'Jugador',
                nickname: nick == null || nick.isEmpty ? null : nick,
                clubName: info?.name ?? club?.name ?? '',
                tier: Tier.parse(club?.tier),
                period: ref.watch(seasonFilterLabelProvider),
                stats: s,
                position: s.goals > 0
                    ? stats.positionOf(widget.uid, RankingKind.goals)
                    : null,
                index: index,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _sharing ? null : _share,
              icon: const Icon(Icons.share),
              label: const Text('Compartir la carta'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _share() async {
    setState(() => _sharing = true);
    try {
      await ShareService.shareBoundary(
        _key,
        fileName: 'elfurbo_carta.png',
        text: 'Mi carta en El Furbo ⚽',
      );
    } catch (e) {
      showError(e);
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }
}

/// "Tu temporada" (spec 2.0 §8.4): el resumen de una temporada cerrada, para
/// compartir.
class SeasonReviewScreen extends ConsumerStatefulWidget {
  const SeasonReviewScreen({
    super.key,
    required this.season,
    required this.uid,
  });

  final Season season;
  final String uid;

  @override
  ConsumerState<SeasonReviewScreen> createState() => _SeasonReviewScreenState();
}

class _SeasonReviewScreenState extends ConsumerState<SeasonReviewScreen> {
  final _key = GlobalKey();
  bool _sharing = false;

  @override
  Widget build(BuildContext context) {
    final users = ref.watch(usersByIdProvider);
    final engine = StatsEngine(
      matches: ref.watch(matchesProvider).value ?? const [],
      reports: ref.watch(reportsProvider).value ?? const [],
      votes: ref.watch(mvpVotesProvider).value ?? const [],
      attendance: ref.watch(attendanceProvider).value ?? const [],
      seasonId: widget.season.id,
    );
    final r = seasonReview(engine, widget.uid);
    final name = users[widget.uid]?.name ?? 'Jugador';
    final club = ref.watch(clubInfoProvider)?.name ?? '';
    final lines = <(IconData, String)>[
      if (r.position != null)
        (Icons.leaderboard, '#${r.position} en la tabla de goles'),
      if (r.bestStreak > 1)
        (Icons.local_fire_department, 'Mejor racha: ${r.bestStreak} seguidas'),
      if (r.bestDay case final d?)
        (
          Icons.star,
          'Mejor día: ${Fmt.short(d.date)}, '
              '${[if (d.goals > 0) Fmt.goals(d.goals), if (d.assists > 0) Fmt.assists(d.assists)].join(' y ')}',
        ),
      if (r.partner case final p?)
        (
          Icons.handshake,
          'Con ${users[p.uid]?.name ?? 'alguien'} jugó '
              '${Fmt.plural(p.times, 'vez', 'veces')} en el mismo equipo',
        ),
    ];
    return Scaffold(
      appBar: AppBar(title: Text(widget.season.name)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Center(
            child: RepaintBoundary(
              key: _key,
              child: ShareCardFrame(
                label: '${widget.season.name} · $club',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'La temporada de $name',
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 16),
                    _Numbers([
                      ('JORNADAS', r.played),
                      ('GOLES', r.goals),
                      ('ASIST.', r.assists),
                      ('MVP', r.mvps),
                    ]),
                    if (lines.isNotEmpty)
                      const Divider(color: Colors.white24, height: 28),
                    for (final (icon, text) in lines)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          children: [
                            Icon(icon, color: _gold, size: 18),
                            const SizedBox(width: 8),
                            Expanded(child: Text(text)),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _sharing ? null : _share,
            icon: const Icon(Icons.share),
            label: const Text('Compartir'),
          ),
        ],
      ),
    );
  }

  Future<void> _share() async {
    setState(() => _sharing = true);
    try {
      await ShareService.shareBoundary(
        _key,
        fileName: 'elfurbo_temporada.png',
        text: 'Mi ${widget.season.name} en El Furbo ⚽',
      );
    } catch (e) {
      showError(e);
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }
}
