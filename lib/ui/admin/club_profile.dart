import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_messenger.dart';
import '../../data/providers.dart';
import '../../domain/provinces.dart';
import '../widgets/chalk.dart';
import '../widgets/club_token.dart';
import '../widgets/common.dart';
import '../widgets/expressive.dart';

/// Quién es el servidor y quién lo ve (solo el dueño): nombre, descripción,
/// dónde juegan, color, y si es privado o sale en el directorio. Va por la cola
/// de sync, así que se cambia también sin señal.
class ClubProfileSection extends ConsumerWidget {
  const ClubProfileSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final info = ref.watch(clubInfoProvider);
    if (info == null) return const SizedBox.shrink();
    final settings = ref.watch(clubSettingsProvider);
    final readOnly = ref.watch(clubReadOnlyProvider);
    final repo = ref.read(repoProvider);
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final where = placeLabel(info.province, info.city);

    void save(Future<void> f, [String done = 'Listo, guardado']) =>
        fireAndForget(f, success: done);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionTitle('Perfil del servidor'),
        GroupedSection(
          children: [
            ListTile(
              leading: ClubToken(
                name: info.name,
                color: info.color,
                tournament: info.isTournament,
              ),
              title: Text(info.name),
              subtitle: Text(
                [
                  if (where != null) where,
                  if (info.description.isNotEmpty) info.description,
                  if (where == null && info.description.isEmpty)
                    'Ponle una descripción y dónde juegan',
                ].join('\n'),
              ),
              isThreeLine: where != null && info.description.isNotEmpty,
              trailing: readOnly ? null : const Icon(Icons.edit_outlined),
              onTap: readOnly
                  ? null
                  : () => showModalBottomSheet<void>(
                      context: context,
                      isScrollControlled: true,
                      showDragHandle: true,
                      builder: (_) => _ProfileSheet(info: info),
                    ),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
          child: Text('Color', style: text.titleMedium),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(
            spacing: 4,
            children: [
              for (var i = 0; i < Chalk.clubColors.length; i++)
                Tooltip(
                  message: Chalk.clubColorNames[i],
                  child: InkResponse(
                    radius: 24,
                    onTap: readOnly || i == info.color
                        ? null
                        : () => save(repo.updateProfile(color: i)),
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: Chalk.clubColors[i],
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: i == info.color
                                ? scheme.onSurface
                                : Colors.transparent,
                            width: 3,
                          ),
                        ),
                        child: i == info.color
                            ? const Icon(Icons.check, color: Chalk.board)
                            : null,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Quién lo ve', style: text.titleMedium),
              Text(
                info.delisted
                    ? 'El superadmin lo sacó del directorio: por ahora solo se '
                          'entra con invitación. Habla con él para volver a ponerlo.'
                    : info.isPublic
                    ? 'Sale en "Buscar servidores": cualquiera lo encuentra y '
                          'puede pedir entrar.'
                    : 'Solo se entra con una invitación. No sale en ningún '
                          'directorio.',
                style: text.bodySmall,
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: SegmentedButton<String>(
                  showSelectedIcon: false,
                  selected: {info.visibility},
                  onSelectionChanged: readOnly
                      ? null
                      : (s) {
                          if (s.first == info.visibility) return;
                          save(
                            repo.setVisibility(s.first),
                            s.first == 'public'
                                ? 'Listo, ya es público'
                                : 'Listo, ahora es privado',
                          );
                        },
                  segments: [
                    const ButtonSegment(
                      value: 'private',
                      icon: Icon(Icons.lock_outline),
                      label: Text('Privado'),
                    ),
                    ButtonSegment(
                      value: 'public',
                      icon: const Icon(Icons.public),
                      label: const Text('Público'),
                      enabled: !info.delisted,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (info.isPublic)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Cómo se entra', style: text.titleMedium),
                Text(
                  settings.joinPolicy == 'open'
                      ? 'Entra al momento quien lo pida.'
                      : 'Quien quiera entrar lo pide y un admin lo acepta.',
                  style: text.bodySmall,
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<String>(
                    showSelectedIcon: false,
                    selected: {settings.joinPolicy},
                    onSelectionChanged: readOnly
                        ? null
                        : (s) {
                            if (s.first == settings.joinPolicy) return;
                            save(
                              repo.setVisibility('public', joinPolicy: s.first),
                            );
                          },
                    segments: const [
                      ButtonSegment(
                        value: 'request',
                        label: Text('Pidiéndolo'),
                      ),
                      ButtonSegment(value: 'open', label: Text('Abierto')),
                    ],
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 8),
      ],
    );
  }
}

class _ProfileSheet extends ConsumerStatefulWidget {
  const _ProfileSheet({required this.info});

  final ClubInfo info;

  @override
  ConsumerState<_ProfileSheet> createState() => _ProfileSheetState();
}

class _ProfileSheetState extends ConsumerState<_ProfileSheet> {
  late final _name = TextEditingController(text: widget.info.name);
  late final _description = TextEditingController(
    text: widget.info.description,
  );
  late final _city = TextEditingController(text: widget.info.city ?? '');
  late String? _province = widget.info.province;
  final _form = GlobalKey<FormState>();

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    _city.dispose();
    super.dispose();
  }

  void _save() {
    if (!_form.currentState!.validate()) return;
    final i = widget.info;
    final name = _name.text.trim();
    final description = _description.text.trim();
    final city = _city.text.trim();
    final changed =
        name != i.name ||
        description != i.description ||
        city != (i.city ?? '') ||
        _province != i.province;
    Navigator.pop(context);
    if (!changed) return;
    fireAndForget(
      ref
          .read(repoProvider)
          .updateProfile(
            name: name != i.name ? name : null,
            description: description != i.description ? description : null,
            city: city != (i.city ?? '') ? city : null,
            province: _province != i.province ? (_province ?? '') : null,
          ),
      success: 'Listo, perfil guardado',
    );
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
              'Perfil del servidor',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _name,
              maxLength: 40,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Nombre'),
              validator: (v) =>
                  (v ?? '').trim().length < 3 ? 'Mínimo 3 caracteres' : null,
            ),
            TextFormField(
              controller: _description,
              maxLength: 200,
              maxLines: 3,
              minLines: 1,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Descripción',
                hintText: 'Cuándo y dónde juegan, el nivel…',
              ),
            ),
            DropdownButtonFormField<String?>(
              initialValue: provinces.containsKey(_province) ? _province : null,
              decoration: const InputDecoration(labelText: 'Provincia'),
              items: [
                const DropdownMenuItem(value: null, child: Text('Sin decir')),
                for (final p in provinces.entries)
                  DropdownMenuItem(value: p.key, child: Text(p.value)),
              ],
              onChanged: (v) => setState(() => _province = v),
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: _city,
              maxLength: 40,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Municipio o ciudad',
                hintText: 'Playa, Santa Clara…',
              ),
            ),
            const SizedBox(height: 8),
            FilledButton(onPressed: _save, child: const Text('Guardar')),
          ],
        ),
      ),
    );
  }
}
