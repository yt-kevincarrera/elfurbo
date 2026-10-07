package app.elfurbo

import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Pasa a Dart los enlaces con los que se abre la app (elfurbo://invite/CODIGO):
 * el de arranque se pide con "initial" (una vez) y los que llegan con la app
 * abierta se mandan con "link". Ver lib/core/deep_links.dart.
 */
class MainActivity : FlutterActivity() {
    private var links: MethodChannel? = null
    private var initialLink: String? = null
    private var restored = false

    override fun onCreate(savedInstanceState: Bundle?) {
        // Recreada por el sistema (rotación, proceso que volvió): el enlace ya se atendió.
        restored = savedInstanceState != null
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Abrir desde recientes trae otra vez el intent con el que empezó la tarea.
        val fromHistory = (intent?.flags ?: 0) and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0
        initialLink = intent?.takeIf { it.action == Intent.ACTION_VIEW && !fromHistory && !restored }?.dataString
        links = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app.elfurbo/links").apply {
            setMethodCallHandler { call, result ->
                if (call.method == "initial") {
                    result.success(initialLink)
                    initialLink = null
                } else {
                    result.notImplemented()
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (intent.action == Intent.ACTION_VIEW) {
            intent.dataString?.let { links?.invokeMethod("link", it) }
        }
    }
}
