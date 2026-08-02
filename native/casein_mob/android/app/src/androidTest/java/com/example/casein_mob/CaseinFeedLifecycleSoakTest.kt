package com.example.casein_mob

import android.content.ComponentName
import android.content.Intent
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.BySelector
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.UiObject2
import androidx.test.uiautomator.Until
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.util.regex.Pattern

/**
 * Data-preserving reconnect driver for the structured mobile-feed cohort.
 *
 * The test activates only Casein's exact launcher activity and repeatedly taps
 * the already-selected canonical origin. It never pairs, submits a work action,
 * changes device connectivity, clears application data, or captures UI content.
 */
@RunWith(AndroidJUnit4::class)
class CaseinFeedLifecycleSoakTest {
    private lateinit var device: UiDevice

    @Before
    fun setUp() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        device = UiDevice.getInstance(instrumentation)
        device.wakeUp()

        assertEquals(PACKAGE_NAME, instrumentation.targetContext.packageName)

        val launchIntent =
            Intent(Intent.ACTION_MAIN).apply {
                component = ComponentName(PACKAGE_NAME, MAIN_ACTIVITY)
                addCategory(Intent.CATEGORY_LAUNCHER)
                flags =
                    Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_CLEAR_TOP or
                        Intent.FLAG_ACTIVITY_SINGLE_TOP
            }

        instrumentation.targetContext.startActivity(launchIntent)
        instrumentation.waitForIdleSync()
    }

    @Test
    fun twentyExplicitCurrentOriginReconnects() {
        assertTrue("Action Center missing", waitForText(DASHBOARD_TITLE))
        assertCanonicalAuthenticatedDashboard()

        repeat(RECONNECT_CYCLES) {
            val selectedOrigin =
                findVisibleText(SELECTED_DEVBOX)
                    ?: throw AssertionError("canonical Devbox selector missing")

            assertTrue("canonical Devbox selector is disabled", selectedOrigin.isEnabled)
            assertTrue("canonical Devbox selector is not tappable", selectedOrigin.isClickable)

            selectedOrigin.click()

            assertTrue(
                "current-origin activation missed its connecting transition",
                device.wait(Until.hasObject(CONNECTING_STATUS), TRANSITION_TIMEOUT_MS),
            )
            assertTrue(
                "authenticated feed did not return after current-origin activation",
                waitForText(AUTHENTICATED_FEED, RECOVERY_TIMEOUT_MS),
            )
            assertTrue("canonical origin changed during reconnect", waitForText(CANONICAL_ORIGIN))
            assertTrue("canonical Devbox selection changed during reconnect", hasText(SELECTED_DEVBOX))
        }

        Log.i(TAG, PASS_METADATA)
    }

    private fun assertCanonicalAuthenticatedDashboard() {
        assertTrue("canonical origin URL is missing", waitForText(CANONICAL_ORIGIN))
        assertTrue("canonical Devbox origin is not selected", findVisibleText(SELECTED_DEVBOX) != null)
        assertTrue("canonical origin is not authenticated", waitForText(AUTHENTICATED_FEED))
    }

    private fun findVisibleText(text: String): UiObject2? {
        repeat(MAX_SCROLL_ATTEMPTS) {
            device.findObject(By.text(text))?.let { return it }

            val width = device.displayWidth
            val height = device.displayHeight
            device.swipe(width / 2, height / 4, width / 2, height * 4 / 5, SCROLL_STEPS)
            device.waitForIdle()
        }

        return device.findObject(By.text(text))
    }

    private fun waitForText(
        text: String,
        timeoutMs: Long = UI_TIMEOUT_MS,
    ): Boolean = device.wait(Until.hasObject(By.text(text)), timeoutMs)

    private fun hasText(text: String): Boolean = device.hasObject(By.text(text))

    private companion object {
        const val PACKAGE_NAME = "com.example.casein_mob"
        const val MAIN_ACTIVITY = "com.example.casein_mob.MainActivity"
        const val TAG = "CaseinFeedLifecycleSoak"
        const val PASS_METADATA =
            "casein_feed_lifecycle_soak result=pass reconnect_cycles=20"
        const val DASHBOARD_TITLE = "Attention Inbox"
        const val CANONICAL_ORIGIN = "https://casein.devbox.milcgroup.com"
        const val SELECTED_DEVBOX = "Selected · Devbox"
        const val AUTHENTICATED_FEED = "Authenticated live feed"
        const val RECONNECT_CYCLES = 20
        const val UI_TIMEOUT_MS = 20_000L
        const val TRANSITION_TIMEOUT_MS = 12_000L
        const val RECOVERY_TIMEOUT_MS = 45_000L
        const val MAX_SCROLL_ATTEMPTS = 10
        const val SCROLL_STEPS = 20

        val CONNECTING_STATUS: BySelector =
            By.text(
                Pattern.compile(
                    "^(Saved profile · validating live access|Card stream connecting)$",
                ),
            )
    }
}
