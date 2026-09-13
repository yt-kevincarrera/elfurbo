import 'dart:math';

/// Jugador candidato para el armado de equipos.
class TeamCandidate {
  const TeamCandidate({required this.uid, required this.rating});

  final String uid;
  final double rating;
}

class TeamSplit {
  const TeamSplit({required this.teamA, required this.teamB});

  final List<TeamCandidate> teamA;
  final List<TeamCandidate> teamB;

  double get ratingA => teamA.fold(0, (s, p) => s + p.rating);
  double get ratingB => teamB.fold(0, (s, p) => s + p.rating);
  double get difference => (ratingA - ratingB).abs();

  List<String> get uidsA => teamA.map((p) => p.uid).toList();
  List<String> get uidsB => teamB.map((p) => p.uid).toList();
}

/// Arma dos equipos parejos a partir de las valoraciones históricas.
///
/// 1. Ordena por valoración con un pequeño ruido aleatorio (para que "mezclar
///    de nuevo" dé equipos distintos pero igual de parejos).
/// 2. Reparte en serpiente (A, B, B, A, A, B, ...) para que ambos tengan la
///    misma cantidad de jugadores (si son impares, A tiene uno más).
/// 3. Prueba intercambios de a un jugador mientras reduzcan la diferencia.
class TeamBalancer {
  static TeamSplit split(
    List<TeamCandidate> players, {
    Random? random,
    double jitter = 0.15,
  }) {
    if (players.isEmpty) return const TeamSplit(teamA: [], teamB: []);
    final rng = random ?? Random();

    // Jugadores sin historial reciben la valoración media del grupo para no
    // desbalancear por desconocimiento.
    final known = players.where((p) => p.rating > 0).toList();
    final avg = known.isEmpty
        ? 1.0
        : known.fold(0.0, (s, p) => s + p.rating) / known.length;
    final normalized = players
        .map(
          (p) =>
              TeamCandidate(uid: p.uid, rating: p.rating > 0 ? p.rating : avg),
        )
        .toList();

    final scale = normalized.fold(0.0, (s, p) => max(s, p.rating));
    final noisy =
        normalized
            .map(
              (p) =>
                  (p, p.rating + (rng.nextDouble() * 2 - 1) * jitter * scale),
            )
            .toList()
          ..sort((a, b) => b.$2.compareTo(a.$2));

    final a = <TeamCandidate>[];
    final b = <TeamCandidate>[];
    for (var i = 0; i < noisy.length; i++) {
      // Serpiente: posiciones 0,3,4,7,8,... van a A; 1,2,5,6,... a B.
      final toA = (i % 4 == 0) || (i % 4 == 3);
      (toA ? a : b).add(noisy[i].$1);
    }
    // Si son impares el reparto en serpiente puede dejar B con uno más;
    // movemos para que A tenga el extra.
    if (b.length > a.length) {
      a.add(b.removeLast());
    }

    var best = TeamSplit(teamA: a, teamB: b);
    var improved = true;
    while (improved) {
      improved = false;
      for (var i = 0; i < best.teamA.length; i++) {
        for (var j = 0; j < best.teamB.length; j++) {
          final newA = [...best.teamA]..[i] = best.teamB[j];
          final newB = [...best.teamB]..[j] = best.teamA[i];
          final candidate = TeamSplit(teamA: newA, teamB: newB);
          if (candidate.difference + 1e-9 < best.difference) {
            best = candidate;
            improved = true;
          }
        }
      }
    }

    // Presentación estable: cada equipo ordenado de mayor a menor valoración.
    return TeamSplit(
      teamA: [...best.teamA]..sort((x, y) => y.rating.compareTo(x.rating)),
      teamB: [...best.teamB]..sort((x, y) => y.rating.compareTo(x.rating)),
    );
  }
}
