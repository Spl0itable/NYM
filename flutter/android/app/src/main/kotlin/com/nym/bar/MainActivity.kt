package com.nym.bar

import android.content.Intent
import android.os.Build
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

// local_auth's Android BiometricPrompt requires the host Activity to be a
// FragmentActivity. With the default FlutterActivity, `authenticate()` throws
// PlatformException("no_fragment_activity", …), which surfaced in-app as
// "Biometric authentication failed." Extending FlutterFragmentActivity is the
// plugin's documented requirement and makes fingerprint/face unlock work.
class MainActivity : FlutterFragmentActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // "Stay Connected in Background": Dart asks for the foreground service
        // when the app goes off-screen and releases it on resume. See
        // NymBackgroundService and lib/services/platform/background_connectivity.dart.
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

        // "Build integrity": hash the installed APK and report who signed and
        // installed it, so Dart can compare against the developer's published,
        // signed release manifest. See BuildIntegrity.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            BUILD_INTEGRITY_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "inspect" -> {
                    // Reads tens of megabytes — never on the platform thread.
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
                    if (call.arguments == true) {
                        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    } else {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        // App attestation: a Play Integrity verdict over a server challenge,
        // which the backend exchanges for the badge that marks this install's
        // pubkey as a real Nymchat client. See PlayIntegrity and
        // lib/services/attest/attest_service.dart.
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
                else -> reply.error("unimplemented", call.method)
            }
        } catch (e: KeyPermanentlyInvalidatedException) {
            eraseKey()
            reply.error("invalidated", e.message)
        } catch (e: Exception) {
            reply.error("failed", e.message)
        }
    }

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

    /**
     * Returns whether the service was actually started. A start can be refused
     * by the OS (background-start restrictions on Android 12+ when the app is
     * already too far into the background), and Dart treats that as "not
     * running" rather than pretending the connection is being held.
     */
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

    private fun stopBackgroundService() {
        try {
            stopService(Intent(this, NymBackgroundService::class.java))
        } catch (t: Throwable) {
            // Never started / already gone.
        }
    }

    companion object {
        private const val BACKGROUND_CHANNEL = "app.nymchat/background_connectivity"
        private const val BUILD_INTEGRITY_CHANNEL = "app.nymchat/build_integrity"
        private const val ATTEST_CHANNEL = "app.nymchat/attest"
        private const val SECURE_CHANNEL = "app.nymchat/secure"
        private const val VAULT_KEY_CHANNEL = "app.nymchat/vault_key"
        private const val PASSKEY_BACKUP_CHANNEL = "app.nymchat/passkey_backup"
        private const val VAULT_KEY_ALIAS = "nymchat_vault_key"
        private const val VAULT_KEY_FILE = "nymchat_vault_key.bin"
    }
}
