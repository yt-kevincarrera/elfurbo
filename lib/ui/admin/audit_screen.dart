import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../cloud/api/admin_api.dart';
import '../../cloud/state/providers.dart';
import '../../cloud/ui/errors.dart';
import '../../cloud/ui/home_screens.dart';
import '../../core/formatters.dart';
import '../../core/theme.dart';
import '../../data/providers.dart';
import '../../models/app_user.dart';
import '../widgets/chalk.dart';
import '../widgets/common.dart';
import '../widgets/expressive.dart';

/// Quién hizo qué en el servidor (owner y admin), lo más nuevo primero.
/// Necesita señal: el registro vive en el servidor.
class AuditScreen extends ConsumerStatefulWidget {
  const AuditScreen({super.key});

  static Future<void> open(BuildContext context) => Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => const AuditScreen()));

  @override
  ConsumerState<AuditScreen> createState() => _AuditScreenState();
}

class _AuditScreenState extends ConsumerState<AuditScreen> {
  final _entries = <AuditEntry>[];
  int? _next;
  bool _loading = false;
  bool _done = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final club = ref.read(currentClubProvider);
    if (club == null || _loading || _done) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await ref
          .read(clubAdminApiProvider)
          .audit(club.id, before: _next);
      if (!mounted) return;
      setState(() {
        _entries.addAll(page.entries);
        _next = page.next;
        _done = page.next == null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final users = ref.watch(usersByIdProvider);
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Quién hizo qué')),
      body: _entries.isEmpty && _loading
          ? const LoadingView()
          : _entries.isEmpty && _error != null
          ? EmptyState(
              icon: Icons.cloud_off,
              title: 'No se pudo traer',
              subtitle: describeError(_error!),
              action: FilledButton(
                onPressed: _load,
                child: const Text('Reintentar'),
              ),
            )
          : _entries.isEmpty
          ? const EmptyState(
              icon: Icons.history,
              title: 'Todavía no hay nada',
              subtitle:
                  'Aquí sale lo importante: invitaciones, roles, reportes corregidos o rechazados…',
            )
          : NotificationListener<ScrollNotification>(
              onNotification: (n) {
                // Tras un error, reintenta el botón (no cada movimiento).
                if (n.metrics.extentAfter < 400 && _error == null) _load();
                return false;
              },
              child: ListView.builder(
                padding: const EdgeInsets.fromLTRB(4, 8, 4, 32),
                itemCount: _entries.length + 1,
                itemBuilder: (context, i) {
                  if (i == _entries.length) {
                    return Padding(
                      padding: const EdgeInsets.all(20),
                      child: Center(
                        child: _loading
                            ? const AppLoading(size: 32)
                            : _error != null
                            ? TextButton(
                                onPressed: _load,
                                child: const Text('Reintentar'),
                              )
                            : const SizedBox.shrink(),
                      ),
                    );
                  }
                  final e = _entries[i];
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: GroupedTile(
                      index: i,
                      count: _entries.length,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text.rich(
                            TextSpan(
                              style: text.bodyLarge,
                              children: [
                                TextSpan(
                                  text: e.actorName ?? 'Alguien',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                    color: Chalk.yellow,
                                  ),
                                ),
                                TextSpan(text: ' ${describeAudit(e, users)}'),
                              ],
                            ),
                          ),
                          Text(
                            '${Fmt.short(e.at)} · ${Fmt.time(e.at)}',
                            style: AppTheme.mono(size: 11, color: Chalk.dim),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
    );
  }
}

/// La acción, contada en claro ("expulsó a Raúl", "rechazó el reporte de…").
String describeAudit(AuditEntry e, Map<String, AppUser> users) {
  final s = e.summary;
  String member(String id) => users[id]?.name ?? 'alguien';
  // Reportes: la clave es "jornada:miembro".
  String reportOf() => member(e.entityKey.split(':').last);
  String role(Object? r) => roleLabel('$r').toLowerCase();
  return switch (e.action) {
    'invite.create' => 'creó una invitación (${role(s['role'])})',
    'invite.revoke' => 'anuló una invitación',
    'invite.accept' => 'entró con una invitación',
    'recovery.issue' =>
      'generó un código de recuperación para ${member(e.entityKey)}',
    'member.setRole' => 'hizo ${role(s['to'])} a ${member(e.entityKey)}',
    'member.ban' => 'expulsó a ${member(e.entityKey)}',
    'member.unban' => 'perdonó a ${member(e.entityKey)}',
    'club.updateSettings' => 'cambió los ajustes del servidor',
    'club.transfer' => 'le pasó el servidor a otro',
    'club.request' => 'pidió el servidor',
    'club.approve' => 'aprobó el servidor',
    'club.suspend' => 'suspendió el servidor',
    'club.reactivate' => 'reactivó el servidor',
    'report.decide' => switch (s['decision']) {
      'confirmed' => 'confirmó el reporte de ${reportOf()}',
      'rejected' => 'rechazó el reporte de ${reportOf()}',
      _ => 'quitó la decisión del reporte de ${reportOf()}',
    },
    'report.correct' =>
      'corrigió el reporte de ${reportOf()} (${Fmt.goals((s['goals'] as num?)?.toInt() ?? 0)}, ${Fmt.assists((s['assists'] as num?)?.toInt() ?? 0)})',
    'report.loadFor' => 'puso los goles de ${reportOf()}',
    'matchday.setStatus' => switch (s['to']) {
      'cancelled' => 'canceló una jornada',
      'closed' => 'cerró una jornada',
      'reopened' => 'reabrió una jornada',
      _ => 'reactivó una jornada',
    },
    'matchday.delete' => 'borró una jornada',
    'matchday.merge' => 'unió dos jornadas repetidas',
    'season.delete' => 'borró una temporada',
    _ => 'hizo "${e.action}"',
  };
}
