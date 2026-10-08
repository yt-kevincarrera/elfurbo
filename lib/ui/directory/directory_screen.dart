import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../cloud/api/directory_api.dart';
import '../../cloud/api/players_api.dart';
import '../../cloud/state/providers.dart';
import '../../cloud/ui/errors.dart';
import '../../core/app_messenger.dart';
import '../../core/formatters.dart';
import '../../domain/provinces.dart';
import '../profile/global_stats.dart';
import '../widgets/club_token.dart';
import '../widgets/common.dart';
import '../widgets/expressive.dart';
import '../widgets/tier_chip.dart';

const _weekdays = ['lun', 'mar', 'mié', 'jue', 'vie', 'sáb', 'dom'];

/// "Juegan sáb y dom" a partir de los días (1 = lunes … 7 = domingo).
String? playDaysLabel(List<int> days) {
  final names = [
    for (final d in days)
      if (d >= 1 && d <= 7) _weekdays[d - 1],
  ];
  if (names.isEmpty) return null;
  final list = names.length == 1
      ? names.single
      : '${names.sublist(0, names.length - 1).join(', ')} y ${names.last}';
  return 'Juegan $list';
}

/// "Buscar servidores": los servidores y torneos públicos, y jugadores de toda
/// la app (spec 2.0 §6). Necesita señal.
class DirectoryScreen extends StatelessWidget {
  const DirectoryScreen({super.key, this.initialTab = 0});

  final int initialTab;

  static Future<void> open(BuildContext context, {int tab = 0}) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => DirectoryScreen(initialTab: tab),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      initialIndex: initialTab,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Buscar'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Servidores'),
              Tab(text: 'Torneos'),
              Tab(text: 'Jugadores'),
            ],
          ),
        ),
        body: const TabBarView(
          children: [
            _ClubList(kind: 'group'),
            _ClubList(kind: 'tournament'),
            _PlayerSearch(),
          ],
        ),
      ),
    );
  }
}

class _ClubList extends ConsumerStatefulWidget {
  const _ClubList({required this.kind});

  final String kind;

  @override
  ConsumerState<_ClubList> createState() => _ClubListState();
}

class _ClubListState extends ConsumerState<_ClubList>
    with AutomaticKeepAliveClientMixin {
  final _query = TextEditingController();
  String? _province;
  List<DirectoryClub> _items = const [];
  int? _next;
  bool _loading = false;
  Object? _error;
  Timer? _debounce;
  int _generation = 0;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load(reset: true);
  }

  @override
  void dispose() {
    _query.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _load({required bool reset}) async {
    final generation = reset ? ++_generation : _generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final (items, next) = await ref
          .read(directoryApiProvider)
          .list(
            query: _query.text,
            province: _province,
            kind: widget.kind,
            cursor: reset ? 0 : (_next ?? 0),
          );
      // Una búsqueda vieja que llega tarde no pisa la nueva.
      if (!mounted || generation != _generation) return;
      setState(() {
        _items = reset ? items : [..._items, ...items];
        _next = next;
      });
    } catch (e) {
      if (mounted && generation == _generation) setState(() => _error = e);
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  void _search() {
    _debounce?.cancel();
    _debounce = Timer(
      const Duration(milliseconds: 400),
      () => _load(reset: true),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final tournaments = widget.kind == 'tournament';
    return RefreshIndicator(
      onRefresh: () => _load(reset: true),
      child: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: TextField(
              controller: _query,
              onChanged: (_) => _search(),
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: tournaments
                    ? 'Nombre del torneo o municipio'
                    : 'Nombre del servidor o municipio',
              ),
            ),
          ),
          SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                for (final p in [null, ...provinces.keys])
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: ChoiceChip(
                      label: Text(p == null ? 'Toda Cuba' : provinces[p]!),
                      selected: _province == p,
                      onSelected: (_) {
                        setState(() => _province = p);
                        _load(reset: true);
                      },
                    ),
                  ),
              ],
            ),
          ),
          if (_error != null && _items.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  Text(describeError(_error!), textAlign: TextAlign.center),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: () => _load(reset: true),
                    child: const Text('Reintentar'),
                  ),
                ],
              ),
            )
          else if (_items.isEmpty && !_loading)
            EmptyState(
              icon: tournaments ? Icons.emoji_events_outlined : Icons.search,
              title: tournaments
                  ? 'Ningún torneo por aquí'
                  : 'Ningún servidor por aquí',
              subtitle: 'Prueba con otra provincia o con otro nombre.',
            )
          else
            GroupedSection(
              children: [
                for (final c in _items)
                  ListTile(
                    leading: ClubToken(
                      name: c.name,
                      color: c.color,
                      tournament: c.isTournament,
                    ),
                    title: Text(c.name, overflow: TextOverflow.ellipsis),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 2),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            TierChip.wire(c.tier),
                            if (placeLabel(c.province, c.city) case final p?)
                              Text(p, style: text.bodySmall),
                          ],
                        ),
                        Text(
                          [
                            Fmt.plural(c.members, 'miembro', 'miembros'),
                            ?playDaysLabel(c.playDays),
                          ].join(' · '),
                          style: text.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                    isThreeLine: true,
                    trailing: switch (c.myStatus) {
                      'member' => const Tooltip(
                        message: 'Ya eres miembro',
                        child: Icon(Icons.check_circle_outline),
                      ),
                      'pending' => const Tooltip(
                        message: 'Esperando respuesta',
                        child: Icon(Icons.hourglass_top),
                      ),
                      _ => const Icon(Icons.chevron_right),
                    },
                    onTap: () async {
                      await DirectoryClubScreen.open(context, c.id);
                      // Pudo pedir entrar: se refresca su estado.
                      if (mounted) _load(reset: true);
                    },
                  ),
              ],
            ),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: AppLoading(size: 36)),
            )
          else if (_next != null)
            Center(
              child: TextButton(
                onPressed: () => _load(reset: false),
                child: const Text('Ver más'),
              ),
            ),
        ],
      ),
    );
  }
}

/// El detalle de un servidor público, con "Pedir entrar" (o "Entrar" si es
/// abierto).
class DirectoryClubScreen extends ConsumerWidget {
  const DirectoryClubScreen({super.key, required this.clubId});

  final String clubId;

  static Future<void> open(BuildContext context, String clubId) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => DirectoryClubScreen(clubId: clubId),
        ),
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(directoryDetailProvider(clubId));
    return Scaffold(
      appBar: AppBar(title: Text(detail.value?.club.name ?? 'Servidor')),
      body: detail.when(
        loading: () => const LoadingView(message: 'Un momentico…'),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(describeError(e), textAlign: TextAlign.center),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: () =>
                      ref.invalidate(directoryDetailProvider(clubId)),
                  child: const Text('Reintentar'),
                ),
              ],
            ),
          ),
        ),
        data: (d) => _DetailBody(detail: d),
      ),
    );
  }
}

class _DetailBody extends ConsumerWidget {
  const _DetailBody({required this.detail});

  final DirectoryDetail detail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = detail.club;
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
          child: Row(
            children: [
              ClubToken(
                name: c.name,
                color: c.color,
                size: 56,
                tournament: c.isTournament,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      c.name,
                      style: text.headlineSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    TierChip.wire(c.tier),
                  ],
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Text(
            [
              ?placeLabel(c.province, c.city),
              Fmt.plural(c.members, 'miembro', 'miembros'),
              ?playDaysLabel(c.playDays),
            ].join(' · '),
            style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
        if (detail.description.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: Text(detail.description, style: text.bodyLarge),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
          child: _JoinButton(club: c),
        ),
        if (detail.upcoming.isNotEmpty) ...[
          const SectionTitle('Próximas jornadas'),
          GroupedSection(
            children: [
              for (final u in detail.upcoming)
                ListTile(
                  leading: const Icon(Icons.event),
                  title: Text(Fmt.full(u.startsAt)),
                  subtitle: u.place == null ? null : Text(u.place!),
                ),
            ],
          ),
        ],
        if (detail.topScorers.isNotEmpty) ...[
          SectionTitle(
            detail.season == null
                ? 'Goleadores'
                : 'Goleadores · ${detail.season}',
          ),
          GroupedSection(
            children: [
              for (final (i, s) in detail.topScorers.indexed)
                ListTile(
                  leading: CircleAvatar(child: Text('${i + 1}')),
                  title: Text(s.name),
                  subtitle: Text(
                    '${Fmt.goals(s.goals)} · ${Fmt.plural(s.played, 'jornada', 'jornadas')}',
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

class _JoinButton extends ConsumerStatefulWidget {
  const _JoinButton({required this.club});

  final DirectoryClub club;

  @override
  ConsumerState<_JoinButton> createState() => _JoinButtonState();
}

class _JoinButtonState extends ConsumerState<_JoinButton> {
  bool _busy = false;

  Future<void> _join() async {
    final c = widget.club;
    String message = '';
    if (c.joinPolicy == 'request') {
      final m = await _askMessage();
      if (m == null) return;
      message = m;
    }
    if (!mounted) return;
    setState(() => _busy = true);
    // Se toman antes de esperar: si se sale de la pantalla a mitad, igual se termina.
    final api = ref.read(directoryApiProvider);
    final cloud = ref.read(cloudProvider);
    final selected = ref.read(selectedClubProvider.notifier);
    try {
      final status = await api.join(c.id, message: message);
      await cloud.loadMe();
      if (status == 'member') {
        selected.select(c.id);
        unawaited(cloud.sync());
        showMessage('¡Bienvenido a ${c.name}!');
        if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
        return;
      }
      showMessage(
        'Listo, se lo pedimos al admin. Te avisamos cuando conteste.',
      );
      if (mounted) ref.invalidate(directoryDetailProvider(c.id));
    } catch (e) {
      showError(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _askMessage() {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Pedir entrar en ${widget.club.name}'),
        content: TextField(
          controller: controller,
          maxLength: 200,
          maxLines: 3,
          minLines: 1,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            hintText: 'Preséntate: quién eres, dónde juegas…',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Pedir'),
          ),
        ],
      ),
    );
  }

  Future<void> _cancel() async {
    setState(() => _busy = true);
    final api = ref.read(directoryApiProvider);
    final cloud = ref.read(cloudProvider);
    try {
      await api.cancelJoin(widget.club.id);
      await cloud.loadMe();
      if (mounted) ref.invalidate(directoryDetailProvider(widget.club.id));
      showMessage('Listo, retiraste la solicitud');
    } catch (e) {
      showError(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.club;
    if (_busy) return const Center(child: AppLoading(size: 36));
    return switch (c.myStatus) {
      'member' => FilledButton.tonalIcon(
        onPressed: () {
          ref.read(selectedClubProvider.notifier).select(c.id);
          Navigator.of(context).popUntil((r) => r.isFirst);
        },
        icon: const Icon(Icons.login),
        label: const Text('Ir al servidor'),
      ),
      'pending' => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Ya lo pediste: falta que un admin conteste.',
            textAlign: TextAlign.center,
          ),
          TextButton(
            onPressed: _cancel,
            child: const Text('Retirar la solicitud'),
          ),
        ],
      ),
      _ => FilledButton.icon(
        onPressed: _join,
        icon: const Icon(Icons.group_add),
        label: Text(c.joinPolicy == 'open' ? 'Entrar' : 'Pedir entrar'),
      ),
    };
  }
}

class _PlayerSearch extends ConsumerStatefulWidget {
  const _PlayerSearch();

  @override
  ConsumerState<_PlayerSearch> createState() => _PlayerSearchState();
}

class _PlayerSearchState extends ConsumerState<_PlayerSearch>
    with AutomaticKeepAliveClientMixin {
  final _query = TextEditingController();
  List<PlayerHit> _hits = const [];
  Object? _error;
  Timer? _debounce;
  int _generation = 0;

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _query.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _search(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () async {
      final generation = ++_generation;
      try {
        final hits = await ref.read(playersApiProvider).search(q);
        if (mounted && generation == _generation) {
          setState(() {
            _hits = hits;
            _error = null;
          });
        }
      } catch (e) {
        if (mounted && generation == _generation) setState(() => _error = e);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return ListView(
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: TextField(
            controller: _query,
            onChanged: _search,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.person_search),
              hintText: 'Usuario o nombre (mínimo 2 letras)',
            ),
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Text(describeError(_error!), textAlign: TextAlign.center),
          )
        else if (_hits.isEmpty && _query.text.trim().length >= 2)
          const EmptyState(
            icon: Icons.person_off,
            title: 'Nadie con ese nombre',
          )
        else
          GroupedSection(
            children: [
              for (final h in _hits)
                ListTile(
                  leading: CircleAvatar(
                    child: Text(
                      h.displayName.isEmpty
                          ? '?'
                          : h.displayName.characters.first.toUpperCase(),
                    ),
                  ),
                  title: Text(h.displayName),
                  subtitle: Text('@${h.username}'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => GlobalPlayerScreen.open(
                    context,
                    h.id,
                    displayName: h.displayName,
                  ),
                ),
            ],
          ),
      ],
    );
  }
}
