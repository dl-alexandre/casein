package com.example.casein_mob

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ColdStartProgressTest {
    @Test
    fun `root present is ready regardless of elapsed time`() {
        assertEquals(
            ColdStartPhase.Ready,
            ColdStartProgress.phase(rootPresent = true, elapsedMs = 0L),
        )
        assertEquals(
            ColdStartPhase.Ready,
            ColdStartProgress.phase(
                rootPresent = true,
                elapsedMs = ColdStartProgress.FAIL_CLOSED_MS + 1,
            ),
        )
    }

    @Test
    fun `before fail budget without root is starting not empty or error`() {
        assertEquals(
            ColdStartPhase.Starting,
            ColdStartProgress.phase(rootPresent = false, elapsedMs = 0L),
        )
        assertEquals(
            ColdStartPhase.Starting,
            ColdStartProgress.phase(rootPresent = false, elapsedMs = 9_620L),
        )
        assertEquals(
            ColdStartPhase.Starting,
            ColdStartProgress.phase(
                rootPresent = false,
                elapsedMs = ColdStartProgress.FAIL_CLOSED_MS - 1,
            ),
        )
    }

    @Test
    fun `past fail budget without root is failed fail-closed`() {
        assertEquals(
            ColdStartPhase.Failed,
            ColdStartProgress.phase(
                rootPresent = false,
                elapsedMs = ColdStartProgress.FAIL_CLOSED_MS,
            ),
        )
        assertEquals(
            ColdStartPhase.Failed,
            ColdStartProgress.phase(
                rootPresent = false,
                elapsedMs = ColdStartProgress.FAIL_CLOSED_MS + 5_000L,
            ),
        )
    }

    @Test
    fun `starting narration is delayed so fast boots do not flash`() {
        assertFalse(
            ColdStartProgress.showStartingNarration(
                phase = ColdStartPhase.Starting,
                elapsedMs = 0L,
            ),
        )
        assertFalse(
            ColdStartProgress.showStartingNarration(
                phase = ColdStartPhase.Starting,
                elapsedMs = ColdStartProgress.NARRATION_REVEAL_MS - 1,
            ),
        )
        assertTrue(
            ColdStartProgress.showStartingNarration(
                phase = ColdStartPhase.Starting,
                elapsedMs = ColdStartProgress.NARRATION_REVEAL_MS,
            ),
        )
    }

    @Test
    fun `narration never shows on ready or failed`() {
        assertFalse(
            ColdStartProgress.showStartingNarration(
                phase = ColdStartPhase.Ready,
                elapsedMs = 10_000L,
            ),
        )
        assertFalse(
            ColdStartProgress.showStartingNarration(
                phase = ColdStartPhase.Failed,
                elapsedMs = 10_000L,
            ),
        )
    }

    @Test
    fun `starting ready and failed are three distinct phases`() {
        val phases =
            setOf(
                ColdStartProgress.phase(false, 0L),
                ColdStartProgress.phase(true, 0L),
                ColdStartProgress.phase(false, ColdStartProgress.FAIL_CLOSED_MS),
            )
        assertEquals(
            setOf(ColdStartPhase.Starting, ColdStartPhase.Ready, ColdStartPhase.Failed),
            phases,
        )
    }
}
