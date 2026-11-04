package com.mattmacosko.realtimeaicam.camera

import android.app.Activity
import android.content.Context
import android.graphics.Bitmap
import android.util.Log
import com.google.android.gms.common.Feature
import com.google.android.gms.common.api.OptionalModuleApi
import com.google.android.gms.common.moduleinstall.InstallStatusListener
import com.google.android.gms.common.moduleinstall.ModuleInstall
import com.google.android.gms.common.moduleinstall.ModuleInstallRequest
import com.google.android.gms.common.moduleinstall.ModuleInstallStatusUpdate
import com.google.android.gms.tasks.Tasks
import com.google.android.play.core.splitcompat.SplitCompat
import com.google.android.play.core.splitinstall.SplitInstallManagerFactory
import com.google.android.play.core.splitinstall.SplitInstallRequest
import com.google.android.play.core.splitinstall.SplitInstallSessionState
import com.google.android.play.core.splitinstall.SplitInstallStateUpdatedListener
import com.google.android.play.core.splitinstall.model.SplitInstallSessionStatus
import com.google.mlkit.common.sdkinternal.OptionalModuleUtils
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.TextRecognizer
import com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions
import com.google.mlkit.vision.text.japanese.JapaneseTextRecognizerOptions
import com.google.mlkit.vision.text.korean.KoreanTextRecognizerOptions
import com.mattmacosko.realtimeaicam.translation.ScriptReader
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * A page reader that lives outside the base app (the on-demand "readers" feature module).
 * The base APK carries only these two interfaces: no Tesseract code, no .so files.
 */
interface PageReader {
    /** The text on the page, in reading order; blank when nothing readable was seen. */
    fun read(bitmap: Bitmap): String
    fun close()
}

interface PageReaderFactory {
    /** [dataDir] holds tessdata/<lang>.traineddata. */
    fun open(dataDir: String, lang: String): PageReader
}

/**
 * The readers for languages the built-in Latin reader cannot see (2026-11-04). Every one of
 * them stays off the phone until the person taps to download that language, so the app
 * download is the same size for everyone:
 *  - Chinese, Japanese, Korean: Google's ML Kit readers, delivered by Play services through
 *    ModuleInstallClient (no install-time DEPENDENCIES meta-data, nothing auto-fetched).
 *  - Russian, Ukrainian, Thai, Arabic: Tesseract in the on-demand "readers" module
 *    (SplitInstallManager), plus that language's traineddata from our own server, checked
 *    against the manifest's SHA-256.
 * Blocking calls: run them off the main thread.
 */
object ScriptReaders {
    private const val TAG = "ScriptReaders"
    const val MODULE = "readers"
    private const val FACTORY = "com.mattmacosko.realtimeaicam.readers.TessPageReaderFactory"
    const val TESSDATA_BASE = "https://ineedhemp.com/models/rtcam/tessdata/"

    /**
     * Google's reader for Chinese / Japanese / Korean. Create it ONLY once [isReady] says the
     * reader is on the phone: creating one when it is not makes Play services fetch it
     * straight away (seen on the emulator 2026-11-04 just from the pill passing Japanese).
     */
    fun mlKitRecognizer(reader: ScriptReader): TextRecognizer = when (reader) {
        ScriptReader.CHINESE -> TextRecognition.getClient(ChineseTextRecognizerOptions.Builder().build())
        ScriptReader.JAPANESE -> TextRecognition.getClient(JapaneseTextRecognizerOptions.Builder().build())
        ScriptReader.KOREAN -> TextRecognition.getClient(KoreanTextRecognizerOptions.Builder().build())
        else -> throw IllegalArgumentException("$reader is not an ML Kit reader")
    }

    /**
     * Stands in for a recognizer when asking Play services about a reader, so checking (and
     * the install request on the tap) never has to create the recognizer itself.
     */
    private class ReaderFeature(private val feature: Feature) : OptionalModuleApi {
        override fun getOptionalFeatures(): Array<Feature> = arrayOf(feature)
    }

    private fun mlKitFeature(reader: ScriptReader): OptionalModuleApi = ReaderFeature(
        when (reader) {
            ScriptReader.CHINESE -> OptionalModuleUtils.FEATURE_OCR_CHINESE
            ScriptReader.JAPANESE -> OptionalModuleUtils.FEATURE_OCR_JAPANESE
            ScriptReader.KOREAN -> OptionalModuleUtils.FEATURE_OCR_KOREAN
            else -> throw IllegalArgumentException("$reader is not an ML Kit reader")
        }
    )

    fun tessDir(context: Context): File = File(context.filesDir, "readers")
    private fun tessFile(context: Context, code: String) = File(File(tessDir(context), "tessdata"), "$code.traineddata")

    private fun moduleInstalled(context: Context): Boolean =
        MODULE in SplitInstallManagerFactory.create(context).installedModules

    /** Is this reader on the phone already? Checks only, never downloads. */
    fun isReady(context: Context, reader: ScriptReader): Boolean = try {
        when {
            reader == ScriptReader.LATIN -> true
            reader.isTesseract -> moduleInstalled(context) && tessFile(context, reader.tessCode!!).length() > 0
            else -> Tasks.await(
                ModuleInstall.getClient(context).areModulesAvailable(mlKitFeature(reader)), 20, TimeUnit.SECONDS,
            ).areModulesAvailable()
        }
    } catch (e: Exception) {
        Log.w(TAG, "ready check for $reader failed", e)
        false
    }

    /**
     * Downloads the reader. Only called after the person tapped to download this language.
     * [progress] gets 0..1 (or null when the size is not known yet). Throws on failure.
     */
    fun install(
        context: Context,
        activity: Activity?,
        reader: ScriptReader,
        progress: (Float?) -> Unit,
    ) {
        if (reader.isTesseract) {
            if (!moduleInstalled(context)) installModule(context, activity) { progress(it?.times(0.5f)) }
            downloadTessData(context, reader.tessCode!!) { progress(0.5f + it * 0.5f) }
        } else {
            installMlKit(context, mlKitFeature(reader), progress)
        }
    }

    private fun installMlKit(context: Context, api: OptionalModuleApi, progress: (Float?) -> Unit) {
        val client = ModuleInstall.getClient(context)
        val done = CountDownLatch(1)
        var failure: String? = null
        val listener = object : InstallStatusListener {
            override fun onInstallStatusUpdated(update: ModuleInstallStatusUpdate) {
                update.progressInfo?.let { p ->
                    if (p.totalBytesToDownload > 0) progress(p.bytesDownloaded.toFloat() / p.totalBytesToDownload)
                }
                when (update.installState) {
                    ModuleInstallStatusUpdate.InstallState.STATE_COMPLETED -> done.countDown()
                    ModuleInstallStatusUpdate.InstallState.STATE_FAILED,
                    ModuleInstallStatusUpdate.InstallState.STATE_CANCELED -> {
                        failure = "install state ${update.installState}, error ${update.errorCode}"
                        done.countDown()
                    }
                }
            }
        }
        val request = ModuleInstallRequest.newBuilder().addApi(api).setListener(listener).build()
        try {
            val response = Tasks.await(client.installModules(request), 60, TimeUnit.SECONDS)
            if (!response.areModulesAlreadyInstalled() && !done.await(10, TimeUnit.MINUTES)) {
                throw IOException("the reader download timed out")
            }
        } finally {
            client.unregisterListener(listener)
        }
        failure?.let { throw IOException(it) }
        progress(1f)
    }

    private fun installModule(context: Context, activity: Activity?, progress: (Float?) -> Unit) {
        val manager = SplitInstallManagerFactory.create(context)
        val done = CountDownLatch(1)
        var failure: String? = null
        var sessionId = 0
        val listener = SplitInstallStateUpdatedListener { state: SplitInstallSessionState ->
            if (sessionId != 0 && state.sessionId() != sessionId) return@SplitInstallStateUpdatedListener
            when (state.status()) {
                SplitInstallSessionStatus.DOWNLOADING -> if (state.totalBytesToDownload() > 0) {
                    progress(state.bytesDownloaded().toFloat() / state.totalBytesToDownload())
                }
                SplitInstallSessionStatus.REQUIRES_USER_CONFIRMATION -> {
                    if (activity != null) manager.startConfirmationDialogForResult(state, activity, 4117)
                    else { failure = "needs confirmation"; done.countDown() }
                }
                SplitInstallSessionStatus.INSTALLED -> done.countDown()
                SplitInstallSessionStatus.FAILED, SplitInstallSessionStatus.CANCELED -> {
                    failure = "module install status ${state.status()}, error ${state.errorCode()}"
                    done.countDown()
                }
                else -> {}
            }
        }
        manager.registerListener(listener)
        try {
            sessionId = Tasks.await(
                manager.startInstall(SplitInstallRequest.newBuilder().addModule(MODULE).build()), 60, TimeUnit.SECONDS,
            )
            if (sessionId == 0 || MODULE in manager.installedModules) done.countDown()
            if (!done.await(10, TimeUnit.MINUTES)) throw IOException("the readers module timed out")
        } finally {
            manager.unregisterListener(listener)
        }
        failure?.let { throw IOException(it) }
        // Make the new code reachable without a restart.
        SplitCompat.install(context)
    }

    /** One traineddata file from our server, size and SHA-256 checked against the manifest. */
    private fun downloadTessData(context: Context, code: String, progress: (Float) -> Unit) {
        val dst = tessFile(context, code)
        if (dst.length() > 0) return
        dst.parentFile?.mkdirs()
        val manifest = JSONObject(httpText(URL(TESSDATA_BASE + "manifest.json")))
        val files = manifest.getJSONArray("files")
        val name = "$code.traineddata"
        val entry = (0 until files.length()).map { files.getJSONObject(it) }.firstOrNull { it.getString("name") == name }
            ?: throw IOException("$name is not on the server")
        val size = entry.getLong("size")
        val sha = entry.getString("sha256").lowercase()
        val part = File(dst.parentFile, "$name.part")
        part.delete()
        val c = URL(TESSDATA_BASE + name).openConnection() as HttpURLConnection
        c.connectTimeout = 20_000; c.readTimeout = 60_000
        try {
            if (c.responseCode != 200) throw IOException("The server answered ${c.responseCode} for $name.")
            var got = 0L
            FileOutputStream(part).use { out ->
                c.inputStream.use { input ->
                    val buf = ByteArray(1 shl 16)
                    while (true) {
                        val n = input.read(buf)
                        if (n < 0) break
                        out.write(buf, 0, n)
                        got += n
                        progress((got.toFloat() / size).coerceAtMost(1f))
                    }
                }
            }
        } finally { c.disconnect() }
        if (part.length() != size || sha256(part) != sha) {
            part.delete()
            throw IOException("$name failed its integrity check")
        }
        if (!part.renameTo(dst)) throw IOException("could not move $name into place")
        Log.i(TAG, "$name ready (${dst.length()} bytes, sha256 ok)")
    }

    /** Opens Tesseract from the readers module. The class is found by name, so the base app has none of its code. */
    fun openTesseract(context: Context, reader: ScriptReader): PageReader {
        SplitCompat.install(context)
        val factory = Class.forName(FACTORY, true, context.classLoader)
            .getDeclaredConstructor().newInstance() as PageReaderFactory
        return factory.open(tessDir(context).absolutePath, reader.tessCode!!)
    }

    private fun httpText(url: URL): String {
        val c = url.openConnection() as HttpURLConnection
        c.connectTimeout = 20_000; c.readTimeout = 30_000
        try {
            if (c.responseCode !in 200..299) throw IOException("The server answered ${c.responseCode}.")
            return c.inputStream.bufferedReader().readText()
        } finally { c.disconnect() }
    }

    private fun sha256(file: File): String {
        val md = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buf = ByteArray(1 shl 20)
            while (true) { val n = input.read(buf); if (n < 0) break; md.update(buf, 0, n) }
        }
        return md.digest().joinToString("") { "%02x".format(it) }
    }
}
