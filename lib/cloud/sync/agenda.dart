import '../rules/matchday_rules.dart';
import 'club_data.dart';

/// Una jornada de la agenda común: la de cualquiera de mis servidores.
class AgendaItem {
  const AgendaItem({
    required this.clubId,
    required this.clubName,
    required this.clubColor,
    required this.timezone,
    required this.matchdayId,
    required this.startsAt,
    required this.going,
    this.place,
    this.myIntent,
  });

  final String clubId;
  final String clubName;
  final int clubColor;
  final String timezone;
  final String matchdayId;
  final DateTime startsAt;
  final String? place;

  /// `yes`, `maybe`, `no` o null (no dije nada).
  final String? myIntent;

  /// Cuántos dijeron "Voy".
  final int going;
}

/// Lo que miro de un servidor para la agenda: su vista local y quién soy en él.
typedef AgendaSource = ({ClubData data, String myMemberId});

/// Las jornadas de los próximos [days] días de todos mis servidores en las que
/// todavía se puede decir si voy, por fecha. Los servidores suspendidos no
/// salen (no se puede responder nada en ellos).
List<AgendaItem> agendaItems(
  Iterable<AgendaSource> sources, {
  required DateTime now,
  int days = 14,
}) {
  final until = now.add(Duration(days: days));
  final items = <AgendaItem>[];
  for (final s in sources) {
    final club = s.data.club;
    if (club == null || club['status'] != 'active') continue;
    final settings = (club['settings'] as Map?) ?? const {};
    final closedSeasons = {
      for (final season in s.data.all('season'))
        if (season['isClosed'] == true) '${season['id']}',
    };
    for (final md in s.data.all('matchday')) {
      final start = DateTime.tryParse('${md['startsAt']}');
      if (start == null || start.isAfter(until)) continue;
      final times = MatchdayTimes(
        startsAt: start,
        durationMinutes: (md['durationMinutes'] as num?)?.toInt() ?? 0,
        status: '${md['status']}',
        seasonClosed: closedSeasons.contains('${md['seasonId']}'),
      );
      if (times.seasonClosed || !acceptsIntent(times, now)) continue;
      final id = '${md['id']}';
      final going = s.data
          .all('attendance')
          .where((a) => a['matchdayId'] == id && a['intent'] == 'yes')
          .length;
      final place = '${md['place'] ?? ''}'.trim();
      items.add(
        AgendaItem(
          clubId: s.data.clubId,
          clubName: '${club['name'] ?? ''}',
          clubColor: (club['color'] as num?)?.toInt() ?? 0,
          timezone: '${settings['timezone'] ?? 'America/Havana'}',
          matchdayId: id,
          startsAt: start,
          place: place.isEmpty ? null : place,
          myIntent:
              s.data.one('attendance', '$id:${s.myMemberId}')?['intent']
                  as String?,
          going: going,
        ),
      );
    }
  }
  items.sort((a, b) => a.startsAt.compareTo(b.startsAt));
  return items;
}
