package com.example.casein_mob

import android.os.SystemClock
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.Until
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * A production-data-preserving Casein soak.
 *
 * This test intentionally avoids Pair, Unpair, Resume, Open, review, and
 * intervention controls. It observes the existing canonical profile and
 * exercises only lifecycle, orientation, filtering, scrolling, and network
 * degradation/recovery. The target app is never cleared or uninstalled.
 */
@RunWith(AndroidJUnit4::class)
class CaseinUtilitySoakTest {
    private lateinit var device: UiDevice

    @Before
    fun setUp() {
        device = UiDevice.getInstance(InstrumentationRegistry.getInstrumentation())
        device.wakeUp()
    }

    @Test
    fun canonicalProfileSurvivesLifecycleRotationAndOfflineRecovery() {
        val wifiWasEnabled = shell("settings get global wifi_on").trim() == "1"

        try {
            val coldMs = coldLaunch()
            assertCanonicalDashboard()
            Log.i(TAG, "casein_soak cold_launch_ms=$coldMs")

            val warmMs = backgroundAndResume()
            assertCanonicalDashboard()
            Log.i(TAG, "casein_soak warm_resume_ms=$warmMs")

            exerciseLandscapeAndPortrait()
            exerciseSafeScrollAndBack()
            exerciseKeyboardWithoutSubmitting()
            exerciseAttentionFilters()

            if (wifiWasEnabled) {
                exerciseOfflineReadOnlyAndRecovery()
            } else {
                Log.i(TAG, "casein_soak offline_phase=skipped_wifi_initially_disabled")
            }
        } finally {
            device.unfreezeRotation()
            if (wifiWasEnabled) {
                shell("svc wifi enable")
            }
        }

        if (wifiWasEnabled) {
            assertTrue(
                "canonical origin did not recover its authenticated live feed",
                waitForText(AUTHENTICATED_FEED, RECOVERY_TIMEOUT_MS)
            )
        }
    }

    private fun coldLaunch(): Long {
        val startedAt = SystemClock.elapsedRealtime()
        val result = shell("am start -W -n $PACKAGE_NAME/.MainActivity")
        assertTrue("MainActivity cold launch failed: $result", result.contains("Status: ok"))
        assertTrue("dashboard did not render after cold launch", waitForText(DASHBOARD_TITLE))
        return SystemClock.elapsedRealtime() - startedAt
    }

    private fun backgroundAndResume(): Long {
        device.pressHome()
        device.waitForIdle()

        val startedAt = SystemClock.elapsedRealtime()
        val result = shell("am start -W -n $PACKAGE_NAME/.MainActivity")
        assertTrue("MainActivity warm launch failed: $result", result.contains("Status: ok"))
        assertTrue("dashboard did not render after warm resume", waitForText(DASHBOARD_TITLE))
        return SystemClock.elapsedRealtime() - startedAt
    }

    private fun assertCanonicalDashboard() {
        assertTrue("canonical origin URL is missing", waitForText(CANONICAL_ORIGIN))
        assertTrue("canonical Devbox origin is not selected", waitForText(SELECTED_DEVBOX))
        assertTrue("canonical origin is not authenticated", waitForText(AUTHENTICATED_FEED))
        assertTrue("Local Mac profile is missing", scrollUntilText(SWITCH_TO_LOCAL_MAC))
        scrollToTop()
        assertFalse(
            "legacy devide.devbox origin unexpectedly appeared",
            device.hasObject(By.textContains(LEGACY_ORIGIN_HOST))
        )
    }

    private fun exerciseLandscapeAndPortrait() {
        device.setOrientationLeft()
        assertTrue("dashboard disappeared in landscape", waitForText(DASHBOARD_TITLE))
        assertTrue("canonical profile disappeared in landscape", waitForText(SELECTED_DEVBOX))

        device.setOrientationNatural()
        assertTrue("dashboard disappeared after portrait restore", waitForText(DASHBOARD_TITLE))
        assertTrue("canonical profile disappeared after portrait restore", waitForText(SELECTED_DEVBOX))
    }

    private fun exerciseSafeScrollAndBack() {
        val width = device.displayWidth
        val height = device.displayHeight
        device.swipe(width / 2, height * 3 / 4, width / 2, height / 3, 18)
        device.swipe(width / 2, height / 3, width / 2, height * 3 / 4, 18)

        // Back from the root dashboard may background the activity. Relaunching
        // must restore the same profile without replaying a deep-link action.
        device.pressBack()
        device.waitForIdle()
        shell("am start -W -n $PACKAGE_NAME/.MainActivity")
        assertTrue("dashboard did not recover after root Back", waitForText(DASHBOARD_TITLE))
        assertTrue("profile changed after root Back", waitForText(SELECTED_DEVBOX))
    }

    private fun exerciseAttentionFilters() {
        assertTrue("Needs Me filter missing", tapText(NEEDS_ME))
        val settledNeedsMe =
            waitForText(NOTHING_NEEDS_YOU, FILTER_TIMEOUT_MS) ||
                waitForText(WHY_NOW_PREFIX, FILTER_TIMEOUT_MS, contains = true)
        assertTrue("Needs Me did not settle to an empty or reasoned attention state", settledNeedsMe)

        assertTrue("Live filter missing", tapText(LIVE))
        val liveSettled =
            waitForText(NO_LIVE_WORK, FILTER_TIMEOUT_MS) ||
                waitForText("· Live", FILTER_TIMEOUT_MS, contains = true)
        assertTrue("Live did not settle to an empty or live origin-qualified state", liveSettled)

        // The current product exposes Needs Me / Live / Failed / Done. Record
        // the requested legacy/generalized All surface as absent without
        // pretending it was exercised.
        assertFalse("unexpected All filter changed the reviewed navigation model", device.hasObject(By.text("All")))
    }

    private fun exerciseKeyboardWithoutSubmitting() {
        scrollToTop()
        assertTrue("Pair navigation control missing", tapText(PAIR))
        assertTrue("Pair workspace screen did not open", waitForText(PAIR_WORKSPACE))
        assertTrue(
            "manual pairing field was not reachable",
            scrollUntilText(PAIRING_CODE_PLACEHOLDER)
        )

        val field = device.findObject(By.text(PAIRING_CODE_PLACEHOLDER))
        assertTrue("manual pairing field was not found", field != null)
        field!!.click()
        device.waitForIdle()

        assertTrue(
            "software keyboard did not present for the pairing field",
            waitForKeyboard()
        )

        // No text is entered and Pair is never tapped. Back dismisses the IME,
        // then the explicit screen Back returns to the unchanged dashboard.
        device.pressBack()
        assertTrue("Pair workspace screen disappeared with IME Back", waitForText(PAIR_WORKSPACE))
        assertTrue("Pair screen Back control missing", tapText(BACK))
        assertTrue("dashboard did not return after keyboard exercise", waitForText(DASHBOARD_TITLE))
        assertCanonicalDashboard()
    }

    private fun waitForKeyboard(timeoutMs: Long = 5_000L): Boolean {
        val deadline = SystemClock.elapsedRealtime() + timeoutMs
        while (SystemClock.elapsedRealtime() < deadline) {
            val state = shell("dumpsys input_method")
            if (state.contains("mInputShown=true") || state.contains("mIsInputViewShown=true")) {
                return true
            }
            SystemClock.sleep(250)
        }
        return false
    }

    private fun exerciseOfflineReadOnlyAndRecovery() {
        shell("svc wifi disable")
        assertTrue(
            "saved profile did not report offline",
            waitForText(SAVED_PROFILE_OFFLINE, OFFLINE_TIMEOUT_MS)
        )
        assertTrue(
            "card stream did not expose stale/offline state",
            waitForText(CARD_STREAM_OFFLINE, OFFLINE_TIMEOUT_MS)
        )
        assertTrue(
            "offline explanation did not identify stale cards",
            waitForText(STALE_CARD_COPY, OFFLINE_TIMEOUT_MS, contains = true)
        )

        assertTrue(
            "no visible card degraded to an origin-qualified read-only state",
            scrollUntilText(READ_ONLY_CONTEXT, contains = true)
        )

        // Cached/offline controls are deliberately not tapped. Recovery must
        // happen through reconnect and an authoritative refresh.
        val reconnectStartedAt = SystemClock.elapsedRealtime()
        shell("svc wifi enable")
        scrollToTop()
        assertTrue(
            "authenticated live feed did not recover after Wi-Fi reconnect",
            waitForText(AUTHENTICATED_FEED, RECOVERY_TIMEOUT_MS)
        )
        assertFalse(
            "offline banner remained after authoritative recovery",
            device.hasObject(By.text(CARD_STREAM_OFFLINE))
        )
        Log.i(
            TAG,
            "casein_soak offline_recovery_ms=${SystemClock.elapsedRealtime() - reconnectStartedAt}"
        )
    }

    private fun scrollUntilText(
        text: String,
        contains: Boolean = false,
        attempts: Int = 8
    ): Boolean {
        repeat(attempts) {
            if (hasText(text, contains)) return true
            val width = device.displayWidth
            val height = device.displayHeight
            device.swipe(width / 2, height * 4 / 5, width / 2, height / 4, 20)
        }
        return hasText(text, contains)
    }

    private fun scrollToTop(attempts: Int = 10) {
        repeat(attempts) {
            if (hasText(CANONICAL_ORIGIN)) return
            val width = device.displayWidth
            val height = device.displayHeight
            device.swipe(width / 2, height / 4, width / 2, height * 4 / 5, 20)
        }
    }

    private fun tapText(text: String): Boolean {
        if (!waitForText(text)) return false
        val node = device.findObject(By.text(text)) ?: return false
        node.click()
        device.waitForIdle()
        return true
    }

    private fun waitForText(
        text: String,
        timeoutMs: Long = UI_TIMEOUT_MS,
        contains: Boolean = false
    ): Boolean {
        val selector = if (contains) By.textContains(text) else By.text(text)
        return device.wait(Until.hasObject(selector), timeoutMs)
    }

    private fun hasText(text: String, contains: Boolean = false): Boolean {
        val selector = if (contains) By.textContains(text) else By.text(text)
        return device.hasObject(selector)
    }

    private fun shell(command: String): String = device.executeShellCommand(command)

    companion object {
        private const val TAG = "CaseinUtilitySoak"
        private const val PACKAGE_NAME = "com.example.casein_mob"
        private const val DASHBOARD_TITLE = "Attention Inbox"
        private const val CANONICAL_ORIGIN = "https://casein.devbox.milcgroup.com"
        private const val LEGACY_ORIGIN_HOST = "devide.devbox.milcgroup.com"
        private const val SELECTED_DEVBOX = "Selected · Devbox"
        private const val SWITCH_TO_LOCAL_MAC = "Switch to · Local Mac"
        private const val AUTHENTICATED_FEED = "Authenticated live feed"
        private const val NEEDS_ME = "Needs Me"
        private const val LIVE = "Live"
        private const val PAIR = "+ Pair"
        private const val PAIR_WORKSPACE = "Pair workspace"
        private const val PAIRING_CODE_PLACEHOLDER = "Enter pairing code"
        private const val BACK = "Back"
        private const val NOTHING_NEEDS_YOU = "Nothing needs you"
        private const val WHY_NOW_PREFIX = "Why now:"
        private const val NO_LIVE_WORK = "No live work observed"
        private const val SAVED_PROFILE_OFFLINE = "Saved profile · live feed offline"
        private const val CARD_STREAM_OFFLINE = "Card stream offline"
        private const val STALE_CARD_COPY = "Latest mobile cards may be stale"
        private const val READ_ONLY_CONTEXT = "Last known · Offline · Read-only"
        private const val UI_TIMEOUT_MS = 20_000L
        private const val FILTER_TIMEOUT_MS = 12_000L
        private const val OFFLINE_TIMEOUT_MS = 30_000L
        private const val RECOVERY_TIMEOUT_MS = 45_000L
    }
}
