package com.nym.bar

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import java.io.File
import java.security.MessageDigest

/**
 * What the app can measure about the copy of itself that is installed.
 *
 * The web app re-hashes every file it is running and looks the result up in the
 * repository's signed attestations. A native build cannot do that with its own
 * source — what runs here is AOT machine code, not the Dart in
 * `android-ios-app/`, and nothing on the device relates one to the other. What
 * Android DOES offer is the installed APK itself, readable at
 * `ApplicationInfo.sourceDir`, so the same shape of proof is available: hash
 * the artifact locally, and compare against a hash the developer published and
 * signed. Neither half trusts the other, and a third party can repeat both.
 *
 * The catch is Google Play. Play App Signing re-signs the upload with Google's
 * key and delivers per-device split APKs generated from the App Bundle, so what
 * lands on a Play device is not the file the developer built and its hash
 * matches nothing publishable. Dart needs to know that, so the installer
 * package and the split count are reported alongside the hash rather than
 * being folded into a verdict here.
 */
object BuildIntegrity {

    /**
     * Measures the install. Blocking: hashing the APK reads tens of megabytes,
     * so callers must run this off the main thread.
     */
    fun inspect(context: Context): Map<String, Any?> {
        val pm = context.packageManager
        val pkg = context.packageName
        val appInfo = pm.getApplicationInfo(pkg, 0)
        val splits = appInfo.splitSourceDirs?.toList() ?: emptyList()

        return mapOf(
            "packageName" to pkg,
            "apkSha256" to sha256OfFile(appInfo.sourceDir),
            // A universal sideloaded APK has none. A Play install almost always
            // has several (per-ABI, per-density, per-language), which is on its
            // own enough to know the base APK is not the published artifact.
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

    /**
     * SHA-256 of the certificate the install is signed with — the same value
     * `keytool -printcert -jarfile` prints for the built APK, and the value
     * Play Console shows for the app-signing key on a Play build.
     *
     * Worth reporting even where the APK hash cannot be compared: it is what
     * separates a Play install from a repackaged APK sideloaded under the same
     * package name.
     */
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
