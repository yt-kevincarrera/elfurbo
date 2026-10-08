import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../cloud/state/providers.dart';
import '../../core/app_messenger.dart';
import '../../models/tournament.dart';
import '../widgets/chalk.dart';
import '../widgets/common.dart';
import '../widgets/expressive.dart';

/// "Organizar un torneo" en el Admin de un servidor (owner y admin). Crearlo
/// necesita señal; después todo va por la cola, como siempre.
class OrganizeTournamentSection extends StatelessWidget {
  const OrganizeTournamentSection({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionTitle('Torneos'),
        GroupedSection(
          children: [
            ListTile(
              leading: const Icon(Icons.emoji_events_outlined),
              title: const Text('Organizar un torneo'),
              subtitle: const Text(
                'Liga, copa o grupos con copa, con equipos de aquí o de otros servidores.',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                showDragHandle: true,
                builder: (_) => const _OrganizeSheet(),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _OrganizeSheet extends ConsumerStatefulWidget {
  const _OrganizeSheet();

  @override
  ConsumerState<_OrganizeSheet> createState() => _OrganizeSheetState();
}

class _OrganizeSheetState extends ConsumerState<_OrganizeSheet> {
  final _name = TextEditingController();
  final _description = TextEditingController();
  final _form = GlobalKey<FormState>();
  TournamentFormat _format = TournamentFormat.league;
  bool _public = false;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    if (!_form.currentState!.validate()) return;
    final host = ref.read(currentClubProvider);
    if (host == null) return;
    setState(() => _busy = true);
    final api = ref.read(clubAdminApiProvider);
    final cloud = ref.read(cloudProvider);
    final selected = ref.read(selectedClubProvider.notifier);
    try {
      final id = await api.createTournament(
        host.id,
        name: _name.text,
        description: _description.text,
        format: _format.wire,
        visibility: _public ? 'public' : 'private',
      );
      await cloud.loadMe();
      selected.select(id);
      await cloud.sync();
      showMessage('¡Torneo creado! Ponle las reglas y abre la inscripción.');
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      showError(e);
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        0,
        20,
        20 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Organizar un torneo',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _name,
              maxLength: 40,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Nombre',
                hintText: 'Copa Verano 2026',
              ),
              validator: (v) =>
                  (v ?? '').trim().length < 3 ? 'Mínimo 3 caracteres' : null,
            ),
            TextFormField(
              controller: _description,
              maxLength: 200,
              maxLines: 2,
              minLines: 1,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Descripción'),
            ),
            const SizedBox(height: 8),
            SegmentedButton<TournamentFormat>(
              showSelectedIcon: false,
              selected: {_format},
              onSelectionChanged: (s) => setState(() => _format = s.first),
              segments: [
                for (final f in TournamentFormat.values)
                  ButtonSegment(value: f, label: Text(f.label)),
              ],
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Público'),
              subtitle: const Text(
                'Sale en "Buscar" y cualquiera puede inscribir su equipo.',
              ),
              value: _public,
              onChanged: (v) => setState(() => _public = v),
            ),
            const SizedBox(height: 8),
            if (_busy)
              const Center(child: AppLoading(size: 36))
            else
              FilledButton(onPressed: _create, child: const Text('Crear')),
          ],
        ),
      ),
    );
  }
}

/// Inscribir un equipo en un torneo público desde el directorio.
Future<void> showRegisterTeam(
  BuildContext context, {
  required String tournamentId,
  required String tournamentName,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) =>
      _RegisterSheet(id: tournamentId, tournamentName: tournamentName),
);

class _RegisterSheet extends ConsumerStatefulWidget {
  const _RegisterSheet({required this.id, required this.tournamentName});

  final String id;
  final String tournamentName;

  @override
  ConsumerState<_RegisterSheet> createState() => _RegisterSheetState();
}

class _RegisterSheetState extends ConsumerState<_RegisterSheet> {
  final _name = TextEditingController();
  final _short = TextEditingController();
  final _form = GlobalKey<FormState>();
  int _color = 0;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _short.dispose();
    super.dispose();
  }

  Future<void> _register() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    final api = ref.read(directoryApiProvider);
    final cloud = ref.read(cloudProvider);
    final selected = ref.read(selectedClubProvider.notifier);
    try {
      await api.registerTeam(
        widget.id,
        name: _name.text,
        shortName: _short.text,
        color: _color,
      );
      await cloud.loadMe();
      selected.select(widget.id);
      await cloud.sync();
      showMessage(
        '¡Inscrito en ${widget.tournamentName}! Invita a los tuyos desde tu equipo.',
      );
      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    } catch (e) {
      showError(e);
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        0,
        20,
        20 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Inscribir un equipo',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 4),
            const Text(
              'Quedas de capitán. El organizador lo aprueba y tú invitas a tu gente.',
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _name,
              maxLength: 30,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Nombre del equipo'),
              validator: (v) =>
                  (v ?? '').trim().length < 2 ? 'Mínimo 2 caracteres' : null,
            ),
            TextFormField(
              controller: _short,
              maxLength: 4,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(
                labelText: 'Sigla',
                hintText: 'TIG',
              ),
              validator: (v) =>
                  RegExp(
                    r'^[A-Za-z0-9ÁÉÍÓÚÑáéíóúñ]{2,4}$',
                  ).hasMatch((v ?? '').trim())
                  ? null
                  : 'De 2 a 4 letras',
            ),
            Wrap(
              spacing: 4,
              children: [
                for (var i = 0; i < Chalk.clubColors.length; i++)
                  InkResponse(
                    onTap: () => setState(() => _color = i),
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: CircleAvatar(
                        radius: 16,
                        backgroundColor: Chalk.clubColors[i],
                        child: i == _color
                            ? const Icon(Icons.check, color: Chalk.board)
                            : null,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            if (_busy)
              const Center(child: AppLoading(size: 36))
            else
              FilledButton(
                onPressed: _register,
                child: const Text('Inscribir'),
              ),
          ],
        ),
      ),
    );
  }
}
