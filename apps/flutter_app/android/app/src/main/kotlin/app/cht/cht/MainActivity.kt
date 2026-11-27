package app.cht.cht

import android.app.Activity
import android.content.Intent
import android.content.Context
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.EventChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.OutputStream
import java.security.KeyStore
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class MainActivity : FlutterActivity() {
    override fun provideFlutterEngine(context: Context): FlutterEngine? = ChatRuntime.engine

    override fun shouldDestroyEngineWithHost(): Boolean = !ChatRuntime.running

    override fun onDestroy() {
        if (!ChatRuntime.running && ChatRuntime.engine === flutterEngine) {
            ChatRuntime.engine = null
            ChatRuntime.channel = null
            ChatRuntime.networkMonitor?.onCancel(null)
            ChatRuntime.networkMonitor = null
        }
        super.onDestroy()
    }
    override fun popSystemNavigator(): Boolean {
        moveTaskToBack(true)
        return true
    }

    private var imageResult: MethodChannel.Result? = null
    private var imageAsPath = false
    private var exportResult: MethodChannel.Result? = null
    private var exportContent: ByteArray? = null
    private var attachmentExportResult: MethodChannel.Result? = null
    private var attachmentOutput: OutputStream? = null
    private var attachmentExportUri: Uri? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        ChatRuntime.engine = flutterEngine
        val appContext = applicationContext
        val networkMonitor = ChatRuntime.networkMonitor ?: ChatNetworkMonitor(appContext).also {
            ChatRuntime.networkMonitor = it
            EventChannel(flutterEngine.dartExecutor.binaryMessenger, "app.cht/network").setStreamHandler(it)
        }
        ChatRuntime.channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app.cht/runtime").apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "configure" -> try {
                        result.success(ChatRuntime.configure(appContext,
                            call.argument<Boolean>("active") == true,
                            call.argument<Boolean>("enabled"),
                            call.argument<Boolean>("showLockAction"),
                            call.argument<Int>("backgroundRefreshSeconds")))
                    } catch (_: Exception) {
                        result.error("background_unavailable", "Could not start background reception", null)
                    }
                    "openBackgroundNotificationSettings" -> {
                        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                            result.notImplemented()
                        } else try {
                            ChatReceiveService.createNotificationChannel(appContext)
                            startActivity(Intent(Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS).apply {
                                putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                                putExtra(Settings.EXTRA_CHANNEL_ID, ChatReceiveService.NOTIFICATION_CHANNEL_ID)
                            })
                            result.success(null)
                        } catch (_: Exception) {
                            result.error("settings_unavailable", "Could not open background notification settings", null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app.cht/platform").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "networkState" -> result.success(networkMonitor.snapshot())
                    "availableStorage" -> result.success(android.os.StatFs(filesDir.absolutePath).availableBytes)
                    "storageConfiguration" -> result.success(storageConfiguration())
                    "createAttachmentExport" -> {
                        check(attachmentExportResult == null && attachmentOutput == null && exportResult == null) { "An export is already open" }
                        val name = requireNotNull(call.argument<String>("name"))
                        val mime = requireNotNull(call.argument<String>("mimeType"))
                        require(name.isNotBlank() && name.length <= 255 && !name.contains('/') && !name.contains('\\'))
                        attachmentExportResult = result
                        startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = mime
                            putExtra(Intent.EXTRA_TITLE, name)
                        }, 4734)
                    }
                    "writeAttachmentExport" -> {
                        val bytes = requireNotNull(call.argument<ByteArray>("bytes"))
                        require(bytes.size <= 1024 * 1024)
                        requireNotNull(attachmentOutput) { "No attachment export is open" }.write(bytes)
                        result.success(null)
                    }
                    "finishAttachmentExport" -> {
                        requireNotNull(attachmentOutput) { "No attachment export is open" }.close()
                        attachmentOutput = null
                        attachmentExportUri = null
                        result.success(null)
                    }
                    "cancelAttachmentExport" -> {
                        val output = attachmentOutput
                        val uri = attachmentExportUri
                        attachmentOutput = null
                        attachmentExportUri = null
                        try { output?.close() } catch (_: Exception) { }
                        try { uri?.let { contentResolver.delete(it, null, null) } } catch (_: Exception) { }
                        result.success(null)
                    }
                    "saveRecoveryPhrase", "saveContactQr" -> {
                        check(exportResult == null && attachmentExportResult == null && attachmentOutput == null) { "An export is already open" }
                        val isQr = call.method == "saveContactQr"
                        exportContent = if (isQr) {
                            requireNotNull(call.argument<ByteArray>("bytes")).also {
                                require(it.isNotEmpty() && it.size <= 2 * 1024 * 1024)
                            }
                        } else {
                            val phrase = requireNotNull(call.argument<String>("phrase"))
                            require(phrase.trim().split(Regex("\\s+")).size == 24)
                            ("chta recovery phrase\n\nWARNING: Anyone with these 24 words can control this identity.\nStore this file offline and delete unsafe copies.\n\n$phrase\n").toByteArray(Charsets.UTF_8)
                        }
                        exportResult = result
                        startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = if (isQr) "image/png" else "text/plain"
                            putExtra(Intent.EXTRA_TITLE, if (isQr) "chta-public-contact.png" else "chta-recovery-phrase.txt")
                        }, 4733)
                    }
                    "pickProfileImage", "pickContactQrImage" -> {
                        if (imageResult != null) { result.error("busy", "An image picker is already open", null) }
                        else {
                            imageResult = result
                            imageAsPath = call.method == "pickContactQrImage"
                            startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                                type = "image/*"
                                addCategory(Intent.CATEGORY_OPENABLE)
                            }, 4732)
                        }
                    }
                    else -> result.notImplemented()
                }
            } catch (_: Exception) {
                if (exportResult === result) {
                    exportContent?.fill(0)
                    exportContent = null
                    exportResult = null
                }
                if (imageResult === result) imageResult = null
                if (attachmentExportResult === result) attachmentExportResult = null
                result.error("platform_unavailable", "Unable to complete this Android operation", null)
            }
        }
    }

    private fun storageConfiguration(): Map<String, String> {
        val alias = "cht.storage.wrapping.v1"
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val key = (store.getKey(alias, null) as? SecretKey) ?: KeyGenerator.getInstance("AES", "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256).build())
        }.generateKey()
        val preferences = getSharedPreferences("cht.secure.storage", MODE_PRIVATE)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        val existing = preferences.getString("wrapped", null)
        val bytes = if (existing == null) {
            val fresh = ByteArray(32).also { SecureRandom().nextBytes(it) }
            cipher.init(Cipher.ENCRYPT_MODE, key)
            val encrypted = cipher.doFinal(fresh)
            check(preferences.edit().putString("wrapped", Base64.encodeToString(encrypted, Base64.NO_WRAP))
                .putString("iv", Base64.encodeToString(cipher.iv, Base64.NO_WRAP)).commit())
            fresh
        } else {
            val iv = Base64.decode(preferences.getString("iv", null), Base64.NO_WRAP)
            cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, iv))
            cipher.doFinal(Base64.decode(existing, Base64.NO_WRAP))
        }
        val encoded = Base64.encodeToString(bytes, Base64.NO_WRAP)
        bytes.fill(0)
        return mapOf("path" to File(filesDir, "cht").absolutePath, "wrappingKey" to encoded)
    }

    @Deprecated("Uses the activity result API supported by FlutterActivity")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == 4734) {
            val result = attachmentExportResult ?: return
            attachmentExportResult = null
            if (resultCode != Activity.RESULT_OK || data?.data == null) { result.success(false); return }
            try {
                attachmentOutput = requireNotNull(contentResolver.openOutputStream(data.data!!, "wt"))
                attachmentExportUri = data.data
                result.success(true)
            } catch (_: Exception) {
                attachmentOutput?.close()
                attachmentOutput = null
                attachmentExportUri = null
                result.error("export_unavailable", "Unable to open the selected file for streaming", null)
            }
            return
        }
        if (requestCode == 4733) {
            val result = exportResult ?: return
            val bytes = exportContent
            exportResult = null
            exportContent = null
            try {
                if (resultCode == Activity.RESULT_OK && data?.data != null && bytes != null) {
                    contentResolver.openOutputStream(data.data!!, "wt").use { output ->
                        requireNotNull(output).write(bytes)
                    }
                }
                result.success(null)
            } catch (_: Exception) {
                result.error("export_unavailable", "Unable to save the selected file", null)
            } finally { bytes?.fill(0) }
            return
        }
        if (requestCode != 4732) return
        val result = imageResult ?: return
        val returnPath = imageAsPath
        imageResult = null
        imageAsPath = false
        if (resultCode != Activity.RESULT_OK || data?.data == null) { result.success(null); return }
        try {
            contentResolver.openInputStream(data.data!!).use { input ->
                requireNotNull(input)
                val output = ByteArrayOutputStream()
                val buffer = ByteArray(8192)
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    require(output.size() + count <= 10 * 1024 * 1024)
                    output.write(buffer, 0, count)
                }
                if (returnPath) {
                    // Dart removes this app-private copy after offline QR analysis.
                    val temporary = File.createTempFile("cht-contact-qr-", ".image", cacheDir)
                    temporary.writeBytes(output.toByteArray())
                    result.success(temporary.absolutePath)
                } else { result.success(output.toByteArray()) }
            }
        } catch (_: Exception) { result.error("image_unavailable", "Unable to read image (maximum 10 MB)", null) }
    }
}
