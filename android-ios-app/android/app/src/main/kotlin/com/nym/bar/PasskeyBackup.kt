package com.nym.bar

import android.app.Activity
import android.os.Build
import androidx.core.content.ContextCompat
import androidx.credentials.CreateCredentialResponse
import androidx.credentials.CreatePublicKeyCredentialRequest
import androidx.credentials.CreatePublicKeyCredentialResponse
import androidx.credentials.CredentialManager
import androidx.credentials.CredentialManagerCallback
import androidx.credentials.GetCredentialRequest
import androidx.credentials.GetCredentialResponse
import androidx.credentials.GetPublicKeyCredentialOption
import androidx.credentials.PublicKeyCredential
import androidx.credentials.exceptions.CreateCredentialCancellationException
import androidx.credentials.exceptions.CreateCredentialException
import androidx.credentials.exceptions.GetCredentialCancellationException
import androidx.credentials.exceptions.GetCredentialException
import androidx.credentials.exceptions.NoCredentialException
import androidx.credentials.exceptions.domerrors.DomError
import androidx.credentials.exceptions.domerrors.InvalidStateError
import androidx.credentials.exceptions.domerrors.NotSupportedError
import androidx.credentials.exceptions.domerrors.SecurityError
import androidx.credentials.exceptions.publickeycredential.CreatePublicKeyCredentialDomException
import androidx.credentials.exceptions.publickeycredential.GetPublicKeyCredentialDomException
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

object PasskeyBackup {
    fun handle(activity: Activity, call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isAvailable" -> result.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.P)
            "create" -> create(activity, call.argument<String>("requestJson"), result)
            "get" -> get(activity, call.argument<String>("requestJson"), result)
            else -> result.notImplemented()
        }
    }

    private fun create(activity: Activity, json: String?, result: MethodChannel.Result) {
        if (json == null) {
            result.error("bad_args", null, null)
            return
        }
        CredentialManager.create(activity).createCredentialAsync(
            activity,
            CreatePublicKeyCredentialRequest(json),
            null,
            ContextCompat.getMainExecutor(activity),
            object : CredentialManagerCallback<CreateCredentialResponse, CreateCredentialException> {
                override fun onResult(response: CreateCredentialResponse) {
                    if (response is CreatePublicKeyCredentialResponse) {
                        result.success(response.registrationResponseJson)
                    } else {
                        result.error("other", "unexpected response", null)
                    }
                }

                override fun onError(e: CreateCredentialException) {
                    result.error(createCode(e), e.message, null)
                }
            },
        )
    }

    private fun get(activity: Activity, json: String?, result: MethodChannel.Result) {
        if (json == null) {
            result.error("bad_args", null, null)
            return
        }
        val request = GetCredentialRequest(listOf(GetPublicKeyCredentialOption(json)))
        CredentialManager.create(activity).getCredentialAsync(
            activity,
            request,
            null,
            ContextCompat.getMainExecutor(activity),
            object : CredentialManagerCallback<GetCredentialResponse, GetCredentialException> {
                override fun onResult(response: GetCredentialResponse) {
                    val credential = response.credential
                    if (credential is PublicKeyCredential) {
                        result.success(credential.authenticationResponseJson)
                    } else {
                        result.error("other", "unexpected credential", null)
                    }
                }

                override fun onError(e: GetCredentialException) {
                    result.error(getCode(e), e.message, null)
                }
            },
        )
    }

    private fun domCode(error: DomError): String? = when (error) {
        is InvalidStateError -> "exists"
        is SecurityError -> "rp"
        is NotSupportedError -> "unsupported"
        else -> null
    }

    private fun createCode(e: CreateCredentialException): String = when (e) {
        is CreateCredentialCancellationException -> "canceled"
        is CreatePublicKeyCredentialDomException -> domCode(e.domError) ?: "other"
        else -> "other"
    }

    private fun getCode(e: GetCredentialException): String = when (e) {
        is GetCredentialCancellationException -> "canceled"
        is NoCredentialException -> "none"
        is GetPublicKeyCredentialDomException -> domCode(e.domError) ?: "other"
        else -> "other"
    }
}
