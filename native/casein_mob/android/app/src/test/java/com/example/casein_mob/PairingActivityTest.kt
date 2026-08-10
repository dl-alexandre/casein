package com.example.casein_mob

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test

class PairingActivityTest {
    private fun compactVector(): JSONObject {
        val fixture = checkNotNull(javaClass.classLoader?.getResource("compact_pairing_vectors.json"))
        return JSONArray(fixture.readText()).getJSONObject(0)
    }

    @Test
    fun `canonical compact vector preserves the exact payload bytes`() {
        val vector = compactVector()
        val notification = JSONObject(PairingDeepLink.notification(vector.getString("uri"))!!)
        val code = notification.getJSONObject("data").getString("pairing_code")

        assertEquals(
            vector.getString("uri").removePrefix("casein://pair/"),
            code
        )

        val rejected = vector.getJSONArray("reject_uris")
        for (index in 0 until rejected.length()) {
            assertNull(PairingDeepLink.notification(rejected.getString(index)))
        }

        assertNull(PairingDeepLink.notification("casein://pair/" + "A".repeat(4097)))
    }

    @Test
    fun `pair path becomes a bounded payload without the credential uri`() {
        val raw = "casein://pair/opaque-bootstrap-code"
        val notification = JSONObject(PairingDeepLink.notification(raw)!!)
        val data = notification.getJSONObject("data")

        assertEquals("mobile.pair", data.getString("action"))
        assertEquals("opaque-bootstrap-code", data.getString("pairing_code"))
        assertFalse(data.has("deep_link"))
        assertFalse(notification.toString().contains(raw))
    }

    @Test
    fun `pair query code is accepted and decoded`() {
        val notification =
            JSONObject(PairingDeepLink.notification("casein://pair?code=opaque%2Dquery")!!)

        assertEquals(
            "opaque-query",
            notification.getJSONObject("data").getString("pairing_code")
        )
    }

    @Test
    fun `wrong host and blank codes are rejected`() {
        assertNull(PairingDeepLink.notification("casein://review/opaque"))
        assertNull(PairingDeepLink.notification("https://pair/opaque"))
        assertNull(PairingDeepLink.notification("casein://pair/"))
        assertNull(PairingDeepLink.notification("casein://pair?code="))
    }


    @Test
    fun `path form still wins when query component is empty string`() {
        val vector = compactVector()
        val uri = vector.getString("uri") + "?"
        // Reject trailing bare ? (structurally ambiguous), but never treat a missing
        // query as a present empty query that cancels a valid path payload.
        assertNull(PairingDeepLink.notification(uri))

        val notification = JSONObject(PairingDeepLink.notification(vector.getString("uri"))!!)
        assertEquals(
            vector.getString("uri").removePrefix("casein://pair/"),
            notification.getJSONObject("data").getString("pairing_code")
        )
    }

    @Test
    fun `pending payload can only be consumed once`() {
        PairingLaunchPayload.put("one-shot")

        assertEquals("one-shot", PairingLaunchPayload.consume())
        assertNull(PairingLaunchPayload.consume())
    }

}
