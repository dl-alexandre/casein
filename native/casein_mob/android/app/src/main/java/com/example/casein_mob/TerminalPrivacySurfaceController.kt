package com.example.casein_mob

import android.app.Activity
import android.graphics.Color
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.FrameLayout

/**
 * Privacy boundary for the product terminal surface.
 *
 * Terminal output never enters this object. The only transport-facing signal is
 * an opaque, monotonically increasing baseline generation. A foregrounded
 * terminal stays covered until a generation newer than the last accepted one
 * is explicitly supplied.
 */
internal class TerminalPrivacySurfaceController(
    private val host: Host,
) {
    internal interface Host {
        fun setSecure(enabled: Boolean)
        fun showOpaqueCover()
        fun hideOpaqueCover()
    }

    private var mounts = 0
    private var foreground = false
    private var covered = false
    private var highestBaselineGeneration = -1L

    fun mount() {
        mounts += 1
        if (mounts == 1) {
            host.setSecure(true)
            cover()
        }
    }

    fun unmount() {
        if (mounts == 0) return
        mounts -= 1
        if (mounts == 0) {
            uncover()
            host.setSecure(false)
        }
    }

    fun onResume() {
        foreground = true
        if (mounts > 0) cover()
    }

    fun onPauseOrStop() {
        if (mounts > 0) cover()
        foreground = false
    }

    fun freshBaseline(generation: Long): Boolean {
        if (generation < 0 || generation <= highestBaselineGeneration) return false
        if (!foreground || mounts == 0) return false

        highestBaselineGeneration = generation
        uncover()
        return true
    }

    internal fun mountedCountForTest(): Int = mounts
    internal fun coveredForTest(): Boolean = covered

    private fun cover() {
        if (covered) return
        covered = true
        host.showOpaqueCover()
    }

    private fun uncover() {
        if (!covered) return
        covered = false
        host.hideOpaqueCover()
    }
}

internal class TerminalBaselineSignalFence {
    private var highestClaimed = -1L

    @Synchronized
    fun claim(generation: Long): Boolean {
        if (generation < 0 || generation <= highestClaimed) return false
        highestClaimed = generation
        return true
    }
}

internal fun terminalBaselineGeneration(value: Any?): Long? =
    when (value) {
        is Byte -> value.toLong()
        is Short -> value.toLong()
        is Int -> value.toLong()
        is Long -> value
        else -> null
    }?.takeIf { it >= 0 }

/** Android window implementation. All calls are made on the activity main thread. */
internal class TerminalPrivacyWindowHost(private val activity: Activity) :
    TerminalPrivacySurfaceController.Host {
    private var cover: View? = null

    override fun setSecure(enabled: Boolean) {
        if (enabled) {
            activity.window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        } else {
            activity.window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
        }
    }

    override fun showOpaqueCover() {
        if (cover != null) return

        val opaque = View(activity).apply {
            setBackgroundColor(Color.rgb(8, 10, 12))
            contentDescription = null
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
            isClickable = true
            isFocusable = true
            isSaveEnabled = false
            elevation = Float.MAX_VALUE
        }
        val params = FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.MATCH_PARENT,
            Gravity.FILL,
        )
        (activity.window.decorView as ViewGroup).addView(opaque, params)
        cover = opaque
    }

    override fun hideOpaqueCover() {
        cover?.let { (it.parent as? ViewGroup)?.removeView(it) }
        cover = null
    }
}

/**
 * Bounded platform callback used by the shared terminal integration.
 *
 * It intentionally accepts only lifecycle metadata. Terminal bytes, labels,
 * commands, and tokens have no API path into Android lifecycle state.
 */
object AndroidTerminalPrivacy {
    @Volatile
    private var activity: MainActivity? = null
    private val baselineSignals = TerminalBaselineSignalFence()

    internal fun bind(activity: MainActivity) {
        this.activity = activity
    }

    internal fun unbind(activity: MainActivity) {
        if (this.activity === activity) this.activity = null
    }

    @JvmStatic
    fun surfaceMounted() {
        val target = activity ?: return
        target.runOnUiThread { target.terminalPrivacySurfaceMounted() }
    }

    @JvmStatic
    fun surfaceUnmounted() {
        val target = activity ?: return
        target.runOnUiThread { target.terminalPrivacySurfaceUnmounted() }
    }

    @JvmStatic
    fun freshBaseline(generation: Long) {
        val target = activity ?: return
        // A configuration change may recompose an old declarative tree. Do not
        // let that replayed prop uncover the new activity; only a newly claimed
        // process-local generation may cross the platform boundary.
        if (!baselineSignals.claim(generation)) return
        target.runOnUiThread { target.terminalPrivacyFreshBaseline(generation) }
    }
}
