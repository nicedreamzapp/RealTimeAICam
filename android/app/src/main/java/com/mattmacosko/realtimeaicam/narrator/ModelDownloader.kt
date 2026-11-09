package com.mattmacosko.realtimeaicam.narrator

import com.mattmacosko.realtimeaicam.AppLang
import com.mattmacosko.realtimeaicam.R
import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.speech.tts.TextToSpeech
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityManager
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest

/**
 * Fetches downloadable levels from our own server, one at a time, file by file.
 * A cut-off file resumes from its last byte (HTTP Range) the next time, and
 * every file is checked against the manifest's size and SHA-256 before the level
 * is moved into place. The request carries nothing but the file name.
 */
object ModelDownloader {
    private const val TAG = "ModelDownloader"

    sealed class State {
        object Idle : State()
        object Queued : State()
        data class Downloading(val progress: Float) : State()
        object Verifying : State()
        object Ready : State()
        data class Failed(val why: String) : State()
    }

    private val _states = MutableStateFlow<Map<ModelLevel, State>>(emptyMap())
    val states: StateFlow<Map<ModelLevel, State>> = _states

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var tts: TextToSpeech? = null

    /**
     * Says a download update out loud: the app's own voice, or TalkBack when the
     * person turned the app voice off (Settings), so two voices never overlap.
     */
    private fun announce(context: Context, text: String) {
        val app = context.applicationContext
        val ownVoice = app.getSharedPreferences("rtaicam", Context.MODE_PRIVATE).getBoolean("speakAnswersAloud", true)
        val am = app.getSystemService(Context.ACCESSIBILITY_SERVICE) as AccessibilityManager
        if (!ownVoice && am.isEnabled) {
            @Suppress("DEPRECATION")
            val e = AccessibilityEvent.obtain(AccessibilityEvent.TYPE_ANNOUNCEMENT).apply {
                // Carries the app's language, so TalkBack reads a Spanish line in a Spanish voice.
                this.text.add(com.mattmacosko.realtimeaicam.ui.A11yAnnounce.inAppLanguage(text)); packageName = app.packageName; className = javaClass.name
            }
            am.sendAccessibilityEvent(e)
            return
        }
        // The line is in the app's language: say it in a voice for that language.
        val lang = AppLang.code()
        val existing = tts
        if (existing != null) {
            com.mattmacosko.realtimeaicam.ui.VoicePrefs.applyFor(app, existing, lang)
            existing.speak(text, TextToSpeech.QUEUE_ADD, null, "model"); return
        }
        var made: TextToSpeech? = null
        made = TextToSpeech(app) { status ->
            if (status == TextToSpeech.SUCCESS) made?.let {
                com.mattmacosko.realtimeaicam.ui.VoicePrefs.applyFor(app, it, lang)
                it.speak(text, TextToSpeech.QUEUE_ADD, null, "model")
            }
        }
        tts = made
    }
    private val queue = ArrayDeque<ModelLevel>()
    private var current: ModelLevel? = null
    private var job: Job? = null

    data class Manifest(val version: String, val files: List<Entry>) {
        data class Entry(val name: String, val size: Long, val sha256: String?)
    }

    fun readManifest(file: File): Manifest? = try { parse(file.readText()) } catch (t: Throwable) { null }

    private fun parse(text: String): Manifest {
        val o = JSONObject(text)
        val arr = o.getJSONArray("files")
        return Manifest(o.optString("version"), (0 until arr.length()).map {
            val f = arr.getJSONObject(it)
            Manifest.Entry(f.getString("name"), f.getLong("size"), f.optString("sha256").ifBlank { null })
        })
    }

    fun state(context: Context, level: ModelLevel): State =
        _states.value[level] ?: if (level.isInstalled(context)) State.Ready else State.Idle

    private fun set(level: ModelLevel, s: State) { _states.value = _states.value + (level to s) }

    /** Progress from a running download; dropped once that download was stopped, so a Stop sticks on screen. */
    @Synchronized
    private fun setFromDownload(level: ModelLevel, s: State) { if (current == level) set(level, s) }

    @Synchronized
    fun start(context: Context, level: ModelLevel) {
        if (level.isBundled) return
        when (state(context, level)) {
            State.Ready, State.Queued, State.Verifying, is State.Downloading -> return
            else -> {}
        }
        if (level.isInstalled(context)) { set(level, State.Ready); return }
        set(level, State.Queued)
        queue.addLast(level)
        next(context.applicationContext)
    }

    @Synchronized
    fun delete(context: Context, level: ModelLevel) {
        if (level.isBundled) return
        queue.remove(level)
        if (current == level) { job?.cancel(); current = null }
        level.staging(context).deleteRecursively()
        level.folder(context).deleteRecursively()
        set(level, State.Idle)
        next(context.applicationContext)
    }

    /**
     * The person deleted a level or stopped its download: the files go, and the
     * level is remembered so automatic mode never fetches it again on its own.
     * Picking it and tapping Download again is the only way back.
     */
    fun remove(context: Context, level: ModelLevel) {
        if (level.isBundled) return
        delete(context, level)
        ModelPicker.markRemoved(context, level)
        if (ModelPicker.pendingLevel(context) == level) ModelPicker.setPending(context, null)
    }

    /** The person tapped Download on a level: it is wanted again and becomes the choice once installed. */
    fun requestByUser(context: Context, level: ModelLevel) {
        if (level.isBundled) return
        ModelPicker.clearRemoved(context, level)
        ModelPicker.setPending(context, level)
        start(context, level)
    }

    /** Picks up levels whose download was cut off by the app closing. */
    fun resumeInterrupted(context: Context) {
        for (level in ModelLevel.entries) {
            if (!level.isBundled && level.staging(context).isDirectory && !level.isInstalled(context)) start(context, level)
        }
    }

    /** Wi-Fi or any other connection that doesn't count against a data plan. */
    fun onUnmeteredNetwork(context: Context): Boolean {
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val caps = cm.getNetworkCapabilities(cm.activeNetwork) ?: return false
        return caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
            caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
    }

    /** Levels automatic mode wants that are not here yet. */
    fun missingWanted(context: Context): List<ModelLevel> =
        ModelLevel.entries.filter { it in ModelPicker.wanted(context) && !it.isInstalled(context) }

    /** Starts what automatic mode wants; `automatic` ones wait for Wi-Fi. */
    fun fetchWanted(context: Context, automatic: Boolean) {
        if (automatic && !onUnmeteredNetwork(context)) return
        missingWanted(context).forEach { start(context, it) }
    }

    @Synchronized
    private fun next(context: Context) {
        if (current != null || queue.isEmpty()) return
        val level = queue.removeFirst()
        current = level
        set(level, State.Downloading(0f))
        announce(context, AppLang.str(R.string.e_dl_getting, level.title, level.sizeText()))
        job = scope.launch {
            val outcome = try { fetch(context, level); null } catch (t: Throwable) { t }
            synchronized(this@ModelDownloader) {
                if (current == level) {
                    when {
                        outcome == null -> {
                            set(level, State.Ready)
                            // A level the person asked for becomes the choice only now that it is here.
                            if (ModelPicker.pendingLevel(context) == level) {
                                ModelPicker.setManualLevel(context, level)
                                ModelPicker.setPending(context, null)
                            }
                            announce(context, AppLang.str(R.string.e_dl_ready, level.title))
                        }
                        outcome is kotlinx.coroutines.CancellationException -> {}
                        else -> {
                            Log.e(TAG, "download of ${level.key} failed", outcome)
                            set(level, State.Failed(outcome.message ?: outcome.javaClass.simpleName))
                            announce(context, AppLang.str(R.string.e_dl_stopped, level.title))
                        }
                    }
                    current = null
                    next(context)
                }
            }
        }
    }

    private suspend fun fetch(context: Context, level: ModelLevel) {
        val staging = level.staging(context).apply { mkdirs() }
        val manifestText = get(URL(level.remoteBase + "manifest.json"))
        val manifest = parse(manifestText)
        if (manifest.files.isEmpty()) throw IOException("The model list on the server is empty.")
        File(staging, "manifest.json").writeText(manifestText)
        val total = manifest.files.sumOf { it.size }.coerceAtLeast(1)
        var before = 0L
        for (f in manifest.files) {
            val dst = File(staging, f.name)
            if (dst.length() > f.size) dst.delete()
            if (dst.length() < f.size) download(URL(level.remoteBase + f.name), dst, f.size) { got ->
                setFromDownload(level, State.Downloading(((before + got).toDouble() / total).toFloat()))
            }
            before += f.size
        }
        setFromDownload(level, State.Verifying)
        for (f in manifest.files) {
            val file = File(staging, f.name)
            if (file.length() != f.size) throw IOException("${f.name} came down the wrong size.")
            if (f.sha256 != null && sha256(file) != f.sha256.lowercase()) {
                file.delete()   // a bad file must not be trusted next time
                throw IOException("${f.name} failed its integrity check.")
            }
        }
        // Stopped while checking: never move a stopped level into place.
        kotlinx.coroutines.currentCoroutineContext().ensureActive()
        val final = level.folder(context)
        final.deleteRecursively()
        if (!staging.renameTo(final)) throw IOException("could not move ${level.key} into place")
    }

    private fun get(url: URL): String {
        val c = url.openConnection() as HttpURLConnection
        c.connectTimeout = 20_000; c.readTimeout = 30_000
        try {
            if (c.responseCode !in 200..299) throw IOException("The server answered ${c.responseCode} for ${url.path.substringAfterLast('/')}.")
            return c.inputStream.bufferedReader().readText()
        } finally { c.disconnect() }
    }

    /** Appends to `dst` from its current length (Range), reporting bytes on disk. */
    private suspend fun download(url: URL, dst: File, size: Long, progress: (Long) -> Unit) {
        val have = dst.length()
        val c = url.openConnection() as HttpURLConnection
        c.connectTimeout = 20_000; c.readTimeout = 60_000
        if (have > 0) c.setRequestProperty("Range", "bytes=$have-")
        try {
            val code = c.responseCode
            val append = code == 206
            if (code != 200 && code != 206) throw IOException("The server answered $code for ${dst.name}.")
            var got = if (append) have else 0L
            FileOutputStream(dst, append).use { out ->
                c.inputStream.use { input ->
                    val buf = ByteArray(1 shl 16)
                    var lastReport = 0L
                    while (kotlinx.coroutines.currentCoroutineContext().isActive) {
                        val n = input.read(buf)
                        if (n < 0) break
                        out.write(buf, 0, n)
                        got += n
                        if (got - lastReport > (4 shl 20)) { progress(got); lastReport = got }
                    }
                }
            }
            progress(got)
            if (got < size) throw IOException("${dst.name} stopped early; it will pick up from here next time.")
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
