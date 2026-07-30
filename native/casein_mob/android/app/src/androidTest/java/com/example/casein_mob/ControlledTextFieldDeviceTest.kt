package com.example.casein_mob

import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.Until
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Data-preserving physical regression for controlled text reconciliation.
 *
 * It uses the manual pairing field as a safe fixture, replaces its value
 * atomically through accessibility, and leaves without tapping Pair.
 */
@RunWith(AndroidJUnit4::class)
class ControlledTextFieldDeviceTest {
    private lateinit var device: UiDevice

    @Before
    fun setUp() {
        device = UiDevice.getInstance(InstrumentationRegistry.getInstrumentation())
        device.wakeUp()
    }

    @Test
    fun atomicAccessibilityInputRemainsExactWithoutSubmitting() {
        val launch =
            device.executeShellCommand(
                "am start -W -n com.example.casein_mob/.MainActivity"
            )
        assertTrue("MainActivity launch failed: $launch", launch.contains("Status: ok"))
        assertTrue("Action Center missing", waitForText("Attention Inbox"))

        val pair = device.wait(Until.findObject(By.text("+ Pair")), UI_TIMEOUT_MS)
        assertTrue("Pair navigation missing", pair != null)
        pair!!.click()
        assertTrue("Pair workspace missing", waitForText("Pair workspace"))

        val field =
            device.wait(
                Until.findObject(By.clazz("android.widget.EditText")),
                UI_TIMEOUT_MS,
            )
        assertTrue("manual pairing field missing", field != null)
        field!!.click()

        setTextAndAssert("Yes")
        setTextAndAssert("Yes, continue.")
        Log.i(TAG, "casein_controlled_text atomic_accessibility=exact")

        // First Back dismisses the keyboard; the explicit Back control leaves
        // the fixture. Pair is deliberately never tapped.
        device.pressBack()
        assertTrue("Pair workspace disappeared with keyboard", waitForText("Pair workspace"))
        val back = device.wait(Until.findObject(By.text("Back")), UI_TIMEOUT_MS)
        assertTrue("Pair workspace Back missing", back != null)
        back!!.click()
        assertTrue("Action Center did not return", waitForText("Attention Inbox"))
    }

    private fun setTextAndAssert(expected: String) {
        val field =
            device.wait(
                Until.findObject(By.clazz("android.widget.EditText")),
                UI_TIMEOUT_MS,
            )
        assertTrue("manual pairing field disappeared", field != null)
        field!!.text = expected

        val exactField =
            device.wait(
                Until.findObject(
                    By.clazz("android.widget.EditText").text(expected)
                ),
                UI_TIMEOUT_MS,
            )
        assertTrue("controlled field did not settle to: $expected", exactField != null)
        assertEquals(expected, exactField!!.text)
    }

    private fun waitForText(text: String): Boolean =
        device.wait(Until.hasObject(By.text(text)), UI_TIMEOUT_MS)

    private companion object {
        const val TAG = "CaseinControlledText"
        const val UI_TIMEOUT_MS = 10_000L
    }
}
