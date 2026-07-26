// mob_camera plugin — Android bridge (CameraX).
//
// Extracted from mob-core's MobBridge camera_* methods. Lives in the plugin's
// own package; MobPluginBootstrap.registerAll() calls register() at startup,
// hands it the Activity (MobActivityAware), and records it as a permission
// provider (MobPermissionProvider, :camera -> CAMERA).
//
// The native thunks (nativeRegister + the deliver hooks) are exported directly
// from the sibling zig NIF mob_camera_nif.zig.
//
// DESIGN NOTE vs core: capture (TakePicture/CaptureVideo) needs an
// ActivityResultLauncher. core registered it in MainActivity.onCreate via
// registerForActivityResult, but that convenience API must run before the host
// reaches STARTED — a late-bound plugin can't meet that. mob's MainActivity is
// a ComponentActivity (Compose host), not a FragmentActivity, so a headless
// Fragment can't attach either. Instead this bridge registers directly on the
// ComponentActivity's ActivityResultRegistry (register(key, contract, callback)
// is callable any time) and unregisters in the callback — self-contained, no
// host MainActivity changes.
//
// The live PREVIEW component (MobCameraPreview) is NOT here yet: it's a Compose
// native-view bound to this bridge's observable state, which needs the plugin
// Compose native-view path (cf. mob_demo_signature_pad). See EXTRACTION.md.
package io.mob.camera

import android.app.Activity
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Matrix
import android.net.Uri
import android.util.Log
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.ActivityResultRegistryOwner
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.ImageProxy
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import org.json.JSONObject
import java.io.File
import java.lang.ref.WeakReference
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicLong

object MobCameraBridge : io.mob.plugin.MobActivityAware, io.mob.plugin.MobPermissionProvider {
    private var activityRef: WeakReference<Activity>? = null

    @JvmStatic external fun nativeRegister()

    // Frame delivery: {:camera, :frame, %{...}}
    @JvmStatic external fun nativeDeliverCameraFrame(
        pid: Long,
        bytes: ByteArray,
        width: Int,
        height: Int,
        format: String,
        timestampMs: Long,
        dropped: Long,
    )

    // Capture result: path -> {:camera, :photo|:video, %{path,...}}; kind=="cancelled" -> {:camera, :cancelled}
    @JvmStatic external fun nativeDeliverCameraFile(
        pid: Long,
        kind: String,
        path: String,
    )

    @JvmStatic external fun nativeDeliverCameraCancelled(pid: Long)

    @JvmStatic fun register() = nativeRegister()

    override fun setActivity(activity: Activity) {
        activityRef = WeakReference(activity)
    }

    override fun permissionsFor(cap: String): Array<String>? = if (cap == "camera") arrayOf(android.Manifest.permission.CAMERA) else null

    // ── Capture (photo / video) ───────────────────────────────────────────
    private var pendingPid: Long = 0L

    @JvmStatic
    fun camera_capture_photo(
        pid: Long,
        quality: String,
    ) = launchCapture(pid, video = false)

    @JvmStatic
    fun camera_capture_video(
        pid: Long,
        maxDuration: String,
    ) = launchCapture(pid, video = true)

    private val captureSeq = AtomicLong(0L)

    private fun launchCapture(
        pid: Long,
        video: Boolean,
    ) {
        pendingPid = pid
        // mob's MainActivity is a ComponentActivity (Compose host), NOT a
        // FragmentActivity, so a headless Fragment can't attach. ComponentActivity
        // is an ActivityResultRegistryOwner, so register against its registry
        // directly. The register(key, contract, callback) overload (no
        // LifecycleOwner) is callable any time — unlike registerForActivityResult,
        // which must run before the host reaches STARTED, a constraint a late-bound
        // plugin can't meet. We unregister inside the callback.
        val activity =
            activityRef?.get() ?: run {
                nativeDeliverCameraCancelled(pid)
                return
            }
        val owner =
            activity as? ActivityResultRegistryOwner ?: run {
                nativeDeliverCameraCancelled(pid)
                return
            }
        val outUri = captureUri(activity, video)
        val contract =
            if (video) {
                ActivityResultContracts.CaptureVideo()
            } else {
                ActivityResultContracts.TakePicture()
            }
        val key = "mob_camera_capture_${captureSeq.incrementAndGet()}"
        var launcher: ActivityResultLauncher<Uri>? = null
        launcher =
            owner.activityResultRegistry.register(key, contract) { ok: Boolean ->
                onCaptureResult(if (ok) outUri else null, video)
                launcher?.unregister()
            }
        launcher.launch(outUri)
    }

    internal fun onCaptureResult(
        uri: Uri?,
        video: Boolean,
    ) {
        val pid = pendingPid
        val activity = activityRef?.get()
        if (uri == null || activity == null) {
            nativeDeliverCameraCancelled(pid)
            return
        }
        Thread {
            try {
                val ext = if (video) "mp4" else "jpg"
                val tmp = File(activity.cacheDir, "mob_cam_${System.currentTimeMillis()}.$ext")
                activity.contentResolver.openInputStream(uri)?.use { it.copyTo(tmp.outputStream()) }
                nativeDeliverCameraFile(pid, if (video) "video" else "photo", tmp.absolutePath)
            } catch (e: Exception) {
                nativeDeliverCameraCancelled(pid)
            }
        }.start()
    }

    internal fun captureUri(
        activity: Activity,
        video: Boolean,
    ): Uri {
        val ext = if (video) "mp4" else "jpg"
        val f = File(activity.cacheDir, "mob_cam_out_${System.currentTimeMillis()}.$ext")
        return FileProvider.getUriForFile(activity, "${activity.packageName}.fileprovider", f)
    }

    // ── Live frame stream ─────────────────────────────────────────────────
    // The MobCameraPreview Compose native-view (plugin component, pending)
    // observes this state and binds CameraX ImageAnalysis with deliverFrame.
    internal val frameStreamRev = AtomicLong(0L)
    internal var frameStreamActive = false
    internal var frameStreamPid: Long = 0L
    internal var frameStreamWidth = 640
    internal var frameStreamHeight = 640
    internal var frameStreamFormat = "rgb_f32"
    internal var frameStreamThrottleMs = 0
    private var lastDeliveryMs = 0L
    private var droppedCount = 0L
    internal var previewFacing: String? = null
    internal val analysisExecutor = Executors.newSingleThreadExecutor()

    @JvmStatic
    fun camera_start_preview(
        pid: Long,
        optsJson: String,
    ) {
        previewFacing =
            try {
                JSONObject(optsJson).optString("facing", "back")
            } catch (_: Exception) {
                "back"
            }
        frameStreamRev.incrementAndGet()
    }

    @JvmStatic
    fun camera_stop_preview() {
        previewFacing = null
        frameStreamRev.incrementAndGet()
    }

    @JvmStatic
    fun camera_start_frame_stream(
        pid: Long,
        optsJson: String,
    ) {
        try {
            val o = JSONObject(optsJson)
            frameStreamPid = pid
            frameStreamWidth = o.optInt("width", 640).coerceIn(1, 4096)
            frameStreamHeight = o.optInt("height", 640).coerceIn(1, 4096)
            frameStreamFormat = o.optString("format", "rgb_f32")
            frameStreamThrottleMs = o.optInt("throttle_ms", 0)
            if (previewFacing != o.optString("facing", "back")) previewFacing = o.optString("facing", "back")
            lastDeliveryMs = 0L
            droppedCount = 0L
            frameStreamActive = true
            frameStreamRev.incrementAndGet()
        } catch (e: Exception) {
            Log.e("MobCamera", "start_frame_stream failed: ${e.message}")
        }
    }

    @JvmStatic
    fun camera_stop_frame_stream() {
        frameStreamActive = false
        frameStreamRev.incrementAndGet()
    }

    // Called from the CameraX analyzer thread (by MobCameraPreview).
    internal fun deliverFrame(image: ImageProxy) {
        try {
            val now = System.currentTimeMillis()
            if (frameStreamThrottleMs > 0 && (now - lastDeliveryMs) < frameStreamThrottleMs.toLong()) {
                droppedCount++
                return
            }
            val rotated = rotateIfNeeded(image.toBitmap(), image.imageInfo.rotationDegrees)
            val cropped = centerCropAndScale(rotated, frameStreamWidth, frameStreamHeight)
            val bytes = if (frameStreamFormat == "bgra_u8") bitmapToBgraU8(cropped) else bitmapToRgbF32(cropped)
            nativeDeliverCameraFrame(frameStreamPid, bytes, cropped.width, cropped.height, frameStreamFormat, now, droppedCount)
            lastDeliveryMs = now
            droppedCount = 0L
        } catch (e: Throwable) {
            Log.e("MobCamera", "deliverFrame failed: ${e.message}")
        } finally {
            image.close()
        }
    }

    private fun rotateIfNeeded(
        bm: Bitmap,
        deg: Int,
    ): Bitmap {
        if (deg == 0) return bm
        val m = Matrix().apply { postRotate(deg.toFloat()) }
        return Bitmap.createBitmap(bm, 0, 0, bm.width, bm.height, m, true)
    }

    private fun centerCropAndScale(
        src: Bitmap,
        w: Int,
        h: Int,
    ): Bitmap {
        val srcAspect = src.width.toDouble() / src.height
        val dstAspect = w.toDouble() / h
        val (cropX, cropY, cropW, cropH) =
            when {
                srcAspect > dstAspect -> {
                    val cw = (src.height * dstAspect).toInt()
                    arrayOf((src.width - cw) / 2, 0, cw, src.height)
                }

                srcAspect < dstAspect -> {
                    val ch = (src.width / dstAspect).toInt()
                    arrayOf(0, (src.height - ch) / 2, src.width, ch)
                }

                else -> {
                    arrayOf(0, 0, src.width, src.height)
                }
            }
        val cropped = Bitmap.createBitmap(src, cropX, cropY, cropW, cropH)
        return if (cropped.width != w || cropped.height != h) {
            Bitmap.createScaledBitmap(cropped, w, h, true)
        } else {
            cropped
        }
    }

    private fun bitmapToRgbF32(bm: Bitmap): ByteArray {
        val w = bm.width
        val h = bm.height
        val pixels = IntArray(w * h)
        bm.getPixels(pixels, 0, w, 0, 0, w, h)
        val out = ByteArray(w * h * 3 * 4)
        val bb = ByteBuffer.wrap(out).order(ByteOrder.LITTLE_ENDIAN)
        for (i in 0 until w * h) {
            val px = pixels[i]
            bb.putFloat(((px shr 16) and 0xff) / 255f)
            bb.putFloat(((px shr 8) and 0xff) / 255f)
            bb.putFloat((px and 0xff) / 255f)
        }
        return out
    }

    private fun bitmapToBgraU8(bm: Bitmap): ByteArray {
        val w = bm.width
        val h = bm.height
        val pixels = IntArray(w * h)
        bm.getPixels(pixels, 0, w, 0, 0, w, h)
        val out = ByteArray(w * h * 4)
        for (i in 0 until w * h) {
            val px = pixels[i]
            out[i * 4 + 0] = (px and 0xff).toByte()
            out[i * 4 + 1] = ((px shr 8) and 0xff).toByte()
            out[i * 4 + 2] = ((px shr 16) and 0xff).toByte()
            out[i * 4 + 3] = ((px shr 24) and 0xff).toByte()
        }
        return out
    }
}
