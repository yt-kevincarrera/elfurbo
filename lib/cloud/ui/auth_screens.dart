import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';
import 'errors.dart';
import '../../ui/widgets/chalk.dart';
import '../../ui/widgets/expressive.dart';

/// Primera pantalla sin sesión: entrar, crear cuenta o empezar con una invitación.
class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    void open(Widget screen) => Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => screen));
    const big = ButtonStyle(
      minimumSize: WidgetStatePropertyAll(Size.fromHeight(56)),
    );
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(),
              const Center(child: _Hero()),
              const SizedBox(height: 40),
              Text(
                'El Furbo',
                style: text.displayMedium?.copyWith(color: scheme.onSurface),
              ),
              const SizedBox(height: 12),
              Text(
                'Goles, asistencias y MVP de tu grupo. Pincha sin internet y se sincroniza solo cuando hay conexión.',
                style: text.bodyLarge?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const Spacer(),
              FilledButton(
                style: big,
                onPressed: () => open(const LoginScreen()),
                child: const Text('Entrar'),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                style: big,
                onPressed: () => open(const RegisterScreen()),
                child: const Text('Crear cuenta'),
              ),
              const SizedBox(height: 8),
              TextButton(
                style: big,
                onPressed: () => open(const RegisterScreen(fromInvite: true)),
                child: const Text('Tengo un código de invitación'),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}

/// Una jugada dibujada a tiza: la cancha, tres fichas y la flecha. Entra
/// con un rebote y se queda quieta.
class _Hero extends StatefulWidget {
  const _Hero();

  @override
  State<_Hero> createState() => _HeroState();
}

class _HeroState extends State<_Hero> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..forward();
  late final Animation<double> _in = CurvedAnimation(
    parent: _c,
    curve: Curves.easeOutBack,
  );

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const t = 34.0;
    return ScaleTransition(
      scale: _in,
      child: Transform.rotate(
        angle: -.04,
        child: SizedBox(
          width: 300,
          height: 196,
          child: LayoutBuilder(
            builder: (context, box) {
              Offset at(double x, double y) =>
                  Offset(x * box.maxWidth, y * box.maxHeight);
              Widget token(double x, double y, String l, Color c, bool fill) =>
                  Positioned(
                    left: at(x, y).dx - t / 2,
                    top: at(x, y).dy - t / 2,
                    child: ChalkToken(
                      label: l,
                      color: c,
                      filled: fill,
                      dashed: !fill,
                      size: t,
                    ),
                  );
              return ChalkPitch(
                children: [
                  Positioned.fill(
                    child: ChalkArrow(
                      from: at(.3, .5) + const Offset(t / 2, 0),
                      to: at(.74, .4) - const Offset(t / 2, 2),
                    ),
                  ),
                  token(.1, .5, '1', Chalk.yellow, true),
                  token(.3, .5, '10', Chalk.yellow, true),
                  token(.24, .2, '7', Chalk.yellow, true),
                  token(.74, .4, '9', Chalk.green, false),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Formulario de cuenta con su botón, el estado de "cargando" y el error.
class _AuthForm extends StatefulWidget {
  const _AuthForm({
    required this.title,
    required this.fields,
    required this.submitLabel,
    required this.onSubmit,
    this.footer,
  });

  final String title;
  final List<Widget> fields;
  final String submitLabel;
  final Future<void> Function() onSubmit;
  final Widget? footer;

  @override
  State<_AuthForm> createState() => _AuthFormState();
}

class _AuthFormState extends State<_AuthForm> {
  bool _busy = false;
  String? _error;

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onSubmit();
      // Solo si esta pantalla sigue siendo la de arriba: al entrar con un enlace
      // de invitación, la app ya volvió a la raíz y abrió encima "Entrar con
      // código", que no hay que cerrar.
      if (mounted && (ModalRoute.of(context)?.isCurrent ?? false)) {
        Navigator.of(context).popUntil((r) => r.isFirst);
      }
    } catch (e) {
      if (mounted) setState(() => _error = describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          children: [
            Text(
              widget.title,
              style: Theme.of(context).textTheme.headlineLarge,
            ),
            const SizedBox(height: 28),
            ...widget.fields.expand((f) => [f, const SizedBox(height: 16)]),
            const SizedBox(height: 8),
            FilledButton(
              style: const ButtonStyle(
                minimumSize: WidgetStatePropertyAll(Size.fromHeight(56)),
              ),
              onPressed: _busy ? null : _submit,
              child: _busy
                  ? const SizedBox(
                      width: 28,
                      height: 28,
                      child: AppLoading(size: 28),
                    )
                  : Text(widget.submitLabel),
            ),
            if (_error != null) ...[
              const SizedBox(height: 16),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.error),
              ),
            ],
            if (widget.footer != null) ...[
              const SizedBox(height: 24),
              widget.footer!,
            ],
          ],
        ),
      ),
    );
  }
}

TextField _field(
  TextEditingController c,
  String label, {
  bool password = false,
  String? hint,
}) => TextField(
  controller: c,
  obscureText: password,
  autocorrect: false,
  enableSuggestions: !password,
  textCapitalization: TextCapitalization.none,
  decoration: InputDecoration(
    labelText: label,
    helperText: hint,
    border: const OutlineInputBorder(),
  ),
);

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _user = TextEditingController();
  final _pass = TextEditingController();

  @override
  Widget build(BuildContext context) => _AuthForm(
    title: 'Entrar',
    fields: [
      _field(_user, 'Usuario'),
      _field(_pass, 'Contraseña', password: true),
    ],
    submitLabel: 'Entrar',
    onSubmit: () => ref.read(cloudProvider).login(_user.text, _pass.text),
    footer: TextButton(
      onPressed: () => Navigator.of(
        context,
      ).push(MaterialPageRoute<void>(builder: (_) => const RecoverScreen())),
      child: const Text('¿Olvidaste la contraseña?'),
    ),
  );
}

class RegisterScreen extends ConsumerStatefulWidget {
  const RegisterScreen({super.key, this.fromInvite = false});

  /// Llegó con "Tengo un código": después de crear la cuenta se le pide el código.
  final bool fromInvite;

  @override
  ConsumerState<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends ConsumerState<RegisterScreen> {
  final _name = TextEditingController();
  final _user = TextEditingController();
  final _pass = TextEditingController();

  @override
  Widget build(BuildContext context) => _AuthForm(
    title: widget.fromInvite ? 'Primero, tu cuenta' : 'Crear cuenta',
    fields: [
      if (widget.fromInvite) ...[
        const Text(
          'Crea tu cuenta y después entras al servidor con el código (si llegaste por un enlace, ya está puesto).',
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: () => Navigator.of(context).pushReplacement(
              MaterialPageRoute<void>(builder: (_) => const LoginScreen()),
            ),
            child: const Text('Ya tengo cuenta: entrar'),
          ),
        ),
      ],
      _field(_name, 'Tu nombre', hint: 'Cómo te dicen en el grupo'),
      _field(
        _user,
        'Usuario',
        hint: 'De 3 a 20: letras sin tildes, números, punto o guion bajo',
      ),
      _field(_pass, 'Contraseña', password: true, hint: 'Mínimo 8 caracteres'),
    ],
    submitLabel: 'Crear cuenta',
    onSubmit: () => ref
        .read(cloudProvider)
        .register(
          username: _user.text,
          password: _pass.text,
          displayName: _name.text,
        ),
  );
}

/// Con el código que le genera un admin del servidor (o el superadmin).
class RecoverScreen extends ConsumerStatefulWidget {
  const RecoverScreen({super.key});

  @override
  ConsumerState<RecoverScreen> createState() => _RecoverScreenState();
}

class _RecoverScreenState extends ConsumerState<RecoverScreen> {
  final _user = TextEditingController();
  final _code = TextEditingController();
  final _pass = TextEditingController();

  @override
  Widget build(BuildContext context) => _AuthForm(
    title: 'Recuperar la cuenta',
    fields: [
      const Text(
        'Pídele un código de recuperación a un admin de tu servidor. Vale una vez y dura 24 horas.',
      ),
      _field(_user, 'Usuario'),
      _field(_code, 'Código', hint: 'Por ejemplo ABCD-EFGH'),
      _field(
        _pass,
        'Contraseña nueva',
        password: true,
        hint: 'Mínimo 8 caracteres',
      ),
    ],
    submitLabel: 'Cambiar contraseña y entrar',
    onSubmit: () => ref
        .read(cloudProvider)
        .recover(
          username: _user.text,
          code: _code.text,
          newPassword: _pass.text,
        ),
  );
}
