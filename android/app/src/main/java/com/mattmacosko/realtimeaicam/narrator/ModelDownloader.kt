package com.mattmacosko.realtimeaicam.narrator

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
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
        job = scope.launch {
            val outcome = try { fetch(context, level); null } catch (t: Throwable) { t }
            synchronized(this@ModelDownloader) {
                if (current == level) {
                    when {
                        outcome == null -> set(level, State.Ready)
                        outcome is kotlinx.coroutines.CancellationException -> {}
                        else -> {
                            Log.e(TAG, "download of ${level.key} failed", outcome)
                            set(level, State.Failed(outcome.message ?: outcome.javaClass.simpleName))
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
                set(level, State.Downloading(((before + got).toDouble() / total).toFloat()))
            }
            before += f.size
        }
        set(level, State.Verifying)
        for (f in manifest.files) {
            val file = File(staging, f.name)
            if (file.length() != f.size) throw IOException("${f.name} came down the wrong size.")
            if (f.sha256 != null && sha256(file) != f.sha256.lowercase()) {
                file.delete()   // a bad file must not be trusted next time
                throw IOException("${f.name} failed its integrity check.")
            }
        }
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
