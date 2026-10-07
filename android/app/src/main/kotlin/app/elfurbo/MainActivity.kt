package app.elfurbo

import android.content.Intent
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

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        initialLink = intent?.takeIf { it.action == Intent.ACTION_VIEW }?.dataString
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
