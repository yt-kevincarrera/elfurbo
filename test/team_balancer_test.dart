import 'dart:math';

import 'package:elfurbo/domain/team_balancer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reparte parejo y con tamaños iguales', () {
    final players = List.generate(
      10,
      (i) => TeamCandidate(uid: 'p$i', rating: (i + 1) * 0.5),
    );
    final split = TeamBalancer.split(players, random: Random(1));
    expect(split.teamA.length, 5);
    expect(split.teamB.length, 5);
    expect(split.difference, lessThanOrEqualTo(0.5));
    final all = {...split.uidsA, ...split.uidsB};
    expect(all.length, 10);
  });

  test('impares: el equipo A tiene uno más', () {
    final players = List.generate(
      7,
      (i) => TeamCandidate(uid: 'p$i', rating: 1 + i * 0.3),
    );
    final split = TeamBalancer.split(players, random: Random(3));
    expect(split.teamA.length, 4);
    expect(split.teamB.length, 3);
  });

  test('jugadores nuevos reciben la valoración media y no rompen el reparto', () {
    final players = [
      const TeamCandidate(uid: 'crack', rating: 3),
      const TeamCandidate(uid: 'medio', rating: 1),
      const TeamCandidate(uid: 'nuevo1', rating: 0),
      const TeamCandidate(uid: 'nuevo2', rating: 0),
    ];
    final split = TeamBalancer.split(players, random: Random(7), jitter: 0);
    expect(split.teamA.length, 2);
    expect(split.teamB.length, 2);
    // Los dos nuevos valen 2 cada uno (media de 3 y 1): el óptimo es 3+1 vs 2+2.
    expect(split.difference, closeTo(0, 1e-9));
  });

  test('mezclar con otra semilla puede dar equipos distintos', () {
    final players = List.generate(
      8,
      (i) => TeamCandidate(uid: 'p$i', rating: 1 + (i % 3) * 0.2),
    );
    final results = <String>{};
    for (var seed = 0; seed < 20; seed++) {
      final s = TeamBalancer.split(players, random: Random(seed));
      results.add((s.uidsA..sort()).join(','));
    }
    expect(results.length, greaterThan(1));
  });

  test('lista vacía', () {
    final split = TeamBalancer.split(const []);
    expect(split.teamA, isEmpty);
    expect(split.teamB, isEmpty);
  });
}
