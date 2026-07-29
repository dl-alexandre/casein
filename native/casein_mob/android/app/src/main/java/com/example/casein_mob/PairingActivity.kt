package com.example.casein_mob

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import org.json.JSONObject

/**
 * Credential-safe trampoline for casein://pair links.
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
    private const val MAX_PAIRING_CODE_BYTES = 4096

    fun notification(rawUri: String?): String? {
        val uri = rawUri?.let { runCatching { java.net.URI(it) }.getOrNull() } ?: return null
        if (uri.scheme != "casein" || uri.host != "pair") return null
        if (uri.fragment != null || uri.userInfo != null || uri.port != -1) return null

        val path = pathCode(uri)
        val query = queryCode(uri)
        if ((path == null) == (query == null)) return null
        val code = path ?: query ?: return null
        if (code.toByteArray(Charsets.UTF_8).size > MAX_PAIRING_CODE_BYTES) return null

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
            ?.takeIf { uri.rawQuery == null && it.startsWith("/") && it.length > 1 }
            ?.removePrefix("/")
            ?.takeIf { !it.contains("/") }
            ?.takeIf { it.isNotBlank() }
            ?.let(::decode)
            ?.takeIf { !it.contains("/") }
            ?.takeIf { it.isNotBlank() }

    private fun queryCode(uri: java.net.URI): String? {
        if (!uri.rawPath.isNullOrEmpty()) return null
        val pair = uri.rawQuery?.split("&")?.singleOrNull()?.split("=", limit = 2) ?: return null
        if (pair.size != 2 || pair[0] !in setOf("code", "pairing_code")) return null
        return decode(pair[1]).takeIf { it.isNotBlank() }
    }

    private fun decode(value: String): String =
        runCatching { java.net.URLDecoder.decode(value, Charsets.UTF_8.name()) }
            .getOrDefault(value)
}
