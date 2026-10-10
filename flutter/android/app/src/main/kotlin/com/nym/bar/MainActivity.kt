package com.nym.bar

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Resources
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PersistableBundle
import android.provider.OpenableColumns
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import android.view.WindowManager
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

// local_auth's BiometricPrompt requires a FragmentActivity host.
class MainActivity : FlutterFragmentActivity() {
    private var shareChannel: MethodChannel? = null
    private var callChannel: MethodChannel? = null
    private var pendingAnswer: String? = null
    private var secretSecure = false
    private var privacySecure = false

    private fun applySecureFlag() {
        if (secretSecure || privacySecure) {
            window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        } else {
            window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
        }
    }
    private val pendingShares = mutableListOf<Map<String, Any?>>()

    override fun onCreate(savedInstanceState: Bundle?) {
        intent?.let { first ->
            if (isShare(first)) {
                if (savedInstanceState == null) readShare(first)?.let { pendingShares.add(it) }
                setIntent(Intent(Intent.ACTION_MAIN))
            }
        }
        val action = intent?.action
        if ((action == NymRing.ACTION_ANSWER || action == NymRing.ACTION_OPEN) && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        }
        super.onCreate(savedInstanceState)
        handleCallIntent(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, Transcriber.CHANNEL)
            .setMethodCallHandler { call, result -> Transcriber.handle(applicationContext, call, result) }

        val share = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SHARE_CHANNEL)
        share.setMethodCallHandler { call, result ->
            when (call.method) {
                "initial" -> {
                    val held = ArrayList(pendingShares)
                    pendingShares.clear()
                    result.success(held)
                }
                else -> result.notImplemented()
            }
        }
        shareChannel = share

        // Foreground service for "Stay Connected in Background", started off-screen and released on resume.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            BACKGROUND_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val mesh = call.argument<Boolean>("mesh") ?: false
                    result.success(startBackgroundService(mesh))
                }
                "stop" -> {
                    stopBackgroundService()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        val callChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CALL_CHANNEL)
        this.callChannel = callChannel
        NymCallService.onHangup = { runOnUiThread { callChannel.invokeMethod("hangup", null) } }
        NymRing.onToken = { token ->
            runOnUiThread { callChannel.invokeMethod("ringToken", mapOf("platform" to "fcm", "token" to token)) }
        }
        NymRing.onAction = { action, callId ->
            runOnUiThread { callChannel.invokeMethod(action, mapOf("callId" to callId)) }
        }
        pendingAnswer?.let { id ->
            pendingAnswer = null
            callChannel.invokeMethod("answer", mapOf("callId" to id))
        }
        callChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "showIncoming" -> {
                    if (!NymRing.foreground) {
                        NymRing.show(
                            applicationContext,
                            call.argument<String>("callId") ?: "",
                            call.argument<String>("name") ?: "",
                            call.argument<String>("body") ?: "",
                            call.argument<Boolean>("video") ?: false,
                        )
                    }
                    result.success(null)
                }
                "endIncoming" -> {
                    NymRing.cancel(applicationContext)
                    result.success(null)
                }
                "ringSupported" -> result.success(NymRing.supported())
                "ringEnable" -> {
                    val strings = call.arguments as? Map<*, *>
                    if (strings != null) {
                        NymRing.saveStrings(
                            applicationContext,
                            strings.entries.mapNotNull { (k, v) -> if (k is String && v is String) k to v else null }.toMap(),
                        )
                    }
                    val source = NymRing.source()
                    if (source == null) {
                        result.success(false)
                    } else {
                        source.fetchToken(applicationContext) { token ->
                            if (token != null) NymRing.onNewToken(token)
                        }
                        result.success(true)
                    }
                }
                "ringDisable" -> {
                    NymRing.source()?.deleteToken(applicationContext)
                    result.success(null)
                }
                "stopOngoing" -> {
                    stopCallService()
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                        setShowWhenLocked(false)
                        setTurnScreenOn(false)
                    }
                    result.success(null)
                }
                "startOngoing" -> result.success(
                    startCallService(
                        call.argument<Boolean>("video") ?: false,
                        call.argument<String>("title") ?: "",
                        call.argument<String>("text") ?: "",
                        call.argument<String>("hangup") ?: "",
                    )
                )
                else -> result.notImplemented()
            }
        }

        // Build integrity: hash the installed APK and report signer and installer to Dart.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            BUILD_INTEGRITY_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "inspect" -> {
                    // Reads tens of megabytes; never on the platform thread.
                    Thread {
                        val payload = try {
                            BuildIntegrity.inspect(applicationContext)
                        } catch (e: Throwable) {
                            null
                        }
                        runOnUiThread {
                            if (payload == null) {
                                result.error("inspect_failed", "could not inspect the install", null)
                            } else {
                                result.success(payload)
                            }
                        }
                    }.start()
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            SECURE_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "secure" -> {
                    secretSecure = call.arguments == true
                    applySecureFlag()
                    result.success(null)
                }
                "copySecret" -> {
                    val text = call.argument<String>("text")
                    if (text == null) {
                        result.success(false)
                    } else {
                        result.success(copySecret(text))
                    }
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            PRIVACY_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "configure" -> {
                    privacySecure = call.argument<Boolean>("secure") ?: false
                    applySecureFlag()
                    result.success(null)
                }
                "isCaptured" -> result.success(false)
                else -> result.notImplemented()
            }
        }

        // App attestation: a Play Integrity verdict over a server challenge.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            ATTEST_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "attest" -> {
                    val challenge = call.argument<String>("challenge")
                    if (challenge.isNullOrEmpty()) {
                        result.success(null)
                    } else {
                        PlayIntegrity.requestToken(applicationContext, challenge) { token, reason ->
                            runOnUiThread {
                                result.success(
                                    if (token != null) mapOf("token" to token)
                                    else mapOf("reason" to (reason ?: "unknown"))
                                )
                            }
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            VAULT_KEY_CHANNEL,
        ).setMethodCallHandler { call, result -> vaultKey(call, Reply(result)) }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            PASSKEY_BACKUP_CHANNEL,
        ).setMethodCallHandler { call, result -> PasskeyBackup.handle(this, call, result) }
    }

    override fun onResume() {
        super.onResume()
        NymRing.foreground = true
        NymRing.cancel(applicationContext)
    }

    override fun onPause() {
        NymRing.foreground = false
        super.onPause()
    }

    private fun handleCallIntent(intent: Intent?): Boolean {
        val action = intent?.action ?: return false
        if (action != NymRing.ACTION_ANSWER && action != NymRing.ACTION_OPEN) return false
        NymRing.cancel(applicationContext)
        val callId = intent.getStringExtra(NymRing.EXTRA_CALL_ID) ?: ""
        if (action == NymRing.ACTION_ANSWER && callId.isNotEmpty()) {
            val channel = callChannel
            if (channel != null) {
                channel.invokeMethod("answer", mapOf("callId" to callId))
            } else {
                pendingAnswer = callId
            }
        }
        return true
    }

    override fun onNewIntent(intent: Intent) {
        if (handleCallIntent(intent)) return
        if (isShare(intent)) {
            val payload = readShare(intent) ?: return
            val channel = shareChannel
            if (channel == null) pendingShares.add(payload) else channel.invokeMethod("incoming", payload)
            return
        }
        super.onNewIntent(intent)
    }

    private fun copySecret(text: String): Boolean = try {
        val clip = ClipData.newPlainText("", text)
        val extras = PersistableBundle()
        if (Build.VERSION.SDK_INT >= 33) {
            extras.putBoolean(ClipDescription.EXTRA_IS_SENSITIVE, true)
        } else {
            extras.putBoolean("android.content.extra.IS_SENSITIVE", true)
        }
        clip.description.extras = extras
        val manager = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        manager.setPrimaryClip(clip)
        true
    } catch (e: Exception) {
        false
    }

    private fun isShare(intent: Intent): Boolean =
        intent.action == Intent.ACTION_SEND || intent.action == Intent.ACTION_SEND_MULTIPLE

    private fun readShare(intent: Intent): Map<String, Any?>? {
        val text = try {
            intent.getStringExtra(Intent.EXTRA_TEXT)
        } catch (e: Exception) {
            null
        }
        val files = mutableListOf<Map<String, Any?>>()
        var total = 0L
        for (uri in sharedStreams(intent).take(MAX_SHARED_FILES)) {
            val file = sharedFile(uri) ?: continue
            val size = (file["bytes"] as ByteArray).size
            if (total + size > MAX_SHARED_TOTAL_BYTES) break
            total += size
            files.add(file)
        }
        if (text.isNullOrBlank() && files.isEmpty()) return null
        return mapOf("text" to text, "files" to files)
    }

    @Suppress("DEPRECATION")
    private fun sharedStreams(intent: Intent): List<Uri> = try {
        if (intent.action == Intent.ACTION_SEND_MULTIPLE) {
            val list = if (Build.VERSION.SDK_INT >= 33) {
                intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
            } else {
                intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
            }
            list?.filterNotNull() ?: emptyList()
        } else {
            val one = if (Build.VERSION.SDK_INT >= 33) {
                intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
            } else {
                intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
            }
            if (one == null) emptyList() else listOf(one)
        }
    } catch (e: Exception) {
        emptyList()
    }

    private fun foreignContent(uri: Uri): Boolean {
        if (uri.scheme?.lowercase() != ContentResolver.SCHEME_CONTENT) return false
        val authority = uri.authority?.lowercase() ?: return false
        val own = packageName.lowercase()
        if (authority.split(';').any { it == own || it.startsWith("$own.") }) return false
        val owner = try {
            if (Build.VERSION.SDK_INT >= 33) {
                packageManager.resolveContentProvider(authority, PackageManager.ComponentInfoFlags.of(0))
            } else {
                @Suppress("DEPRECATION")
                packageManager.resolveContentProvider(authority, 0)
            }
        } catch (e: Exception) {
            null
        }
        return owner?.packageName != packageName
    }

    private fun sharedFile(uri: Uri): Map<String, Any?>? = if (!foreignContent(uri)) null else try {
        var name = "shared"
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
            if (c.moveToFirst()) c.getString(0)?.let { name = it }
        }
        val safe = File(name.replace('\\', '/')).name.trim().takeIf { it.isNotEmpty() && it != "." && it != ".." }
            ?: "shared"
        val bytes = contentResolver.openInputStream(uri)?.use { stream ->
            val out = java.io.ByteArrayOutputStream()
            val buffer = ByteArray(64 * 1024)
            var total = 0
            while (true) {
                val n = stream.read(buffer)
                if (n < 0) break
                total += n
                if (total > MAX_SHARED_BYTES) return@use null
                out.write(buffer, 0, n)
            }
            out.toByteArray()
        }
        if (bytes == null) null else mapOf("name" to safe, "mime" to contentResolver.getType(uri), "bytes" to bytes)
    } catch (e: Exception) {
        null
    }

    private class Reply(private val result: MethodChannel.Result) {
        private var sent = false

        fun success(value: Any?) {
            if (sent) return
            sent = true
            result.success(value)
        }

        fun error(code: String, message: String?) {
            if (sent) return
            sent = true
            result.error(code, message, null)
        }
    }

    private val keyFile: File get() = File(filesDir, VAULT_KEY_FILE)

    private fun vaultKey(call: MethodCall, reply: Reply) {
        try {
            when (call.method) {
                "store" -> storeKey(
                    call.argument<String>("secret") ?: return reply.error("failed", null),
                    call.argument<String>("title") ?: "",
                    call.argument<String>("cancel") ?: "",
                    reply,
                )
                "load" -> loadKey(
                    call.argument<String>("title") ?: "",
                    call.argument<String>("cancel") ?: "",
                    reply,
                )
                "erase" -> {
                    eraseKey()
                    reply.success(null)
                }
                "biometryType" -> reply.success(biometryType())
                else -> reply.error("unimplemented", call.method)
            }
        } catch (e: KeyPermanentlyInvalidatedException) {
            eraseKey()
            reply.error("invalidated", e.message)
        } catch (e: Exception) {
            reply.error("failed", e.message)
        }
    }

    private fun biometryType(): String {
        val status = BiometricManager.from(this).canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_STRONG)
        if (status == BiometricManager.BIOMETRIC_ERROR_NONE_ENROLLED ||
            status == BiometricManager.BIOMETRIC_ERROR_NO_HARDWARE
        ) {
            return "none"
        }
        val sensors = listOf(
            "android.hardware.fingerprint" to "fingerprint",
            "android.hardware.biometrics.face" to "face",
            "android.hardware.biometrics.iris" to "iris",
        ).filter { packageManager.hasSystemFeature(it.first) }.map { it.second }
        return strongBiometryName(strongSettingName(), sensors) { systemString(it) }
    }

    private fun strongSettingName(): String? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return null
        return runCatching {
            getSystemService(android.hardware.biometrics.BiometricManager::class.java)
                ?.getStrings(android.hardware.biometrics.BiometricManager.Authenticators.BIOMETRIC_STRONG)
                ?.settingName
                ?.toString()
        }.getOrNull()
    }

    private fun systemString(name: String): String? = runCatching {
        val resources = Resources.getSystem()
        val id = resources.getIdentifier(name, "string", "android")
        if (id == 0) null else resources.getString(id)
    }.getOrNull()

    private fun storeKey(secret: String, title: String, cancel: String, reply: Reply) {
        if (BiometricManager.from(this).canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_STRONG)
            != BiometricManager.BIOMETRIC_SUCCESS
        ) {
            return reply.error("unavailable", null)
        }
        eraseKey()
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, newKey())
        prompt(cipher, title, cancel, reply) { unlocked ->
            val sealed = unlocked.doFinal(secret.toByteArray(Charsets.UTF_8))
            keyFile.writeBytes(unlocked.iv + sealed)
            reply.success(null)
        }
    }

    private fun loadKey(title: String, cancel: String, reply: Reply) {
        val file = keyFile
        if (!file.exists()) return reply.success(null)
        val key = keyStore().getKey(VAULT_KEY_ALIAS, null) as SecretKey?
        if (key == null) {
            file.delete()
            return reply.error("invalidated", null)
        }
        val bytes = file.readBytes()
        if (bytes.size <= 12) return reply.error("failed", null)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, bytes, 0, 12))
        prompt(cipher, title, cancel, reply) { unlocked ->
            val clear = unlocked.doFinal(bytes, 12, bytes.size - 12)
            reply.success(String(clear, Charsets.UTF_8))
        }
    }

    private fun eraseKey() {
        runCatching { keyStore().deleteEntry(VAULT_KEY_ALIAS) }
        keyFile.delete()
    }

    private fun keyStore(): KeyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }

    private fun newKey(): SecretKey {
        val spec = KeyGenParameterSpec.Builder(
            VAULT_KEY_ALIAS,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
        )
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .setUserAuthenticationRequired(true)
            .setInvalidatedByBiometricEnrollment(true)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            spec.setUserAuthenticationParameters(0, KeyProperties.AUTH_BIOMETRIC_STRONG)
        } else {
            @Suppress("DEPRECATION")
            spec.setUserAuthenticationValidityDurationSeconds(-1)
        }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(spec.build())
        return generator.generateKey()
    }

    private fun prompt(
        cipher: Cipher,
        title: String,
        cancel: String,
        reply: Reply,
        done: (Cipher) -> Unit,
    ) {
        val callback = object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                val unlocked = result.cryptoObject?.cipher ?: return reply.error("failed", null)
                try {
                    done(unlocked)
                } catch (e: Exception) {
                    reply.error("failed", e.message)
                }
            }

            override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                val message = errString.toString()
                when (errorCode) {
                    BiometricPrompt.ERROR_USER_CANCELED,
                    BiometricPrompt.ERROR_NEGATIVE_BUTTON,
                    BiometricPrompt.ERROR_CANCELED,
                    BiometricPrompt.ERROR_TIMEOUT -> reply.error("cancelled", message)
                    BiometricPrompt.ERROR_NO_BIOMETRICS,
                    BiometricPrompt.ERROR_HW_NOT_PRESENT,
                    BiometricPrompt.ERROR_HW_UNAVAILABLE -> reply.error("unavailable", message)
                    else -> reply.error("failed", message)
                }
            }
        }
        val info = BiometricPrompt.PromptInfo.Builder()
            .setTitle(title)
            .setNegativeButtonText(cancel)
            .setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG)
            .setConfirmationRequired(false)
            .build()
        BiometricPrompt(this, ContextCompat.getMainExecutor(this), callback)
            .authenticate(info, BiometricPrompt.CryptoObject(cipher))
    }

    /** Returns whether the service started; Android 12+ can refuse background starts. */
    private fun startBackgroundService(mesh: Boolean): Boolean {
        val intent = Intent(this, NymBackgroundService::class.java).apply {
            putExtra(NymBackgroundService.EXTRA_MESH, mesh)
        }
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(intent)
            } else {
                startService(intent)
            }
            true
        } catch (t: Throwable) {
            false
        }
    }

    private fun startCallService(video: Boolean, title: String, text: String, hangup: String): Boolean {
        val intent = Intent(this, NymCallService::class.java).apply {
            putExtra(NymCallService.EXTRA_VIDEO, video)
            putExtra(NymCallService.EXTRA_TITLE, title)
            putExtra(NymCallService.EXTRA_TEXT, text)
            putExtra(NymCallService.EXTRA_HANGUP, hangup)
        }
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(intent)
            } else {
                startService(intent)
            }
            true
        } catch (t: Throwable) {
            false
        }
    }

    private fun stopCallService() {
        try {
            stopService(Intent(this, NymCallService::class.java))
        } catch (t: Throwable) {
        }
    }

    override fun onDestroy() {
        NymCallService.onHangup = null
        NymRing.onToken = null
        NymRing.onAction = null
        callChannel = null
        super.onDestroy()
    }

    private fun stopBackgroundService() {
        try {
            stopService(Intent(this, NymBackgroundService::class.java))
        } catch (t: Throwable) {
            // Never started or already gone.
        }
    }

    companion object {
        private const val SHARE_CHANNEL = "app.nymchat/share"
        private const val MAX_SHARED_FILES = 10
        private const val MAX_SHARED_BYTES = 16 * 1024 * 1024
        private const val MAX_SHARED_TOTAL_BYTES = 64L * 1024 * 1024
        private const val CALL_CHANNEL = "app.nymchat/call"
        private const val BACKGROUND_CHANNEL = "app.nymchat/background_connectivity"
        private const val BUILD_INTEGRITY_CHANNEL = "app.nymchat/build_integrity"
        private const val ATTEST_CHANNEL = "app.nymchat/attest"
        private const val SECURE_CHANNEL = "app.nymchat/secure"
        private const val PRIVACY_CHANNEL = "app.nymchat/privacy"
        private const val VAULT_KEY_CHANNEL = "app.nymchat/vault_key"
        private const val PASSKEY_BACKUP_CHANNEL = "app.nymchat/passkey_backup"
        private const val VAULT_KEY_ALIAS = "nymchat_vault_key"
        private const val VAULT_KEY_FILE = "nymchat_vault_key.bin"
    }
}

internal fun strongBiometryName(
    strongSetting: String?,
    sensors: List<String>,
    systemString: (String) -> String?,
): String {
    if (strongSetting != null) {
        val generic = systemString("biometric_app_setting_name")
        val named = listOf(
            "fingerprint_app_setting_name" to "fingerprint",
            "face_app_setting_name" to "face",
        ).filter { (resource, _) ->
            val label = systemString(resource)
            label != null && label == strongSetting && label != generic
        }
        if (named.size == 1 && named[0].second in sensors) return named[0].second
    }
    return if (sensors.size == 1) sensors[0] else "biometrics"
}
