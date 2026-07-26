package com.example.casein_mob

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class NotificationDeliveryCoordinatorTest {
    @Test
    fun `registered notify screen takes precedence over permission requester`() {
        assertEquals(41L, notificationDeliveryPid(41L, 42L, "notifications"))
    }

    @Test
    fun `notification permission requester is a bounded live screen fallback`() {
        assertEquals(42L, notificationDeliveryPid(0L, 42L, "notifications"))
        assertEquals(0L, notificationDeliveryPid(0L, 42L, "camera"))
        assertEquals(0L, notificationDeliveryPid(0L, 0L, "notifications"))
    }

    @Test
    fun `delivers immediately to an already registered screen`() {
        val harness = Harness(pid = 41L)

        harness.coordinator.accept("review")

        assertEquals(listOf<String?>("review", null), harness.stored)
        assertEquals(listOf(41L to "review"), harness.delivered)
        assertEquals(1, harness.registrationRequests)
        assertEquals(0, harness.scheduled.size)
    }

    @Test
    fun `retries until permission wake registers the screen`() {
        val harness = Harness()

        harness.coordinator.accept("review")
        assertEquals("review", harness.stored.last())
        assertEquals(1, harness.scheduled.size)

        harness.pid = 42L
        harness.runNext()

        assertNull(harness.stored.last())
        assertEquals(listOf(42L to "review"), harness.delivered)
    }

    @Test
    fun `newer payload supersedes an older deferred payload`() {
        val harness = Harness()

        harness.coordinator.accept("old")
        harness.coordinator.accept("new")
        harness.pid = 43L
        harness.runAll()

        assertEquals(listOf(43L to "new"), harness.delivered)
    }

    @Test
    fun `bounded retry leaves launch fallback for a future cold start`() {
        val harness = Harness(maxAttempts = 1)

        harness.coordinator.accept("review")
        harness.runAll()

        assertEquals("review", harness.stored.last())
        assertEquals(emptyList<Pair<Long, String>>(), harness.delivered)
    }

    private class Harness(
        var pid: Long = 0L,
        maxAttempts: Int = 50,
    ) {
        val stored = mutableListOf<String?>()
        val delivered = mutableListOf<Pair<Long, String>>()
        val scheduled = ArrayDeque<() -> Unit>()
        var registrationRequests = 0

        val coordinator =
            NotificationDeliveryCoordinator(
                currentPid = { pid },
                storeLaunchPayload = { stored.add(it) },
                requestRegistration = { registrationRequests += 1 },
                deliver = { target, json -> delivered.add(target to json) },
                schedule = { _, task -> scheduled.addLast(task) },
                maxAttempts = maxAttempts,
            )

        fun runNext() {
            scheduled.removeFirst().invoke()
        }

        fun runAll() {
            while (scheduled.isNotEmpty()) runNext()
        }
    }
}
