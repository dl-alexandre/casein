package com.example.casein_mob

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TerminalPrivacySurfaceControllerTest {
    private class Host : TerminalPrivacySurfaceController.Host {
        var secureEnabled = false
        var coversShown = 0
        var coversHidden = 0

        override fun setSecure(enabled: Boolean) {
            secureEnabled = enabled
        }

        override fun showOpaqueCover() {
            coversShown += 1
        }

        override fun hideOpaqueCover() {
            coversHidden += 1
        }
    }

    @Test
    fun `secure flag is ref counted across terminal surface mounts`() {
        val host = Host()
        val controller = TerminalPrivacySurfaceController(host)

        controller.onResume()
        controller.mount()
        controller.mount()
        assertTrue(host.secureEnabled)
        assertEquals(2, controller.mountedCountForTest())

        controller.unmount()
        assertTrue(host.secureEnabled)
        controller.unmount()
        assertFalse(host.secureEnabled)
        assertFalse(controller.coveredForTest())
    }

    @Test
    fun `foreground remains covered until a fresh monotonic baseline`() {
        val host = Host()
        val controller = TerminalPrivacySurfaceController(host)

        controller.onResume()
        controller.mount()
        assertTrue(controller.coveredForTest())
        assertTrue(controller.freshBaseline(7))
        assertFalse(controller.coveredForTest())

        controller.onPauseOrStop()
        assertTrue(controller.coveredForTest())
        assertFalse(controller.freshBaseline(8))
        controller.onResume()
        assertTrue(controller.coveredForTest())
        assertFalse(controller.freshBaseline(7))
        assertTrue(controller.freshBaseline(8))
        assertFalse(controller.coveredForTest())
    }

    @Test
    fun `invalid duplicate and out of order generations fail closed`() {
        val host = Host()
        val controller = TerminalPrivacySurfaceController(host)
        controller.onResume()
        controller.mount()

        assertFalse(controller.freshBaseline(-1))
        assertTrue(controller.freshBaseline(1))
        controller.onPauseOrStop()
        controller.onResume()
        assertFalse(controller.freshBaseline(1))
        assertFalse(controller.freshBaseline(0))
        assertTrue(controller.coveredForTest())
    }

    @Test
    fun `resize and recreation do not require or retain terminal payloads`() {
        val firstHost = Host()
        val first = TerminalPrivacySurfaceController(firstHost)
        first.onResume()
        first.mount()
        assertTrue(first.freshBaseline(Long.MAX_VALUE))
        first.onPauseOrStop()

        val recreatedHost = Host()
        val recreated = TerminalPrivacySurfaceController(recreatedHost)
        recreated.onResume()
        recreated.mount()

        // A recreated controller has no persisted terminal bytes or generation.
        assertTrue(recreated.coveredForTest())
        assertTrue(recreated.freshBaseline(0))
    }

    @Test
    fun `activity recreation cannot replay an already forwarded generation`() {
        val fence = TerminalBaselineSignalFence()

        assertTrue(fence.eligible(41))
        assertTrue(fence.commit(41))
        assertFalse(fence.eligible(41))
        assertFalse(fence.commit(41))
        assertFalse(fence.eligible(40))
        assertTrue(fence.eligible(42))
        assertTrue(fence.commit(42))

        val recreatedHost = Host()
        val recreated = TerminalPrivacySurfaceController(recreatedHost)
        recreated.onResume()
        recreated.mount()
        if (fence.eligible(42)) recreated.freshBaseline(42)
        assertTrue(recreated.coveredForTest())
    }

    @Test
    fun `pre resume baseline rejection does not consume the process generation`() {
        val host = Host()
        val controller = TerminalPrivacySurfaceController(host)
        val fence = TerminalBaselineSignalFence()
        controller.mount()

        assertTrue(fence.eligible(9))
        assertFalse(controller.freshBaseline(9))
        assertTrue(fence.eligible(9))

        controller.onResume()
        assertTrue(controller.freshBaseline(9))
        assertTrue(fence.commit(9))
        assertFalse(fence.eligible(9))
    }

    @Test
    fun `baseline property accepts only non negative integer wire values`() {
        assertEquals(0L, terminalBaselineGeneration(0))
        assertEquals(7L, terminalBaselineGeneration(7L))
        assertEquals(null, terminalBaselineGeneration(-1))
        assertEquals(null, terminalBaselineGeneration(1.5))
        assertEquals(null, terminalBaselineGeneration("7"))
        assertEquals(null, terminalBaselineGeneration(null))
    }

    @Test
    fun `first paint advances once only for the active accepted baseline`() {
        val controller = TerminalPrivacySurfaceController(Host())
        controller.onResume()
        controller.mount()

        assertTrue(controller.freshBaseline(7))
        assertTrue(controller.firstPaint(7))
        assertFalse(controller.firstPaint(7))

        assertEquals(listOf(7L, 7L, 7L, 1L, 1L, 0L), controller.fixedDiagnostic().toList())
    }

    @Test
    fun `stale baseline and stale draw cannot advance first paint`() {
        val controller = TerminalPrivacySurfaceController(Host())
        controller.onResume()
        controller.mount()

        assertTrue(controller.freshBaseline(8))
        assertFalse(controller.firstPaint(7))
        assertFalse(controller.freshBaseline(7))
        assertFalse(controller.firstPaint(7))
        assertEquals(-1L, controller.fixedDiagnostic()[2])
        assertEquals(0L, controller.fixedDiagnostic()[3])
    }

    @Test
    fun `unrelated UI invalidation has no terminal first paint callback`() {
        val controller = TerminalPrivacySurfaceController(Host())
        controller.onResume()
        controller.mount()
        assertTrue(controller.freshBaseline(3))

        val beforeUnrelatedDraw = controller.fixedDiagnostic().toList()
        assertFalse(reportTerminalFirstPaint(null) { controller.firstPaint(it) })
        val afterUnrelatedDraw = controller.fixedDiagnostic().toList()

        assertEquals(beforeUnrelatedDraw, afterUnrelatedDraw)
        assertEquals(0L, controller.fixedDiagnostic()[3])
    }

    @Test
    fun `background cover and close clear active paint eligibility`() {
        val controller = TerminalPrivacySurfaceController(Host())
        controller.onResume()
        controller.mount()
        assertTrue(controller.freshBaseline(4))

        controller.onPauseOrStop()
        assertFalse(controller.firstPaint(4))
        assertEquals(-1L, controller.fixedDiagnostic()[1])
        assertEquals(1L, controller.fixedDiagnostic()[5])

        controller.onResume()
        assertTrue(controller.freshBaseline(5))
        assertTrue(controller.firstPaint(5))
        controller.unmount()
        assertFalse(controller.firstPaint(5))
        assertEquals(-1L, controller.fixedDiagnostic()[1])
        assertEquals(0L, controller.fixedDiagnostic()[4])
        assertEquals(1L, controller.fixedDiagnostic()[3])
    }
}
