import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_messenger.dart';
import '../../data/providers.dart';
import '../widgets/common.dart';

/// Los ajustes del servidor (solo el dueño). Van por la cola de sync, así que
/// se cambian también sin señal.
class ClubSettingsSection extends ConsumerWidget {
  const ClubSettingsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(clubSettingsProvider);
    final readOnly = ref.watch(clubReadOnlyProvider);
    final repo = ref.read(repoProvider);
    final text = Theme.of(context).textTheme;

    void save(Future<void> f) => fireAndForget(f, success: 'Ajuste guardado');

    Widget setting<T>({
      required String title,
      required String help,
      required T value,
      required Map<T, String> options,
      required void Function(T) onChanged,
    }) => Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: text.titleMedium),
          Text(help, style: text.bodySmall),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<T>(
              showSelectedIcon: false,
              selected: {value},
              onSelectionChanged: readOnly
                  ? null
                  : (sel) {
                      if (sel.first != value) onChanged(sel.first);
                    },
              segments: [
                for (final e in options.entries)
                  ButtonSegment(value: e.key, label: Text(e.value)),
              ],
            ),
          ),
        ],
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionTitle('Ajustes del servidor'),
        setting(
          title: 'Quién crea jornadas',
          help: 'Si es "cualquiera", el que primero llegue al terreno la crea.',
          value: s.matchdayCreators,
          options: const {'members': 'Cualquiera', 'staff': 'Solo el staff'},
          onChanged: (v) => save(repo.updateSettings(matchdayCreators: v)),
        ),
        setting(
          title: 'Los goles que pone cada uno',
          help:
              'Con confirmación, cuentan cuando los confirman compañeros que jugaron. '
              'Confiando, cuentan al momento (el admin puede rechazarlos igual).',
          value: s.reportValidation,
          options: const {'confirm': 'Con confirmación', 'trust': 'Confiando'},
          onChanged: (v) => save(repo.updateSettings(reportValidation: v)),
        ),
        if (s.reportValidation == 'confirm')
          setting(
            title: 'Confirmaciones que hacen falta',
            help: 'Cuántos compañeros tienen que decir "Es verdad".',
            value: s.confirmationsNeeded,
            options: const {1: '1', 2: '2', 3: '3', 4: '4', 5: '5'},
            onChanged: (v) => save(repo.updateSettings(confirmationsNeeded: v)),
          ),
        setting(
          title: 'Las jornadas se cierran',
          help:
              'Pasado ese tiempo desde que empieza, ya no se ponen goles ni se vota.',
          value: s.closeAfterHours,
          options: {
            24: '1 día',
            48: '2 días',
            72: '3 días',
            168: '1 semana',
            if (![24, 48, 72, 168].contains(s.closeAfterHours))
              s.closeAfterHours: '${s.closeAfterHours} h',
          },
          onChanged: (v) => save(repo.updateSettings(closeAfterHours: v)),
        ),
        setting(
          title: 'Estadísticas en el perfil de cada uno',
          help:
              'Si se comparten, lo que cada jugador hace aquí sale en su perfil '
              'de toda la app, con el nivel del servidor.',
          value: s.shareStats,
          options: const {true: 'Se comparten', false: 'Solo aquí'},
          onChanged: (v) => save(repo.updateSettings(shareStats: v)),
        ),
      ],
    );
  }
}
