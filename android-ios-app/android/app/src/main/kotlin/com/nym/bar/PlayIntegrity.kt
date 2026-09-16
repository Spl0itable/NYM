package com.nym.bar

import android.content.Context
import android.util.Base64
import com.google.android.play.core.integrity.IntegrityManagerFactory
import com.google.android.play.core.integrity.IntegrityTokenRequest
import java.security.MessageDigest

/**
 * Google Play Integrity: asks Play for a verdict on this app and device, bound
 * to a server-chosen challenge.
 *
 * The verdict is a token Google signs and only Google's API can decode, so the
 * server learns whether the caller is the app it published (PLAY_RECOGNIZED,
 * matching signing certificate) running on a device that passes basic
 * integrity — none of which a repackaged APK or a script can claim. The
 * challenge is folded in as `requestHash`, which is what makes the verdict
 * about THIS enrollment rather than one captured earlier.
 */
object PlayIntegrity {

    /**
     * The cloud project number Play Integrity issues verdicts under. Read from
     * the manifest so the release build can carry it without a code change;
     * absent, there is nothing to ask and attestation is simply unavailable.
     */
    private const val PROJECT_NUMBER_KEY = "com.nym.bar.PLAY_INTEGRITY_PROJECT_NUMBER"

    private fun projectNumber(context: Context): Long? {
        return try {
            val ai = context.packageManager.getApplicationInfo(
                context.packageName,
                android.content.pm.PackageManager.GET_META_DATA,
            )
            val raw = ai.metaData?.get(PROJECT_NUMBER_KEY)
            when (raw) {
                is Long -> raw
                is Int -> raw.toLong()
                is String -> raw.toLongOrNull()
                else -> null
            }
        } catch (t: Throwable) {
            null
        }
    }

    /**
     * The server binds its challenge into the verdict as `requestHash`, and
     * checks base64url(sha256(challenge)) against it. Padding is stripped
     * because that is the form the worker compares.
     */
    private fun requestHash(challenge: String): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(challenge.toByteArray(Charsets.UTF_8))
        return Base64.encodeToString(digest, Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP)
    }

    /**
     * Requests an integrity token for [challenge]. Calls [onResult] with the
     * token, or with null when this device cannot produce one — no Play
     * Services, an unconfigured project number, a network failure. Null means
     * "no proof", and the Dart side enrolls nothing rather than downgrading to
     * a weaker claim.
     */
    fun requestToken(context: Context, challenge: String, onResult: (String?) -> Unit) {
        val project = projectNumber(context)
        if (project == null || project <= 0L) {
            onResult(null)
            return
        }
        try {
            val manager = IntegrityManagerFactory.create(context.applicationContext)
            manager.requestIntegrityToken(
                IntegrityTokenRequest.builder()
                    .setCloudProjectNumber(project)
                    .setNonce(requestHash(challenge))
                    .build()
            )
                .addOnSuccessListener { response -> onResult(response.token()) }
                .addOnFailureListener { _ -> onResult(null) }
        } catch (t: Throwable) {
            onResult(null)
        }
    }
}
