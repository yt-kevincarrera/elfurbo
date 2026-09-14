import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';

/// Opcional: "Web client ID" de OAuth de tu proyecto de Firebase. En Android
/// normalmente no hace falta porque se toma de google-services.json, pero si
/// el idToken llega null, compilá con:
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
        'Google no devolvió un idToken. Revisá el SHA-1 en Firebase o definí GOOGLE_SERVER_CLIENT_ID.',
      );
    }
    final credential = GoogleAuthProvider.credential(idToken: idToken);
    return _auth.signInWithCredential(credential);
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
