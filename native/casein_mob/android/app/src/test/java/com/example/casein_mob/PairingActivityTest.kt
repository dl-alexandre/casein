package com.example.casein_mob

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test

class PairingActivityTest {
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
    fun `pending payload can only be consumed once`() {
        PairingLaunchPayload.put("one-shot")

        assertEquals("one-shot", PairingLaunchPayload.consume())
        assertNull(PairingLaunchPayload.consume())
    }

}
