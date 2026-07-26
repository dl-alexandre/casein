package com.example.casein_mob

/**
 * Bridges a notification/deep-link payload into the already-running BEAM.
 *
 * The notify plugin may not have registered its delivery PID yet (for example
 * while Android's notification-permission result is still crossing the native
 * bridge). Keep the launch-slot fallback populated, prompt registration, and
 * retry for a short bounded window. The payload still enters the normal Elixir
 * notification router, where stored-origin resolution and authoritative
 * refresh enforce trust.
 */
internal class NotificationDeliveryCoordinator(
    private val currentPid: () -> Long,
    private val storeLaunchPayload: (String?) -> Unit,
    private val requestRegistration: () -> Unit,
    private val deliver: (Long, String) -> Unit,
    private val schedule: (Long, () -> Unit) -> Unit,
    private val retryDelayMs: Long = 100L,
    private val maxAttempts: Int = 50,
) {
    private var generation = 0

    fun accept(json: String) {
        generation += 1
        val acceptedGeneration = generation

        storeLaunchPayload(json)
        requestRegistration()
        attempt(json, acceptedGeneration, 0)
    }

    private fun attempt(json: String, acceptedGeneration: Int, attempt: Int) {
        if (acceptedGeneration != generation) return

        val pid = currentPid()
        if (pid != 0L) {
            storeLaunchPayload(null)
            deliver(pid, json)
            return
        }

        if (attempt < maxAttempts) {
            schedule(retryDelayMs) {
                attempt(json, acceptedGeneration, attempt + 1)
            }
        }
    }
}

internal fun notificationDeliveryPid(
    registeredPid: Long,
    pendingPermissionPid: Long,
    pendingPermissionCapability: String,
): Long =
    when {
        registeredPid != 0L -> registeredPid
        pendingPermissionCapability == "notifications" -> pendingPermissionPid
        else -> 0L
    }
