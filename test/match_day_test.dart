import 'package:elfurbo/models/match_day.dart';
import 'package:flutter_test/flutter_test.dart';

MatchDay _m(
  DateTime date, {
  MatchStatus status = MatchStatus.scheduled,
  int duration = 120,
}) => MatchDay(
  id: 'm',
  date: date,
  seasonId: 's',
  status: status,
  createdBy: 'u',
  durationMinutes: duration,
);

void main() {
  final start = DateTime(2026, 9, 13, 10);

  test('próxima, en curso y jugada según duración', () {
    final m = _m(start);
    expect(m.isUpcoming(start.subtract(const Duration(hours: 1))), isTrue);
    expect(m.isUpcoming(start), isFalse);
    expect(m.isInProgress(start), isTrue);
    expect(m.isInProgress(start.add(const Duration(minutes: 30))), isTrue);
    expect(m.isPlayed(start.add(const Duration(minutes: 30))), isFalse);
    expect(m.isPlayed(start.add(const Duration(minutes: 120))), isTrue);
    expect(m.isInProgress(start.add(const Duration(minutes: 120))), isFalse);
    expect(m.end, start.add(const Duration(minutes: 120)));
  });

  test('duración personalizada y por defecto', () {
    expect(_m(start, duration: 60).end, start.add(const Duration(hours: 1)));
    final def = MatchDay(
      id: 'm',
      date: start,
      seasonId: 's',
      status: MatchStatus.scheduled,
      createdBy: 'u',
    );
    expect(def.durationMinutes, MatchDay.defaultDurationMinutes);
  });

  test('cancelada no es próxima, en curso ni jugada', () {
    final m = _m(start, status: MatchStatus.cancelled);
    expect(m.isUpcoming(start.subtract(const Duration(days: 1))), isFalse);
    expect(m.isInProgress(start), isFalse);
    expect(m.isPlayed(start.add(const Duration(days: 1))), isFalse);
    expect(m.isCancelled, isTrue);
  });

  test('cierre automático a las 72 h, manual y reabierta', () {
    final m = _m(start);
    expect(m.isClosed(start.add(const Duration(hours: 71))), isFalse);
    expect(m.isClosed(start.add(const Duration(hours: 72))), isTrue);
    expect(_m(start, status: MatchStatus.closed).isClosed(start), isTrue);
    expect(
      _m(
        start,
        status: MatchStatus.reopened,
      ).isClosed(start.add(const Duration(days: 30))),
      isFalse,
    );
    expect(m.isClosed(start, seasonClosed: true), isTrue);
    expect(_m(start, status: MatchStatus.cancelled).isClosed(start), isTrue);
  });

  test('reabierta sigue siendo jugada y no cancelada', () {
    final m = _m(start, status: MatchStatus.reopened);
    expect(m.isPlayed(start.add(const Duration(days: 10))), isTrue);
    expect(m.isReopened, isTrue);
    expect(m.isManuallyClosed, isFalse);
  });
}
