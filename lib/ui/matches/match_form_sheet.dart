import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_messenger.dart';
import '../../core/formatters.dart';
import '../../data/providers.dart';
import '../../domain/matchday_rules.dart';
import '../../models/match_day.dart';
import '../../models/season.dart';

/// Alta o edición de una jornada (solo admin).
Future<void> showMatchFormSheet(BuildContext context, {MatchDay? existing}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _MatchForm(existing: existing),
  );
}

class _MatchForm extends ConsumerStatefulWidget {
  const _MatchForm({this.existing});

  final MatchDay? existing;

  @override
  ConsumerState<_MatchForm> createState() => _MatchFormState();
}

class _MatchFormState extends ConsumerState<_MatchForm> {
  static const _durations = [60, 90, 120, 180];

  late DateTime _date;
  late int _duration;
  String? _seasonId;
  bool _repeat = false;
  int _weeks = 4;
  late final TextEditingController _place;
  late final TextEditingController _notes;

  bool get _isNew => widget.existing == null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _date = e?.date ?? _nextSunday();
    _duration = e?.durationMinutes ?? MatchDay.defaultDurationMinutes;
    _seasonId = e?.seasonId;
    _place = TextEditingController(text: e?.place ?? '');
    _notes = TextEditingController(text: e?.notes ?? '');
  }

  @override
  void dispose() {
    _place.dispose();
    _notes.dispose();
    super.dispose();
  }

  static DateTime _nextSunday() {
    final now = DateTime.now();
    var d = DateTime(now.year, now.month, now.day, 10);
    while (d.weekday != DateTime.sunday || d.isBefore(now)) {
      d = d.add(const Duration(days: 1));
    }
    return d;
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked == null) return;
    setState(
      () => _date = DateTime(
        picked.year,
        picked.month,
        picked.day,
        _date.hour,
        _date.minute,
      ),
    );
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_date),
    );
    if (picked == null) return;
    setState(
      () => _date = DateTime(
        _date.year,
        _date.month,
        _date.day,
        picked.hour,
        picked.minute,
      ),
    );
  }

  void _save() {
    final repo = ref.read(repoProvider);
    final existing = widget.existing;
    var seasonId = _seasonId ?? ref.read(activeSeasonProvider)?.id;
    if (seasonId == null || seasonId.isEmpty) {
      // Primera jornada del grupo (o todas las temporadas cerradas): creamos
      // una temporada automáticamente.
      seasonId = repo.newSeasonId();
      fireAndForget(
        repo.createSeason(
          id: seasonId,
          name: 'Temporada ${_date.year}',
          startDate: DateTime(_date.year),
          activate: true,
          otherSeasonIds: (ref.read(seasonsProvider).value ?? const [])
              .map((s) => s.id)
              .toList(),
        ),
      );
    }
    if (existing != null) {
      fireAndForget(
        repo.updateMatch(
          existing.id,
          date: _date,
          durationMinutes: _duration,
          seasonId: seasonId,
          place: _place.text,
          notes: _notes.text,
        ),
        success: 'Jornada actualizada',
      );
    } else {
      final dates = weeklyDates(_date, _repeat ? _weeks : 1);
      fireAndForget(
        repo.createMatches(
          dates: dates,
          seasonId: seasonId,
          createdBy: ref.read(myUidProvider),
          durationMinutes: _duration,
          place: _place.text,
          notes: _notes.text,
        ),
        success: dates.length == 1
            ? 'Jornada creada'
            : '${dates.length} jornadas creadas',
      );
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final seasons = (ref.watch(seasonsProvider).value ?? const <Season>[])
        .where((s) => !s.isClosed || s.id == _seasonId)
        .toList();
    final activeId = ref.watch(activeSeasonProvider)?.id;
    final selectedSeason = _seasonId ?? activeId;
    final durationOptions = {..._durations, _duration}.toList()..sort();
    final count = _repeat ? _weeks : 1;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        0,
        20,
        20 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              _isNew ? 'Nueva jornada' : 'Editar jornada',
              style: text.titleLarge,
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _pickDate,
                    icon: const Icon(Icons.calendar_today),
                    label: Text(Fmt.short(_date)),
                  ),
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  onPressed: _pickTime,
                  icon: const Icon(Icons.schedule),
                  label: Text(Fmt.time(_date)),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text('Duración', style: text.labelLarge),
            const SizedBox(height: 6),
            SegmentedButton<int>(
              showSelectedIcon: false,
              selected: {_duration},
              onSelectionChanged: (s) => setState(() => _duration = s.first),
              segments: [
                for (final d in durationOptions)
                  ButtonSegment(value: d, label: Text(_durationLabel(d))),
              ],
            ),
            if (seasons.isNotEmpty) ...[
              const SizedBox(height: 12),
              DropdownMenu<String>(
                initialSelection: selectedSeason,
                label: const Text('Temporada'),
                leadingIcon: const Icon(Icons.flag_outlined),
                expandedInsets: EdgeInsets.zero,
                onSelected: (id) => setState(() => _seasonId = id),
                dropdownMenuEntries: [
                  for (final s in seasons)
                    DropdownMenuEntry(
                      value: s.id,
                      label: s.isClosed ? '${s.name} (cerrada)' : s.name,
                    ),
                ],
              ),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: _place,
              decoration: const InputDecoration(
                labelText: 'Cancha / lugar (opcional)',
                prefixIcon: Icon(Icons.place_outlined),
              ),
              textCapitalization: TextCapitalization.sentences,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _notes,
              decoration: const InputDecoration(
                labelText: 'Notas (opcional)',
                prefixIcon: Icon(Icons.notes),
              ),
              textCapitalization: TextCapitalization.sentences,
              maxLines: 2,
            ),
            if (_isNew) ...[
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Repetir cada semana'),
                subtitle: Text(
                  _repeat
                      ? 'Se crean $_weeks jornadas, una por semana, a la misma hora.'
                      : 'Crea varias jornadas de una vez (por ejemplo, todos los domingos).',
                ),
                value: _repeat,
                onChanged: (v) => setState(() => _repeat = v),
              ),
              if (_repeat)
                Row(
                  children: [
                    Text('Semanas', style: text.labelLarge),
                    Expanded(
                      child: Slider(
                        value: _weeks.toDouble(),
                        min: 2,
                        max: maxRecurringWeeks.toDouble(),
                        divisions: maxRecurringWeeks - 2,
                        label: '$_weeks',
                        onChanged: (v) => setState(() => _weeks = v.round()),
                      ),
                    ),
                    SizedBox(
                      width: 28,
                      child: Text(
                        '$_weeks',
                        textAlign: TextAlign.end,
                        style: text.titleMedium?.copyWith(
                          color: scheme.primary,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
            ],
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _save,
              child: Text(
                !_isNew
                    ? 'Guardar'
                    : count == 1
                    ? 'Crear jornada'
                    : 'Crear $count jornadas',
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _durationLabel(int minutes) {
    if (minutes % 60 == 0) return '${minutes ~/ 60} h';
    if (minutes > 60) return '${minutes ~/ 60} h ${minutes % 60}';
    return '$minutes min';
  }
}
