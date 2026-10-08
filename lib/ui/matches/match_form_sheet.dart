import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_messenger.dart';
import '../../core/formatters.dart';
import '../../data/providers.dart';
import '../../domain/matchday_rules.dart';
import '../../models/match_day.dart';
import '../../models/season.dart';

/// Alta o edición de una jornada. Crear la puede cualquier miembro (según el
/// ajuste del servidor), también sin señal.
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

/// Cupo de jugadores: sin límite (0) o de 2 a 60. Los de más quedan en
/// lista de espera.
class CapStepper extends StatelessWidget {
  const CapStepper({super.key, required this.value, required this.onChanged});

  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.groups_outlined),
      title: const Text('Cupo'),
      subtitle: Text(
        value == 0
            ? 'Sin límite'
            : '$value jugadores; los demás, en lista de espera',
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Menos',
            onPressed: value == 0
                ? null
                : () => onChanged(value <= 2 ? 0 : value - 1),
            icon: const Icon(Icons.remove),
          ),
          IconButton(
            tooltip: 'Más',
            onPressed: value >= 60
                ? null
                : () => onChanged(value == 0 ? 10 : value + 1),
            icon: const Icon(Icons.add),
          ),
        ],
      ),
    );
  }
}

class _MatchFormState extends ConsumerState<_MatchForm> {
  late DateTime _date;
  String? _seasonId;
  bool _repeat = false;
  int _weeks = 4;
  late int _cap;
  late final TextEditingController _place;
  late final TextEditingController _notes;

  bool get _isNew => widget.existing == null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _date = e?.date ?? _nextSunday();
    _seasonId = e?.seasonId;
    _cap = e?.maxPlayers ?? ref.read(clubSettingsProvider).maxPlayers;
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
      if (!ref.read(isAdminProvider)) {
        showError(
          'No hay temporada abierta. Pídele a un admin del servidor que cree una.',
        );
        return;
      }
      // Primera jornada del servidor (o todas las temporadas cerradas): se
      // crea una temporada sola.
      seasonId = repo.newId();
      fireAndForget(
        repo.createSeason(
          id: seasonId,
          name: 'Temporada ${_date.year}',
          startDate: DateTime(_date.year),
          activate: true,
        ),
      );
    }
    if (existing != null) {
      // Solo lo que cambió: al que creó la jornada el servidor no le deja
      // moverla de fecha o de temporada si ya hay datos de otros.
      final date = _date == existing.date ? null : _date;
      final season = seasonId == existing.seasonId ? null : seasonId;
      final place = _place.text.trim() == (existing.place ?? '')
          ? null
          : _place.text;
      final notes = _notes.text.trim() == (existing.notes ?? '')
          ? null
          : _notes.text;
      final cap = _cap == existing.maxPlayers ? null : _cap;
      if ([date, season, place, notes, cap].every((v) => v == null)) {
        Navigator.of(context).pop(); // Nada que cambiar.
        return;
      }
      fireAndForget(
        repo.updateMatch(
          existing.id,
          date: date,
          seasonId: season,
          place: place,
          notes: notes,
          maxPlayers: cap,
        ),
        success: 'Jornada actualizada',
      );
    } else {
      final dates = weeklyDates(_date, _repeat ? _weeks : 1);
      fireAndForget(
        repo.createMatches(
          dates: dates,
          seasonId: seasonId,
          place: _place.text,
          notes: _notes.text,
          maxPlayers: _cap,
        ),
        success: dates.length == 1
            ? 'Listo, jornada creada'
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
    final count = _repeat ? _weeks : 1;
    // El que la creó, si ya hay datos de otros, solo cambia lugar y notas.
    final locked =
        widget.existing != null &&
        !ref.watch(isStaffProvider) &&
        ref.watch(matchHasOthersDataProvider(widget.existing!.id));

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
            if (locked) ...[
              Text(
                'Ya hay datos de otros: la fecha y la temporada solo las cambia el staff.',
                style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 12),
            ],
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: locked ? null : _pickDate,
                    icon: const Icon(Icons.calendar_today),
                    label: Text(Fmt.short(_date)),
                  ),
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  onPressed: locked ? null : _pickTime,
                  icon: const Icon(Icons.schedule),
                  label: Text(Fmt.time(_date)),
                ),
              ],
            ),
            if (seasons.isNotEmpty) ...[
              const SizedBox(height: 12),
              DropdownMenu<String>(
                enabled: !locked,
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
                labelText: 'Terreno / lugar (opcional)',
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
            const SizedBox(height: 8),
            CapStepper(value: _cap, onChanged: (v) => setState(() => _cap = v)),
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
}
