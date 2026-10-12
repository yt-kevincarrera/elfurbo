package app.elfurbo.furbo_http3

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.chromium.net.CronetEngine
import org.chromium.net.CronetException
import org.chromium.net.ExperimentalCronetEngine
import org.chromium.net.UploadDataProviders
import org.chromium.net.UrlRequest
import org.chromium.net.UrlResponseInfo
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.ByteBuffer
import java.util.concurrent.Executors

/**
 * Peticiones HTTP con Cronet, la pila de red de Chrome. En Cuba, ETECSA corta las conexiones TLS
 * cuyo nombre (SNI) acaba en `.workers.dev`; Chrome pasa porque va por HTTP/3 y con el nombre
 * cifrado (ECH), que aprende del registro DNS HTTPS del servidor. Aquí se hace lo mismo.
 *
 * Un solo motor por proceso: lo comparten la app y el sync en segundo plano (otro FlutterEngine).
 */
class FurboHttp3Plugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var context: Context

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "app.elfurbo/http3")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "send" -> send(call, result)
            else -> result.notImplemented()
        }
    }

    private fun send(call: MethodCall, result: MethodChannel.Result) {
        val url = call.argument<String>("url")!!
        val engine = try {
            engine(context, call.argument<List<String>>("quicHosts") ?: emptyList())
        } catch (e: Throwable) {
            result.error("unavailable", "Cronet no arrancó: $e", null)
            return
        }
        val main = Handler(Looper.getMainLooper())
        val body = ByteArrayOutputStream()
        val callback = object : UrlRequest.Callback() {
            override fun onRedirectReceived(request: UrlRequest, info: UrlResponseInfo, newLocationUrl: String) {
                request.followRedirect()
            }

            override fun onResponseStarted(request: UrlRequest, info: UrlResponseInfo) {
                request.read(ByteBuffer.allocateDirect(64 * 1024))
            }

            override fun onReadCompleted(request: UrlRequest, info: UrlResponseInfo, buffer: ByteBuffer) {
                buffer.flip()
                val chunk = ByteArray(buffer.remaining())
                buffer.get(chunk)
                body.write(chunk)
                buffer.clear()
                request.read(buffer)
            }

            override fun onSucceeded(request: UrlRequest, info: UrlResponseInfo) {
                val headers = HashMap<String, String>()
                for ((name, values) in info.allHeaders) headers[name.lowercase()] = values.joinToString(", ")
                val reply = mapOf(
                    "status" to info.httpStatusCode,
                    "headers" to headers,
                    "body" to body.toByteArray(),
                    "protocol" to info.negotiatedProtocol,
                )
                main.post { result.success(reply) }
            }

            override fun onFailed(request: UrlRequest, info: UrlResponseInfo?, error: CronetException) {
                main.post { result.error("network", error.message ?: "$error", null) }
            }

            override fun onCanceled(request: UrlRequest, info: UrlResponseInfo?) {
                main.post { result.error("network", "Cancelada", null) }
            }
        }
        val builder = engine.newUrlRequestBuilder(url, callback, executor)
            .setHttpMethod(call.argument<String>("method") ?: "GET")
            .disableCache()
        val headers = call.argument<Map<String, String>>("headers") ?: emptyMap()
        for ((name, value) in headers) builder.addHeader(name, value)
        val upload = call.argument<ByteArray>("body")
        if (upload != null && upload.isNotEmpty()) {
            // Cronet exige content-type para enviar cuerpo.
            if (headers.keys.none { it.equals("content-type", ignoreCase = true) }) {
                builder.addHeader("content-type", "application/octet-stream")
            }
            builder.setUploadDataProvider(UploadDataProviders.create(upload), executor)
        }
        builder.build().start()
    }

    companion object {
        private val executor = Executors.newCachedThreadPool()

        @Volatile
        private var shared: CronetEngine? = null

        @Synchronized
        private fun engine(context: Context, quicHosts: List<String>): CronetEngine {
            shared?.let { return it }
            val storage = File(context.cacheDir, "cronet").apply { mkdirs() }
            val builder = ExperimentalCronetEngine.Builder(context)
            builder.enableQuic(true)
            builder.enableHttp2(true)
            builder.enableBrotli(true)
            // Guarda lo aprendido (que el servidor habla HTTP/3) para la próxima vez.
            builder.setStoragePath(storage.absolutePath)
            builder.enableHttpCache(CronetEngine.Builder.HTTP_CACHE_DISK_NO_HTTP, 1024 * 1024)
            // Sin esperar a una primera respuesta por TCP (que en Cuba se corta): HTTP/3 de entrada.
            for (host in quicHosts) builder.addQuicHint(host, 443, 443)
            // DNS propio de Chromium: así lee el registro HTTPS (HTTP/3 y la clave de ECH), como Chrome.
            builder.setExperimentalOptions(
                JSONObject()
                    .put("AsyncDNS", JSONObject().put("enable", true))
                    .put("UseDnsHttpsSvcb", JSONObject().put("enable", true))
                    .put("QUIC", JSONObject().put("use_dns_https_svcb_alpn", true))
                    .toString()
            )
            return builder.build().also { shared = it }
        }
    }
}
