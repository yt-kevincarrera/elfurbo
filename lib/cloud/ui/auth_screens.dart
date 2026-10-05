import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';
import 'errors.dart';

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
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(Icons.sports_soccer, size: 96, color: scheme.primary),
              const SizedBox(height: 16),
              Text(
                'El Furbo',
                textAlign: TextAlign.center,
                style: text.displaySmall?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                'Goles, asistencias y MVP de tu grupo.\nPincha sin internet y se sincroniza solo cuando hay conexión.',
                textAlign: TextAlign.center,
                style: text.bodyLarge?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 48),
              FilledButton(
                onPressed: () => open(const LoginScreen()),
                child: const Text('Entrar'),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () => open(const RegisterScreen()),
                child: const Text('Crear cuenta'),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: () => open(const RegisterScreen(fromInvite: true)),
                child: const Text('Tengo un código de invitación'),
              ),
            ],
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
      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
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
      appBar: AppBar(title: Text(widget.title)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            ...widget.fields.expand((f) => [f, const SizedBox(height: 16)]),
            FilledButton(
              onPressed: _busy ? null : _submit,
              child: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
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
      if (widget.fromInvite)
        const Text(
          'Crea tu cuenta (o entra si ya tienes una) y después escribe el código de invitación.',
        ),
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
