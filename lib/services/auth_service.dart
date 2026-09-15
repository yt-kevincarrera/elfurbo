import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../core/network_hints.dart';

/// Opcional: "Web client ID" de OAuth de tu proyecto de Firebase. En Android
/// normalmente no hace falta porque se toma de google-services.json, pero si
/// el idToken llega null, compila con:
///   flutter build apk --dart-define=GOOGLE_SERVER_CLIENT_ID=xxxx.apps.googleusercontent.com
const String kGoogleServerClientId = String.fromEnvironment(
  'GOOGLE_SERVER_CLIENT_ID',
);

class AuthService {
  AuthService([FirebaseAuth? auth]) : _auth = auth ?? FirebaseAuth.instance;

  final FirebaseAuth _auth;
  bool _initialized = false;

  Stream<User?> get authStateChanges => _auth.authStateChanges();
  User? get currentUser => _auth.currentUser;

  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    await GoogleSignIn.instance.initialize(
      serverClientId: kGoogleServerClientId.isEmpty
          ? null
          : kGoogleServerClientId,
    );
    _initialized = true;
  }

  /// Login con Google. Devuelve null si el usuario canceló.
  Future<UserCredential?> signInWithGoogle() async {
    await _ensureInitialized();
    final GoogleSignInAccount account;
    try {
      account = await GoogleSignIn.instance.authenticate();
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) return null;
      throw Exception('No se pudo iniciar sesión con Google (${e.code.name}).');
    }
    final idToken = account.authentication.idToken;
    if (idToken == null) {
      throw Exception(
        'Google no devolvió un idToken. Revisa el SHA-1 en Firebase o define GOOGLE_SERVER_CLIENT_ID.',
      );
    }
    final credential = GoogleAuthProvider.credential(idToken: idToken);
    try {
      return await _auth.signInWithCredential(credential);
    } on FirebaseException catch (e) {
      // Desde Cuba la API de Firebase Auth responde 403 aunque la cuenta de
      // Google esté bien: lo decimos claro en vez de mostrar el error crudo.
      if (looksLikeBlockedNetwork(e)) {
        throw Exception(
          'Google no está disponible desde tu red (${e.code}). $vpnHint',
        );
      }
      throw Exception('No se pudo iniciar sesión: ${e.message ?? e.code}');
    }
  }

  /// Borra la cuenta de Firebase Auth. Si la sesión es vieja, Firebase exige
  /// reautenticación: se vuelve a pedir la cuenta de Google y se reintenta.
  Future<void> deleteAccount() async {
    final user = _auth.currentUser;
    if (user == null) return;
    await _ensureInitialized();
    try {
      await user.delete();
    } on FirebaseAuthException catch (e) {
      if (e.code != 'requires-recent-login') rethrow;
      final GoogleSignInAccount account;
      try {
        account = await GoogleSignIn.instance.authenticate();
      } on GoogleSignInException catch (e) {
        if (e.code == GoogleSignInExceptionCode.canceled) {
          throw Exception(
            'Hace falta volver a entrar con Google para borrar la cuenta.',
          );
        }
        throw Exception('No se pudo reautenticar con Google (${e.code.name}).');
      }
      final idToken = account.authentication.idToken;
      if (idToken == null) {
        throw Exception('Google no devolvió un idToken al reautenticar.');
      }
      await user.reauthenticateWithCredential(
        GoogleAuthProvider.credential(idToken: idToken),
      );
      await user.delete();
    }
    try {
      await GoogleSignIn.instance.signOut();
    } catch (_) {}
  }

  Future<void> signOut() async {
    await _ensureInitialized();
    try {
      await GoogleSignIn.instance.signOut();
    } catch (_) {
      // Si Google falla al cerrar, igual cerramos Firebase.
    }
    await _auth.signOut();
  }
}
