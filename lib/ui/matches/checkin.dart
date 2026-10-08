import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../cloud/state/providers.dart';
import '../../core/app_messenger.dart';
import '../../data/providers.dart';
import '../../domain/checkin.dart';
import '../../models/match_day.dart';

/// "Estoy aquí" y, para el staff, el código de asistencia (spec 2.0 §8.1).
/// Sale cerca de la jornada: de 3 horas antes a 3 después.
class CheckinCard extends ConsumerWidget {
  const CheckinCard({super.key, required this.match});

  final MatchDay match;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final closed = ref.watch(matchClosedProvider(match.id));
    if (closed || !checkinOpen(match.date, match.end, DateTime.now())) {
      return const SizedBox.shrink();
    }
    final me = ref.watch(myUidProvider);
    final mine = ref.watch(attendanceForMatchProvider(match.id))[me];
    final isStaff = ref.watch(isStaffProvider);
    final text = Theme.of(context).textTheme;
    final done = mine?.checkedIn == true;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('¿Ya llegaste?', style: text.titleMedium),
            const SizedBox(height: 4),
            Text(
              done
                  ? '✓ Comprobaste que estás aquí. Cuenta como jornada jugada.'
                  : 'Pídele el código al organizador y confirma que estás '
                        'aquí. Así tu jornada vale más.',
              style: text.bodySmall,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (!done)
                  FilledButton.icon(
                    onPressed: () => _askCode(context, ref),
                    icon: const Icon(Icons.where_to_vote),
                    label: const Text('Estoy aquí'),
                  ),
                if (isStaff)
                  FilledButton.tonalIcon(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const CheckinCodeScreen(),
                      ),
                    ),
                    icon: const Icon(Icons.pin),
                    label: const Text('Código de asistencia'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _askCode(BuildContext context, WidgetRef ref) async {
    final code = await showDialog<String>(
      context: context,
      builder: (_) => const _CodeDialog(),
    );
    if (code == null) return;
    fireAndForget(
      ref.read(repoProvider).checkIn(match.id, code),
      success: 'Listo, ya saben que estás aquí',
    );
  }
}

class _CodeDialog extends StatefulWidget {
  const _CodeDialog();

  @override
  State<_CodeDialog> createState() => _CodeDialogState();
}

class _CodeDialogState extends State<_CodeDialog> {
  final _code = TextEditingController();

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ok = RegExp(r'^\d{6}$').hasMatch(_code.text);
    return AlertDialog(
      title: const Text('Estoy aquí'),
      content: TextField(
        controller: _code,
        autofocus: true,
        keyboardType: TextInputType.number,
        maxLength: 6,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        textAlign: TextAlign.center,
        style: Theme.of(
          context,
        ).textTheme.headlineMedium?.copyWith(letterSpacing: 8),
        decoration: const InputDecoration(
          hintText: '000000',
          helperText: 'El que sale en el teléfono del organizador',
        ),
        onChanged: (_) => setState(() {}),
        onSubmitted: ok ? (v) => Navigator.pop(context, v) : null,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: ok ? () => Navigator.pop(context, _code.text) : null,
          child: const Text('Confirmar'),
        ),
      ],
    );
  }
}

/// El código que enseña el staff: 6 cifras que cambian cada 5 minutos y se
/// sacan sin conexión. El secreto se pide la primera vez y queda guardado.
class CheckinCodeScreen extends ConsumerStatefulWidget {
  const CheckinCodeScreen({super.key});

  @override
  ConsumerState<CheckinCodeScreen> createState() => _CheckinCodeScreenState();
}

class _CheckinCodeScreenState extends ConsumerState<CheckinCodeScreen> {
  String? _secret;
  bool _failed = false;
  late final Timer _tick;

  @override
  void initState() {
    super.initState();
    _load();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final clubId = ref.read(currentClubProvider)?.id;
    final store = ref.read(cloudProvider).engine?.store;
    if (clubId == null || store == null) {
      setState(() => _failed = true);
      return;
    }
    try {
      final saved = await store.readCheckinSecrets();
      var secret = saved[clubId] as String?;
      if (secret == null) {
        secret = await ref.read(clubAdminApiProvider).checkinSecret(clubId);
        await store.writeCheckinSecrets({...saved, clubId: secret});
      }
      if (mounted) setState(() => _secret = secret);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final now = DateTime.now();
    final secret = _secret;
    final left = checkinRemaining(now);
    final Widget body;
    if (secret != null) {
      body = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Enséñaselo a los que llegan', style: text.titleMedium),
          const SizedBox(height: 24),
          Text(
            checkinCode(secret, now),
            key: const Key('checkin-code'),
            style: text.displayLarge?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: 10,
              color: scheme.primary,
            ),
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: 220,
            child: LinearProgressIndicator(
              value: left.inMilliseconds / checkinWindow.inMilliseconds,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Cambia en ${left.inMinutes}:'
            '${(left.inSeconds % 60).toString().padLeft(2, '0')}',
            style: text.bodySmall,
          ),
          const SizedBox(height: 24),
          Text(
            'Funciona sin señal. El que lo escribe sin conexión lo manda '
            'después: vale el código del momento en que lo puso.',
            textAlign: TextAlign.center,
            style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      );
    } else if (_failed) {
      body = Text(
        'La primera vez hace falta conexión para sacar el código. '
        'Prueba otra vez cuando tengas señal.',
        textAlign: TextAlign.center,
        style: text.bodyLarge,
      );
    } else {
      body = const CircularProgressIndicator();
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Código de asistencia')),
      body: Center(
        child: Padding(padding: const EdgeInsets.all(24), child: body),
      ),
    );
  }
}
