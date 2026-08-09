package com.example.casein_mob

/**
 * Native cold-start phase before the BEAM root captures the canvas (#410).
 *
 * Distinct from empty Action Center content and from a settled runtime error
 * (#731): this is only "the OTP root has not arrived yet".
 *
 * Progress narration follows #732 — delayed, not immediate — so a fast boot
 * never flashes a "starting" label. The branded surface itself is static
 * (no spin/pulse): reduced-motion is the product default (#778); a cold-start
 * indicator is a legitimate slow-path exception only as static affordance on
 * the cockpit motion scale (#776), not a bespoke animation.
 */
enum class ColdStartPhase {
    /** BEAM root has not painted yet. */
    Starting,

    /** BEAM root is present; native cold-start chrome must yield. */
    Ready,

    /** Root never arrived within the fail-closed budget. */
    Failed,
}

object ColdStartProgress {
    /** Match cockpit async-wait: stay silent under ~200ms (#732). */
    const val NARRATION_REVEAL_MS: Long = 200L

    /**
     * Healthy cold start on SM-T390 was ~9.6s. Fail closed well above that so
     * slow-but-alive boots are not mislabeled as errors, while a permanent
     * black canvas still surfaces a bounded startup failure.
     */
    const val FAIL_CLOSED_MS: Long = 30_000L

    fun phase(
        rootPresent: Boolean,
        elapsedMs: Long,
        failAfterMs: Long = FAIL_CLOSED_MS,
    ): ColdStartPhase =
        when {
            rootPresent -> ColdStartPhase.Ready
            elapsedMs >= failAfterMs -> ColdStartPhase.Failed
            else -> ColdStartPhase.Starting
        }

    /**
     * Whether to show the delayed "starting up" label. Branded chrome may be
     * visible earlier; only this narration is latency-gated.
     */
    fun showStartingNarration(
        phase: ColdStartPhase,
        elapsedMs: Long,
        revealAfterMs: Long = NARRATION_REVEAL_MS,
    ): Boolean = phase == ColdStartPhase.Starting && elapsedMs >= revealAfterMs
}
