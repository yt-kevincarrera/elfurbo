import 'stats_engine.dart';

/// Un logro con sus niveles. `thresholds` son los valores a alcanzar para cada
/// nivel (bronce, plata, oro). Los logros de un solo nivel tienen un umbral.
class AchievementDef {
  const AchievementDef({
    required this.id,
    required this.title,
    required this.description,
    required this.emoji,
    required this.thresholds,
    required this.value,
  });

  final String id;
  final String title;
  final String Function(int threshold) description;
  final String emoji;
  final List<int> thresholds;
  final int Function(PlayerStats s) value;
}

/// Estado de un logro para un jugador concreto.
class AchievementProgress {
  const AchievementProgress({
    required this.def,
    required this.current,
    required this.tier,
  });

  final AchievementDef def;
  final int current;

  /// 0 = bloqueado, 1..n = nivel alcanzado.
  final int tier;

  bool get unlocked => tier > 0;
  int get maxTier => def.thresholds.length;
  bool get isMaxed => tier >= maxTier;

  /// Siguiente umbral a alcanzar, o null si ya está al máximo.
  int? get nextThreshold => isMaxed ? null : def.thresholds[tier];

  /// Progreso 0..1 hacia el siguiente nivel.
  double get progress {
    final next = nextThreshold;
    if (next == null) return 1;
    final prev = tier == 0 ? 0 : def.thresholds[tier - 1];
    if (next == prev) return 1;
    return ((current - prev) / (next - prev)).clamp(0, 1).toDouble();
  }

  String get tierLabel => switch (tier) {
    0 => 'Bloqueado',
    1 when maxTier == 1 => 'Logrado',
    1 => 'Bronce',
    2 => 'Plata',
    _ => 'Oro',
  };
}

/// Catálogo de logros. Se calculan siempre a partir de las estadísticas, no se
/// guardan en ningún lado: si se corrige un reporte, los logros se recalculan.
class Achievements {
  static String _n(int n, String one, String many) =>
      '$n ${n == 1 ? one : many}';

  static final List<AchievementDef> all = [
    AchievementDef(
      id: 'debut',
      title: 'Debut',
      emoji: '👟',
      description: (_) => 'Jugaste tu primer partido con el grupo.',
      thresholds: const [1],
      value: (s) => s.matchesPlayed,
    ),
    AchievementDef(
      id: 'first_goal',
      title: 'Primer grito',
      emoji: '🎯',
      description: (_) => 'Tu primer gol confirmado.',
      thresholds: const [1],
      value: (s) => s.goals,
    ),
    AchievementDef(
      id: 'hat_trick',
      title: 'Hat-trick',
      emoji: '🎩',
      description: (t) =>
          'Meté 3 o más goles en un partido (${_n(t, 'vez', 'veces')}).',
      thresholds: const [1, 3, 10],
      value: (s) => s.hatTricks,
    ),
    AchievementDef(
      id: 'poker',
      title: 'Póker',
      emoji: '🃏',
      description: (_) => '4 o más goles en un mismo partido.',
      thresholds: const [1],
      value: (s) => s.pokers,
    ),
    AchievementDef(
      id: 'scorer',
      title: 'Goleador',
      emoji: '⚽',
      description: (t) => 'Llegá a $t goles confirmados.',
      thresholds: const [10, 50, 100],
      value: (s) => s.goals,
    ),
    AchievementDef(
      id: 'assister',
      title: 'Asistidor',
      emoji: '🅰️',
      description: (t) => 'Llegá a $t asistencias confirmadas.',
      thresholds: const [10, 50, 100],
      value: (s) => s.assists,
    ),
    AchievementDef(
      id: 'complete',
      title: 'Partido completo',
      emoji: '🔁',
      description: (t) =>
          'Gol y asistencia en el mismo partido (${_n(t, 'vez', 'veces')}).',
      thresholds: const [1, 5, 15],
      value: (s) => s.completeMatches,
    ),
    AchievementDef(
      id: 'loyal',
      title: 'Fiel',
      emoji: '📅',
      description: (t) => '$t partidos seguidos sin faltar.',
      thresholds: const [5, 10, 25],
      value: (s) => s.bestStreak,
    ),
    AchievementDef(
      id: 'veteran',
      title: 'Veterano',
      emoji: '🏟️',
      description: (t) => 'Jugá $t partidos con el grupo.',
      thresholds: const [10, 50, 100],
      value: (s) => s.matchesPlayed,
    ),
    AchievementDef(
      id: 'mvp',
      title: 'MVP',
      emoji: '🏆',
      description: (t) => 'Elegido mejor jugador ${_n(t, 'vez', 'veces')}.',
      thresholds: const [1, 5, 15],
      value: (s) => s.mvps,
    ),
    AchievementDef(
      id: 'mvp_streak',
      title: 'Imparable',
      emoji: '🔥',
      description: (t) => 'MVP en $t partidos seguidos.',
      thresholds: const [2, 3],
      value: (s) => s.bestMvpStreak,
    ),
  ];

  static List<AchievementProgress> forPlayer(PlayerStats s) {
    return all.map((def) {
      final current = def.value(s);
      var tier = 0;
      for (final t in def.thresholds) {
        if (current >= t) tier++;
      }
      return AchievementProgress(def: def, current: current, tier: tier);
    }).toList();
  }

  static int unlockedCount(PlayerStats s) =>
      forPlayer(s).where((a) => a.unlocked).length;
}
