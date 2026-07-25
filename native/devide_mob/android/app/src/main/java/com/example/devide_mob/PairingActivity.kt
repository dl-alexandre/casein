package com.example.devide_mob

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import org.json.JSONObject

/**
 * Credential-safe trampoline for devide://pair links.
 *
 * Android retains an activity's launch intent in task state. Pairing links
 * carry a short-lived bootstrap credential, so they must never launch the
 * durable MainActivity task directly. This no-history activity converts the
 * link to an in-process, single-consumption payload and returns to MainActivity
 * with a credential-free launcher intent.
 */
class PairingActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        PairingDeepLink.notification(intent?.data?.toString())?.let(PairingLaunchPayload::put)

        val safeIntent = Intent(this, MainActivity::class.java).apply {
            action = Intent.ACTION_MAIN
            addCategory(Intent.CATEGORY_LAUNCHER)
            addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP
            )
        }

        // Remove the credential-bearing activity from task history immediately.
        startActivity(safeIntent)
        intent?.replaceExtras(Bundle())
        intent?.data = null
        finishAndRemoveTask()
    }

}

internal object PairingLaunchPayload {
    private var pending: String? = null

    @Synchronized
    fun put(payload: String) {
        pending = payload
    }

    @Synchronized
    fun consume(): String? {
        val payload = pending
        pending = null
        return payload
    }
}

internal object PairingDeepLink {
    fun notification(rawUri: String?): String? {
        val uri = rawUri?.let { runCatching { java.net.URI(it) }.getOrNull() } ?: return null
        if (uri.scheme != "devide" || uri.host != "pair") return null

        val code = pathCode(uri) ?: queryCode(uri) ?: return null

        return JSONObject().apply {
            put("id", "pairing-deep-link")
            put("title", "Pair Casein")
            put("source", "deep_link")
            put("data", JSONObject().apply {
                put("action", "mobile.pair")
                put("pairing_code", code)
            })
        }.toString()
    }

    private fun pathCode(uri: java.net.URI): String? =
        uri.rawPath
            ?.removePrefix("/")
            ?.takeIf { it.isNotBlank() }
            ?.let(::decode)
            ?.takeIf { it.isNotBlank() }

    private fun queryCode(uri: java.net.URI): String? =
        uri.rawQuery
            ?.split("&")
            ?.asSequence()
            ?.map { it.split("=", limit = 2) }
            ?.firstOrNull { it.firstOrNull() == "code" }
            ?.getOrNull(1)
            ?.let(::decode)
            ?.takeIf { it.isNotBlank() }

    private fun decode(value: String): String =
        runCatching { java.net.URLDecoder.decode(value, Charsets.UTF_8.name()) }
            .getOrDefault(value)
}
