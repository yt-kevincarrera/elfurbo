import 'package:elfurbo/domain/achievements.dart';
import 'package:elfurbo/domain/stats_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('niveles y progreso', () {
    final s = PlayerStats('a')
      ..matchesPlayed = 12
      ..goals = 55
      ..hatTricks = 1
      ..bestStreak = 4
      ..mvps = 0;
    final list = Achievements.forPlayer(s);
    AchievementProgress byId(String id) =>
        list.firstWhere((a) => a.def.id == id);

    expect(byId('debut').unlocked, isTrue);
    expect(byId('scorer').tier, 2); // 55 >= 50, < 100
    expect(byId('scorer').tierLabel, 'Plata');
    expect(byId('scorer').nextThreshold, 100);
    expect(byId('scorer').progress, closeTo(0.1, 0.001));
    expect(byId('hat_trick').tier, 1);
    expect(byId('loyal').unlocked, isFalse);
    expect(byId('loyal').progress, closeTo(0.8, 0.001));
    expect(byId('mvp').tierLabel, 'Bloqueado');
    expect(byId('veteran').tier, 1);
    expect(Achievements.unlockedCount(s), 5);
  });

  test('sin actividad, nada desbloqueado', () {
    expect(Achievements.unlockedCount(PlayerStats('x')), 0);
  });
}
