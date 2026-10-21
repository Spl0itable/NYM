package com.nym.bar

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.zip.ZipFile

object AppShare {
    const val CHANNEL = "app.nymchat/app_share"
    private const val DIR = "apk-share"
    private val executor: ExecutorService = Executors.newSingleThreadExecutor()
    private val main by lazy { Handler(Looper.getMainLooper()) }

    fun register(context: Context, messenger: BinaryMessenger) {
        val app = context.applicationContext
        executor.execute { clear(app) }
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "apkInfo" -> runOff(result) { apkInfo(app) }
                "prepareCopy" -> runOff(result) { prepareCopy(app) }
                "clearCopies" -> runOff(result) {
                    clear(app)
                    true
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun runOff(result: MethodChannel.Result, work: () -> Any?) {
        executor.execute {
            val value = try {
                work()
            } catch (_: Throwable) {
                null
            }
            main.post { result.success(value) }
        }
    }

    private fun apkInfo(context: Context): Map<String, Any?> {
        val pm = context.packageManager
        val pkg = context.packageName
        val info = pm.getApplicationInfo(pkg, 0)
        val path = info.sourceDir
        return mapOf(
            "path" to path,
            "sizeBytes" to File(path).length(),
            "splitCount" to (info.splitSourceDirs?.size ?: 0),
            "installer" to BuildIntegrity.installerPackage(pm, pkg),
            "versionName" to BuildIntegrity.versionName(pm, pkg),
            "versionCode" to BuildIntegrity.versionCode(pm, pkg),
            "signerSha256" to BuildIntegrity.signingCertSha256(pm, pkg),
            "abis" to abisOf(path),
        )
    }

    internal fun abisOf(path: String): List<String> = try {
        ZipFile(path).use { zip ->
            val out = sortedSetOf<String>()
            val entries = zip.entries()
            while (entries.hasMoreElements()) {
                val name = entries.nextElement().name
                if (name.startsWith("lib/")) {
                    val slash = name.indexOf('/', 4)
                    if (slash > 4) out.add(name.substring(4, slash))
                }
            }
            out.toList()
        }
    } catch (_: Exception) {
        emptyList()
    }

    private fun prepareCopy(context: Context): String? {
        val pm = context.packageManager
        val pkg = context.packageName
        val info = pm.getApplicationInfo(pkg, 0)
        if (!info.splitSourceDirs.isNullOrEmpty()) return null
        val source = File(info.sourceDir)
        if (!source.isFile) return null
        val version = (BuildIntegrity.versionName(pm, pkg) ?: "").replace(Regex("[^A-Za-z0-9._+-]"), "_")
        val code = BuildIntegrity.versionCode(pm, pkg) ?: 0L
        clear(context)
        val dir = File(context.cacheDir, DIR)
        if (!dir.isDirectory && !dir.mkdirs()) return null
        val out = File(dir, "Nymchat-$version-$code.apk")
        source.inputStream().use { input -> out.outputStream().use { input.copyTo(it, 1 shl 16) } }
        return out.absolutePath
    }

    private fun clear(context: Context) {
        File(context.cacheDir, DIR).listFiles()?.forEach { it.delete() }
    }
}
