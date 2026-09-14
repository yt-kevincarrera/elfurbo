import 'package:elfurbo/domain/matchday_rules.dart';
import 'package:elfurbo/models/app_user.dart';
import 'package:elfurbo/models/match_day.dart';
import 'package:elfurbo/models/season.dart';
import 'package:flutter_test/flutter_test.dart';

AppUser _u(
  String uid, {
  UserRole role = UserRole.player,
  UserStatus status = UserStatus.active,
}) => AppUser(uid: uid, displayName: uid, role: role, status: status);

void main() {
  group('weeklyDates', () {
    final first = DateTime(2026, 9, 13, 10, 30);
    test('una semana devuelve solo la fecha inicial', () {
      expect(weeklyDates(first, 1), [first]);
    });
    test('n semanas: una por semana a la misma hora', () {
      final dates = weeklyDates(first, 3);
      expect(dates, [
        first,
        DateTime(2026, 9, 20, 10, 30),
        DateTime(2026, 9, 27, 10, 30),
      ]);
    });
    test('acota entre 1 y 26 semanas', () {
      expect(weeklyDates(first, 0).length, 1);
      expect(weeklyDates(first, 99).length, 26);
    });
  });

  group('canRemoveAdminRole', () {
    test('false si es el único admin activo', () {
      final users = [_u('a', role: UserRole.admin), _u('b')];
      expect(canRemoveAdminRole(users, 'a'), isFalse);
    });
    test('true si hay otro admin activo', () {
      final users = [
        _u('a', role: UserRole.admin),
        _u('b', role: UserRole.admin),
      ];
      expect(canRemoveAdminRole(users, 'a'), isTrue);
    });
    test('un admin bloqueado no cuenta como respaldo', () {
      final users = [
        _u('a', role: UserRole.admin),
        _u('b', role: UserRole.admin, status: UserStatus.blocked),
      ];
      expect(canRemoveAdminRole(users, 'a'), isFalse);
    });
    test('quitar rol a un jugador normal siempre se puede', () {
      final users = [_u('a', role: UserRole.admin), _u('b')];
      expect(canRemoveAdminRole(users, 'b'), isTrue);
    });
  });

  group('canDeleteSeason', () {
    final season = Season(
      id: 's1',
      name: 'T',
      startDate: DateTime(2026),
      isActive: false,
    );
    MatchDay m(String seasonId) => MatchDay(
      id: 'm',
      date: DateTime(2026, 9, 13),
      seasonId: seasonId,
      status: MatchStatus.scheduled,
      createdBy: 'u',
    );
    test('sin jornadas se puede borrar', () {
      expect(canDeleteSeason(season, [m('otra')]), isTrue);
    });
    test('con jornadas no', () {
      expect(canDeleteSeason(season, [m('s1')]), isFalse);
    });
  });

  test('Season.isClosed por defecto false', () {
    final s = Season(
      id: 's',
      name: 'T',
      startDate: DateTime(2026),
      isActive: true,
    );
    expect(s.isClosed, isFalse);
  });
}
