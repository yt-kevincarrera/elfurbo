import 'package:elfurbo/domain/club_roles.dart';
import 'package:elfurbo/models/app_user.dart';
import 'package:flutter_test/flutter_test.dart';

// Mismos casos que `canSetRole` y `canBan` de backend/test/authz.test.ts.
void main() {
  const owner = UserRole.owner;
  const admin = UserRole.admin;
  const scorer = UserRole.scorer;
  const player = UserRole.player;
  const guest = UserRole.guest;

  group('canSetRole', () {
    test('el owner nombra y quita admins', () {
      expect(canSetRole(owner, player, admin), isTrue);
      expect(canSetRole(owner, admin, player), isTrue);
    });
    test('un admin solo mueve entre anotador y jugador', () {
      expect(canSetRole(admin, player, scorer), isTrue);
      expect(canSetRole(admin, scorer, player), isTrue);
      expect(canSetRole(admin, player, admin), isFalse);
      expect(canSetRole(admin, admin, player), isFalse);
    });
    test('nadie pasa a owner ni se toca al owner o a un sin cuenta', () {
      expect(canSetRole(owner, admin, owner), isFalse);
      expect(canSetRole(owner, owner, admin), isFalse);
      expect(canSetRole(owner, guest, player), isFalse);
    });
    test('anotadores y jugadores no cambian roles', () {
      expect(canSetRole(scorer, player, scorer), isFalse);
      expect(canSetRole(player, player, scorer), isFalse);
    });
  });

  group('canBan', () {
    test('el owner expulsa a cualquiera menos al owner', () {
      expect(canBan(owner, admin), isTrue);
      expect(canBan(owner, guest), isTrue);
      expect(canBan(owner, owner), isFalse);
    });
    test('un admin, a anotadores, jugadores y sin cuenta', () {
      expect(canBan(admin, scorer), isTrue);
      expect(canBan(admin, player), isTrue);
      expect(canBan(admin, guest), isTrue);
      expect(canBan(admin, admin), isFalse);
    });
    test('los demás no expulsan', () {
      expect(canBan(scorer, player), isFalse);
      expect(canBan(player, guest), isFalse);
    });
  });
}
