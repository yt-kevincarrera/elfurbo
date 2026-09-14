import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_messenger.dart';
import '../../core/formatters.dart';
import '../../data/providers.dart';
import '../../models/match_day.dart';

/// Alta o edición de un partido (solo admin).
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
  late DateTime _date;
  late final TextEditingController _place;
  late final TextEditingController _notes;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _date = e?.date ?? _nextSunday();
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
    if (existing != null) {
      fireAndForget(
        repo.updateMatch(
          existing.id,
          date: _date,
          place: _place.text,
          notes: _notes.text,
        ),
        success: 'Partido actualizado',
      );
    } else {
      var seasonId = ref.read(activeSeasonProvider)?.id;
      if (seasonId == null) {
        // Primer partido del grupo: creamos una temporada automáticamente.
        seasonId = repo.newSeasonId();
        fireAndForget(
          repo.createSeason(
            id: seasonId,
            name: 'Temporada ${_date.year}',
            startDate: DateTime(_date.year),
            activate: true,
            otherSeasonIds: const [],
          ),
        );
      }
      fireAndForget(
        repo.createMatch(
          date: _date,
          seasonId: seasonId,
          createdBy: ref.read(myUidProvider),
          place: _place.text,
          notes: _notes.text,
        ),
        success: 'Partido creado',
      );
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        0,
        20,
        20 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.existing == null ? 'Nuevo partido' : 'Editar partido',
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
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _save,
            child: Text(widget.existing == null ? 'Crear partido' : 'Guardar'),
          ),
        ],
      ),
    );
  }
}
