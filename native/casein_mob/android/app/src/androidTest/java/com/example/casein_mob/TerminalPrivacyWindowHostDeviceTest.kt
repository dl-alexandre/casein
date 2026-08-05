package com.example.casein_mob

import android.app.Activity
import android.os.Bundle
import android.view.ViewGroup
import android.view.WindowManager
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

class TerminalPrivacyTestActivity : Activity() {
    internal lateinit var privacy: TerminalPrivacySurfaceController

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        privacy = TerminalPrivacySurfaceController(TerminalPrivacyWindowHost(this))
    }
}

@RunWith(AndroidJUnit4::class)
class TerminalPrivacyWindowHostDeviceTest {
    @Test
    fun secureFlagAndOpaqueCoverSurviveResizeWithoutPersistingContent() {
        ActivityScenario.launch(TerminalPrivacyTestActivity::class.java).use { scenario ->
            scenario.onActivity { activity ->
                activity.privacy.onResume()
                activity.privacy.mount()

                assertTrue(
                    activity.window.attributes.flags and WindowManager.LayoutParams.FLAG_SECURE != 0,
                )
                assertEquals(1, opaqueCoverCount(activity))
                assertTrue(activity.privacy.freshBaseline(1))
                assertEquals(0, opaqueCoverCount(activity))

                // Multi-window/rotation resize does not mutate privacy state.
                activity.window.setLayout(640, 480)
                assertFalse(activity.privacy.coveredForTest())

                activity.privacy.onPauseOrStop()
                assertEquals(1, opaqueCoverCount(activity))
                val cover = (activity.window.decorView as ViewGroup).getChildAt(
                    (activity.window.decorView as ViewGroup).childCount - 1,
                )
                assertEquals(null, cover.contentDescription)
                assertFalse(cover.isSaveEnabled)
            }
        }
    }

    private fun opaqueCoverCount(activity: Activity): Int {
        val decor = activity.window.decorView as ViewGroup
        return (0 until decor.childCount).count { index ->
            val child = decor.getChildAt(index)
            child.isClickable && !child.isSaveEnabled && child.contentDescription == null
        }
    }
}
