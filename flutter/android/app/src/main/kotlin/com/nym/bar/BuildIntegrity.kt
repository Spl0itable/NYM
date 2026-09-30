package com.nym.bar

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import java.io.File
import java.security.MessageDigest

/** Measures the installed APK (hash, signer, installer, splits) for Dart to compare to the release. */
object BuildIntegrity {

    /** Blocking: hashing reads tens of megabytes, so call off the main thread. */
    fun inspect(context: Context): Map<String, Any?> {
        val pm = context.packageManager
        val pkg = context.packageName
        val appInfo = pm.getApplicationInfo(pkg, 0)
        val splits = appInfo.splitSourceDirs?.toList() ?: emptyList()

        return mapOf(
            "packageName" to pkg,
            "apkSha256" to sha256OfFile(appInfo.sourceDir),
            // Sideloaded universal APKs have no splits; Play installs almost always do.
            "splitCount" to splits.size,
            "signerSha256" to signingCertSha256(pm, pkg),
            "installer" to installerPackage(pm, pkg),
            "versionName" to versionName(pm, pkg),
            "versionCode" to versionCode(pm, pkg),
        )
    }

    private fun sha256OfFile(path: String?): String? {
        if (path.isNullOrEmpty()) return null
        val file = File(path)
        if (!file.isFile) return null
        return try {
            val digest = MessageDigest.getInstance("SHA-256")
            file.inputStream().use { stream ->
                val buffer = ByteArray(1 shl 16)
                while (true) {
                    val read = stream.read(buffer)
                    if (read <= 0) break
                    digest.update(buffer, 0, read)
                }
            }
            digest.digest().toHex()
        } catch (_: Throwable) {
            null
        }
    }

    /** SHA-256 of the signing certificate, which separates Play installs from repackaged sideloads. */
    private fun signingCertSha256(pm: PackageManager, pkg: String): String? {
        return try {
            @Suppress("DEPRECATION")
            val certs: Array<android.content.pm.Signature>? =
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                    val info = pm.getPackageInfo(pkg, PackageManager.GET_SIGNING_CERTIFICATES)
                    val signing = info.signingInfo ?: return null
                    if (signing.hasMultipleSigners()) signing.apkContentsSigners
                    else signing.signingCertificateHistory
                } else {
                    pm.getPackageInfo(pkg, PackageManager.GET_SIGNATURES).signatures
                }
            val first = certs?.firstOrNull() ?: return null
            MessageDigest.getInstance("SHA-256").digest(first.toByteArray()).toHex()
        } catch (_: Throwable) {
            null
        }
    }

    private fun installerPackage(pm: PackageManager, pkg: String): String? {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                pm.getInstallSourceInfo(pkg).installingPackageName
            } else {
                @Suppress("DEPRECATION")
                pm.getInstallerPackageName(pkg)
            }
        } catch (_: Throwable) {
            null
        }
    }

    private fun versionName(pm: PackageManager, pkg: String): String? = try {
        pm.getPackageInfo(pkg, 0).versionName
    } catch (_: Throwable) {
        null
    }

    private fun versionCode(pm: PackageManager, pkg: String): Long? = try {
        val info = pm.getPackageInfo(pkg, 0)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.longVersionCode
        } else {
            @Suppress("DEPRECATION")
            info.versionCode.toLong()
        }
    } catch (_: Throwable) {
        null
    }

    private fun ByteArray.toHex(): String {
        val out = StringBuilder(size * 2)
        for (b in this) {
            val v = b.toInt() and 0xFF
            out.append("0123456789abcdef"[v ushr 4])
            out.append("0123456789abcdef"[v and 0x0F])
        }
        return out.toString()
    }
}
