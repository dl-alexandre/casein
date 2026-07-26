// mob_biometric plugin — Android bridge (androidx.biometric BiometricPrompt).
//
// Extracted from mob-core's MobBridge.biometric_authenticate (mob_new template
// MobBridge.kt.eex lines 681-712). Lives in the plugin's own package; mob_dev
// copies it into the app Kotlin sourceSet and MobPluginBootstrap.registerAll()
// calls register() at startup and hands it the Activity (MobActivityAware).
// No MobPermissionProvider: biometric auth has no runtime permission dialog —
// it uses the device's existing enrollment.
//
// The native thunks (nativeRegister + nativeDeliverBiometric) are exported
// directly from the sibling zig NIF mob_biometric_nif.zig.
//
// ACTIVITY-TYPE FINDING (copied verbatim from the template): androidx.biometric
// 1.1.0's BiometricPrompt constructor requires a FragmentActivity, but mob's
// MainActivity is a ComponentActivity (Compose host — MainActivity.kt.eex:31).
// The template makes this COMPILE with the safe cast
// `activityRef?.get() as? FragmentActivity`; at RUNTIME on a mob host the cast
// returns null and we deliver {:biometric, :not_available}. That is core's
// current (degraded) Android behavior and is preserved verbatim here. Making
// the prompt actually show on Android needs either androidx.biometric 1.2.x's
// ComponentActivity-friendly API or a FragmentActivity host — a follow-up,
// not part of this extraction.
package io.mob.biometric

import android.app.Activity
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import java.lang.ref.WeakReference
import java.util.concurrent.Executor

object MobBiometricBridge : io.mob.plugin.MobActivityAware {
    private var activityRef: WeakReference<Activity>? = null

    @JvmStatic external fun nativeRegister()

    // result: "success" | "failure" | "not_available" -> {:biometric, atom}
    @JvmStatic external fun nativeDeliverBiometric(pid: Long, result: String)

    @JvmStatic
    fun register() {
        nativeRegister()
    }

    override fun setActivity(activity: Activity) {
        activityRef = WeakReference(activity)
    }

    @JvmStatic
    fun biometric_authenticate(pid: Long, reason: String) {
        // VERBATIM from core (template MobBridge.kt.eex:684) — see the
        // activity-type finding in the header comment.
        val activity = activityRef?.get() as? FragmentActivity ?: run {
            nativeDeliverBiometric(pid, "not_available"); return
        }
        val mgr = BiometricManager.from(activity)
        if (mgr.canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_WEAK)
                != BiometricManager.BIOMETRIC_SUCCESS) {
            nativeDeliverBiometric(pid, "not_available"); return
        }
        val executor: Executor = ContextCompat.getMainExecutor(activity)
        val prompt = BiometricPrompt(activity, executor, object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                nativeDeliverBiometric(pid, "success")
            }
            override fun onAuthenticationFailed() {
                nativeDeliverBiometric(pid, "failure")
            }
            override fun onAuthenticationError(code: Int, msg: CharSequence) {
                nativeDeliverBiometric(pid, if (code == BiometricPrompt.ERROR_CANCELED ||
                    code == BiometricPrompt.ERROR_USER_CANCELED) "failure" else "not_available")
            }
        })
        activity.runOnUiThread {
            prompt.authenticate(BiometricPrompt.PromptInfo.Builder()
                .setTitle("Authenticate").setSubtitle(reason)
                .setNegativeButtonText("Cancel")
                .setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_WEAK).build())
        }
    }
}
