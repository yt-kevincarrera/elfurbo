import 'package:elfurbo/core/deep_links.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('el código de un enlace de invitación', () {
    expect(DeepLinks.inviteCode('elfurbo://invite/ab12cd34'), 'AB12CD34');
    expect(DeepLinks.inviteCode('elfurbo://invite/AB12-CD34'), 'AB12-CD34');
    expect(
      DeepLinks.inviteCode(
        'https://furbo-api.furbo-probe.workers.dev/i/AB12CD34',
      ),
      'AB12CD34',
    );
  });

  test('lo que no es una invitación: null', () {
    for (final link in [
      'elfurbo://otra/AB12CD34',
      'elfurbo://invite/',
      'elfurbo://invite/a/b',
      'elfurbo://invite/<script>',
      'https://ejemplo.com/x/AB12CD34',
      'no es un enlace',
    ]) {
      expect(DeepLinks.inviteCode(link), isNull, reason: link);
    }
  });

  test('al llegar uno, queda pendiente para atenderlo', () {
    DeepLinks.handle('elfurbo://invite/AB12CD34');
    expect(DeepLinks.pendingInvite.value, 'AB12CD34');
    DeepLinks.pendingInvite.value = null;
    DeepLinks.handle('https://ejemplo.com');
    expect(DeepLinks.pendingInvite.value, isNull);
  });

  test('el id de un enlace a un servidor público', () {
    const id = '00000000-0000-4000-8000-000000000001';
    expect(DeepLinks.clubId('elfurbo://club/$id'), id);
    expect(
      DeepLinks.clubId('https://furbo-api.furbo-probe.workers.dev/s/$id'),
      id,
    );
    for (final link in [
      'elfurbo://club/',
      'elfurbo://club/<script>',
      'elfurbo://invite/$id',
      'https://ejemplo.com/x/$id',
    ]) {
      expect(DeepLinks.clubId(link), isNull, reason: link);
    }
    DeepLinks.handle('elfurbo://club/$id');
    expect(DeepLinks.pendingClub.value, id);
    expect(DeepLinks.pendingInvite.value, isNull);
    DeepLinks.pendingClub.value = null;
  });
}
