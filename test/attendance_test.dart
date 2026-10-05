import 'package:elfurbo/models/attendance.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('sin played la presencia es desconocida', () {
    const a = Attendance(matchId: 'm', uid: 'u', status: AttendanceStatus.yes);
    expect(a.presenceUnknown, isTrue);
    expect(a.isPresent, isFalse);
    expect(a.isAbsent, isFalse);
  });

  test('played true es presente aunque la intención fuera no ir', () {
    const a = Attendance(
      matchId: 'm',
      uid: 'u',
      status: AttendanceStatus.no,
      played: true,
      playedSetBy: 'admin',
    );
    expect(a.isPresent, isTrue);
    expect(a.playedSetBy, 'admin');
  });

  test('played false es ausente aunque dijera que iba', () {
    const a = Attendance(
      matchId: 'm',
      uid: 'u',
      status: AttendanceStatus.yes,
      played: false,
    );
    expect(a.isAbsent, isTrue);
    expect(a.isPresent, isFalse);
  });

  test('fromCloud lee una fila de la vista local', () {
    final a = Attendance.fromCloud({
      'id': 'm:u',
      'matchdayId': 'm',
      'memberId': 'u',
      'intent': 'yes',
      'played': true,
      'playedSetBy': 'u',
    });
    expect(a.matchId, 'm');
    expect(a.uid, 'u');
    expect(a.status, AttendanceStatus.yes);
    expect(a.isPresent, isTrue);
    expect(a.playedSetBy, 'u');
    final b = Attendance.fromCloud({
      'matchdayId': 'm',
      'memberId': 'v',
      'intent': null,
      'played': null,
    });
    expect(b.presenceUnknown, isTrue);
    expect(b.status, isNull, reason: 'sin intención marcada no es quizás');
  });
}
