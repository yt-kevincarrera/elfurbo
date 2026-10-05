import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../cloud/api/admin_api.dart';
import '../../cloud/state/providers.dart';
import '../../cloud/ui/errors.dart';
import '../../cloud/ui/home_screens.dart';
import '../../core/app_messenger.dart';
import '../../core/formatters.dart';
import '../../core/theme.dart';
import '../../data/providers.dart';
import '../../domain/club_roles.dart';
import '../../models/app_user.dart';
import '../widgets/common.dart';
import '../widgets/chalk.dart';
import '../widgets/expressive.dart';

/// Comparte una invitación por WhatsApp (o lo que elija): el código y el enlace.
Future<void> shareInvite(
  WidgetRef ref,
  Invite invite, {
  required String clubName,
  String? claimName,
}) {
  final link = ref.read(clubAdminApiProvider).inviteLink(invite.code);
  final text = claimName == null
      ? '¿Qué bolá? Te invito a jugar con $clubName en El Furbo.\n'
            'Código: ${invite.code}\n$link\n'
            'Si no tienes la app, pídeme el APK.'
      : '¿Qué bolá? Con esto reclamas tu perfil de $claimName en $clubName '
            '(El Furbo), con todos tus goles.\n'
            'Código: ${invite.code}\n$link';
  return SharePlus.instance.share(ShareParams(text: text));
}

/// Las invitaciones vigentes del servidor elegido, con compartir y revocar.
class InvitesSection extends ConsumerWidget {
  const InvitesSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final club = ref.watch(currentClubProvider);
    if (club == null) return const SizedBox.shrink();
    final invites = ref.watch(invitesProvider(club.id));
    final readOnly = ref.watch(clubReadOnlyProvider);
    final users = ref.watch(usersByIdProvider);
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionTitle(
          'Invitaciones',
          trailing: readOnly
              ? null
              : TextButton.icon(
                  onPressed: () => showCreateInvite(context, ref),
                  icon: const Icon(Icons.person_add),
                  label: const Text('Invitar'),
                ),
        ),
        invites.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: AppLoading(size: 36)),
          ),
          error: (e, _) => Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    describeError(e),
                    style: text.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () => ref.invalidate(invitesProvider(club.id)),
                  child: const Text('Reintentar'),
                ),
              ],
            ),
          ),
          data: (list) => list.isEmpty
              ? Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Text(
                    'No hay invitaciones abiertas. Crea una y mándala por WhatsApp.',
                    style: text.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                )
              : GroupedSection(
                  children: [
                    for (final i in list)
                      ListTile(
                        leading: Icon(
                          i.targetMemberId == null
                              ? Icons.mail_outline
                              : Icons.how_to_reg,
                          color: Chalk.yellow,
                        ),
                        title: Text(
                          i.code,
                          style: AppTheme.mono(
                            size: 17,
                            weight: 800,
                            spacing: 2,
                            color: Chalk.white,
                          ),
                        ),
                        subtitle: Text(
                          [
                            if (i.targetMemberId != null)
                              'Para ${users[i.targetMemberId]?.name ?? 'reclamar un perfil'}'
                            else
                              roleLabel(i.role),
                            i.maxUses == 1
                                ? 'una persona'
                                : '${i.uses} de ${i.maxUses}',
                            'vence el ${Fmt.dateOnly(i.expiresAt)}',
                          ].join(' · '),
                        ),
                        trailing: readOnly
                            ? null
                            : Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    tooltip: 'Compartir',
                                    icon: const Icon(Icons.share),
                                    onPressed: () => shareInvite(
                                      ref,
                                      i,
                                      clubName: club.name,
                                      claimName: i.targetMemberId == null
                                          ? null
                                          : users[i.targetMemberId]?.name,
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: 'Anular',
                                    icon: const Icon(Icons.link_off),
                                    onPressed: () =>
                                        _revoke(context, ref, club.id, i),
                                  ),
                                ],
                              ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  Future<void> _revoke(
    BuildContext context,
    WidgetRef ref,
    String clubId,
    Invite invite,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('¿Anular ${invite.code}?'),
        content: const Text(
          'El código deja de servir. Los que ya entraron con él se quedan.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Volver'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Anular'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(clubAdminApiProvider).revokeInvite(clubId, invite.code);
      ref.invalidate(invitesProvider(clubId));
      showMessage('Invitación anulada');
    } catch (e) {
      showError(describeError(e));
    }
  }
}

/// Crear una invitación y compartirla al momento.
Future<void> showCreateInvite(BuildContext context, WidgetRef ref) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => const _CreateInviteSheet(),
  );
}

class _CreateInviteSheet extends ConsumerStatefulWidget {
  const _CreateInviteSheet();

  @override
  ConsumerState<_CreateInviteSheet> createState() => _CreateInviteSheetState();
}

class _CreateInviteSheetState extends ConsumerState<_CreateInviteSheet> {
  UserRole _role = UserRole.player;
  int _uses = 1;
  int _days = 7;
  bool _busy = false;

  Future<void> _create() async {
    final club = ref.read(currentClubProvider);
    if (club == null) return;
    setState(() => _busy = true);
    try {
      final invite = await ref
          .read(clubAdminApiProvider)
          .createInvite(
            club.id,
            role: _role.name,
            maxUses: _uses,
            expiresInDays: _days,
          );
      ref.invalidate(invitesProvider(club.id));
      if (mounted) Navigator.of(context).pop();
      await shareInvite(ref, invite, clubName: club.name);
    } catch (e) {
      showError(describeError(e));
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final myRole = ref.watch(myRoleProvider);
    final text = Theme.of(context).textTheme;
    final roles = [
      for (final r in const [UserRole.player, UserRole.scorer, UserRole.admin])
        if (canInviteAs(myRole, r)) r,
    ];
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          24,
          0,
          24,
          24 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Invitar al servidor', style: text.headlineSmall),
            const SizedBox(height: 20),
            Text('Entra como', style: text.labelLarge),
            const SizedBox(height: 8),
            SegmentedButton<UserRole>(
              showSelectedIcon: false,
              selected: {_role},
              onSelectionChanged: (s) => setState(() => _role = s.first),
              segments: [
                for (final r in roles)
                  ButtonSegment(value: r, label: Text(roleLabel(r.name))),
              ],
            ),
            const SizedBox(height: 20),
            Text('Para cuántos', style: text.labelLarge),
            const SizedBox(height: 8),
            SegmentedButton<int>(
              showSelectedIcon: false,
              selected: {_uses},
              onSelectionChanged: (s) => setState(() => _uses = s.first),
              segments: const [
                ButtonSegment(value: 1, label: Text('Uno')),
                ButtonSegment(value: 10, label: Text('Hasta 10')),
                ButtonSegment(value: 50, label: Text('Hasta 50')),
              ],
            ),
            const SizedBox(height: 20),
            Text('Dura', style: text.labelLarge),
            const SizedBox(height: 8),
            SegmentedButton<int>(
              showSelectedIcon: false,
              selected: {_days},
              onSelectionChanged: (s) => setState(() => _days = s.first),
              segments: const [
                ButtonSegment(value: 1, label: Text('1 día')),
                ButtonSegment(value: 7, label: Text('1 semana')),
                ButtonSegment(value: 30, label: Text('1 mes')),
              ],
            ),
            const SizedBox(height: 28),
            FilledButton.icon(
              style: const ButtonStyle(
                minimumSize: WidgetStatePropertyAll(Size.fromHeight(56)),
              ),
              onPressed: _busy ? null : _create,
              icon: _busy
                  ? const SizedBox.square(
                      dimension: 24,
                      child: AppLoading(size: 24),
                    )
                  : const Icon(Icons.share),
              label: const Text('Crear y compartir'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Muestra un código de recuperación (se ve una sola vez) para copiarlo o
/// mandarlo.
Future<void> showRecoveryCode(
  BuildContext context, {
  required String forName,
  required RecoveryCode code,
}) {
  return showDialog<void>(
    context: context,
    builder: (ctx) {
      final text = Theme.of(ctx).textTheme;
      final scheme = Theme.of(ctx).colorScheme;
      return AlertDialog(
        icon: const Icon(Icons.key),
        title: Text('Código para $forName'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
              decoration: BoxDecoration(
                color: scheme.secondaryContainer,
                borderRadius: BorderRadius.circular(16),
              ),
              child: SelectableText(
                code.code,
                textAlign: TextAlign.center,
                style: text.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  letterSpacing: 3,
                  color: scheme.onSecondaryContainer,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Con esto entra y pone una contraseña nueva. Vale una vez y dura '
              'hasta el ${Fmt.full(code.expiresAt)}. Dáselo solo a $forName: '
              'no se vuelve a enseñar.',
              style: text.bodyMedium,
            ),
          ],
        ),
        actions: [
          TextButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: code.code));
              showMessage('Código copiado');
            },
            icon: const Icon(Icons.copy),
            label: const Text('Copiar'),
          ),
          FilledButton.icon(
            onPressed: () => SharePlus.instance.share(
              ShareParams(
                text:
                    'Tu código para entrar en El Furbo: ${code.code}\n'
                    'Ve a "¿Olvidaste la contraseña?" y ponlo con tu usuario.',
              ),
            ),
            icon: const Icon(Icons.share),
            label: const Text('Mandar'),
          ),
        ],
      );
    },
  );
}

/// Invitación para que un jugador sin cuenta reclame su perfil (con todo su
/// historial): una sola persona, la manda por WhatsApp quien la crea.
Future<void> inviteToClaim(WidgetRef ref, AppUser guest) async {
  final club = ref.read(currentClubProvider);
  if (club == null) return;
  try {
    final invite = await ref
        .read(clubAdminApiProvider)
        .createInvite(club.id, targetMemberId: guest.uid);
    ref.invalidate(invitesProvider(club.id));
    await shareInvite(ref, invite, clubName: club.name, claimName: guest.name);
  } catch (e) {
    showError(describeError(e));
  }
}

/// Código de recuperación para un miembro (se ve una sola vez).
Future<void> issueRecoveryCode(
  BuildContext context,
  WidgetRef ref,
  AppUser member,
) async {
  final club = ref.read(currentClubProvider);
  if (club == null) return;
  try {
    final code = await ref
        .read(clubAdminApiProvider)
        .recoveryCode(club.id, member.uid);
    if (!context.mounted) return;
    await showRecoveryCode(context, forName: member.name, code: code);
  } catch (e) {
    showError(describeError(e));
  }
}
