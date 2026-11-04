package com.mattmacosko.realtimeaicam.translation

import android.content.Context
import android.util.Log
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.common.model.DownloadConditions
import com.google.mlkit.common.model.RemoteModelManager
import com.google.mlkit.nl.translate.TranslateLanguage
import com.google.mlkit.nl.translate.TranslateRemoteModel
import com.google.mlkit.nl.translate.Translation
import com.google.mlkit.nl.translate.Translator
import com.google.mlkit.nl.translate.TranslatorOptions
import kotlinx.coroutines.flow.MutableStateFlow
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * "Your language" (2026-11-04, Play reviews from a French and a Spanish speaker: everything
 * was spoken in English). The language the person wants to HEAR. Read, Object Detection,
 * Help Me Aim and What's this? translate what they say into it with Google's on-device
 * translator. Screens and buttons stay English for now.
 *
 * Matt's rule: no added MB and nothing downloads until the person clearly wants it. The
 * language's translation pack downloads only on a tap of "Download <Name> once, then it works
 * offline"; until it is on the phone everything works exactly as in English. English = no
 * change at all. Same rules and words as iOS YourLanguage.swift.
 */
object YourLanguageRules {
    const val ENGLISH = "en"

    /** English plus the 17 languages Read can read. */
    val codes: List<String> = listOf(ENGLISH) + ReaderLanguages.all.map { it.code }

    fun name(code: String): String =
        if (code == ENGLISH) "English" else ReaderLanguages.all.firstOrNull { it.code == code }?.name ?: "English"

    /** Java's old codes ("in" Indonesian, "iw" Hebrew) and regional tags to our codes. */
    fun normalize(language: String): String {
        val base = language.lowercase().substringBefore('-').substringBefore('_')
        return when (base) { "in" -> "id"; "iw" -> "he"; "ji" -> "yi"; else -> base }
    }

    /** The phone's language when the app can translate into it, else English. */
    fun defaultFor(phoneLanguage: String): String =
        normalize(phoneLanguage).takeIf { it in codes } ?: ENGLISH

    /** A saved choice wins; nothing saved follows the phone. */
    fun resolve(saved: String?, phoneLanguage: String): String =
        saved?.takeIf { it in codes } ?: defaultFor(phoneLanguage)

    /** Announce once on first launch: only when the phone is in a supported language other than English. */
    fun shouldAnnounceFirstLaunch(phoneLanguage: String, alreadyAnnounced: Boolean): Boolean =
        !alreadyAnnounced && defaultFor(phoneLanguage) != ENGLISH

    fun firstLaunchLine(code: String): String {
        val n = name(code)
        return "Your language is $n. Spoken results can be translated into $n after a one-time download. You can change this in Settings."
    }

    fun downloadRow(code: String): String = "Download ${name(code)} once, then it works offline"
    fun downloadingLine(code: String): String = "Downloading ${name(code)}, one time only."
    fun stillDownloadingLine(code: String): String = "Still downloading ${name(code)}."
    fun readyLine(code: String): String = "${name(code)} is ready, it works offline now."
    fun failedLine(code: String, online: Boolean): String =
        if (online) "${name(code)} couldn't download just now. Tap the download row to try again."
        else "${name(code)} needs a one-time download. Connect to the internet once, then tap the download row."
    fun noVoiceLine(code: String): String =
        "No ${name(code)} voice is installed on this phone. You can add one in the phone's speech settings."

    /**
     * The Read pill. [page] is the language the page is in (null = English page). With Your
     * language English nothing changes ("English", "Span → Eng"). Otherwise it names both
     * ends: "French → Spanish", "English → Spanish", or just "Spanish" when they match.
     */
    fun pillLabel(page: ReaderLanguage?, target: String): String {
        if (target == ENGLISH) return if (page == null) "English" else "${page.tag} → Eng"
        val from = page?.name ?: "English"
        val to = name(target)
        return if (from == to) to else "$from → $to"
    }

    /** What a screen reader hears for the pill. */
    fun pillSpoken(page: ReaderLanguage?, target: String): String {
        if (target == ENGLISH) return if (page == null) "English" else "${page.name}, translated to English"
        val from = page?.name ?: "English"
        val to = name(target)
        return if (from == to) to else "$from, translated to $to"
    }
}

object YourLanguage {
    private const val TAG = "YourLanguage"
    const val PREFS = "rtcam"
    const val KEY = "userLanguage"
    const val ANNOUNCED_KEY = "userLanguageAnnounced"

    /** Packs on the phone (from Google's own list; asking never downloads anything). */
    val readyPacks = MutableStateFlow<Set<String>>(emptySet())
    /** True once Google has answered which packs are on the phone (shortly after launch). */
    @Volatile var packsKnown = false
        private set

    /** Wait (off the main thread) until [readyPacks] is known, at most [ms]. */
    fun awaitPacksKnown(ms: Long = 5_000) {
        val end = System.currentTimeMillis() + ms
        while (!packsKnown && System.currentTimeMillis() < end) Thread.sleep(50)
    }

    /** The code whose pack is downloading right now, or null. */
    val downloading = MutableStateFlow<String?>(null)
    /** Bumps when the choice changes, so screens can re-read it. */
    val choice = MutableStateFlow<String?>(null)

    private val worker = Executors.newSingleThreadExecutor { r -> Thread(r, "your-language").apply { isDaemon = true } }
    private val translators = HashMap<String, Translator>()
    private val lineCache = object : LinkedHashMap<String, String>(64, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, String>?) = size > 300
    }

    fun phoneLanguage(): String = java.util.Locale.getDefault().language

    fun code(context: Context): String {
        val saved = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY, null)
        return YourLanguageRules.resolve(saved, phoneLanguage())
    }

    fun set(context: Context, code: String) {
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString(KEY, code).apply()
        choice.value = code
        Log.i(TAG, "Your language = $code")
    }

    fun isReady(code: String): Boolean = code == YourLanguageRules.ENGLISH || code in readyPacks.value

    /** Your language when its pack is on the phone, else English (today's behaviour). */
    fun active(context: Context): String {
        val c = code(context)
        return if (isReady(c)) c else YourLanguageRules.ENGLISH
    }

    /** Ask Google which packs are on the phone. Never downloads. */
    fun refresh() {
        try {
            RemoteModelManager.getInstance().getDownloadedModels(TranslateRemoteModel::class.java)
                .addOnFailureListener { packsKnown = true }
                .addOnSuccessListener { models ->
                    readyPacks.value = models.map { it.language }.toSet()
                    packsKnown = true
                    Log.i(TAG, "packs on phone: ${readyPacks.value}")
                }
        } catch (t: Throwable) {
            Log.w(TAG, "pack list failed", t)
        }
    }

    /**
     * The person tapped the download row. The ONLY place a pack downloads. [say] gets the
     * spoken progress lines (on a background thread).
     */
    fun download(context: Context, code: String, say: (String) -> Unit, done: (Boolean) -> Unit = {}) {
        if (code == YourLanguageRules.ENGLISH || isReady(code) || downloading.value != null) { done(isReady(code)); return }
        downloading.value = code
        say(YourLanguageRules.downloadingLine(code))
        Log.i(TAG, "download requested by tap: $code")
        worker.execute {
            val ok = try {
                val task = RemoteModelManager.getInstance()
                    .download(TranslateRemoteModel.Builder(code).build(), DownloadConditions.Builder().build())
                var waited = 0
                while (!task.isComplete && waited < 300) {
                    Thread.sleep(1000); waited++
                    if (waited % 15 == 0) say(YourLanguageRules.stillDownloadingLine(code))
                }
                Tasks.await(task, 1, TimeUnit.SECONDS)
                true
            } catch (t: Throwable) {
                Log.w(TAG, "download $code failed", t)
                false
            }
            downloading.value = null
            if (ok) {
                readyPacks.value = readyPacks.value + code
                Log.i(TAG, "pack ready: $code")
                say(YourLanguageRules.readyLine(code))
            } else {
                say(YourLanguageRules.failedLine(code, online(context)))
            }
            done(ok)
        }
    }

    private fun online(context: Context): Boolean = try {
        val cm = context.getSystemService(android.net.ConnectivityManager::class.java)
        cm?.getNetworkCapabilities(cm.activeNetwork)?.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_INTERNET) == true
    } catch (_: Throwable) { false }

    /**
     * Translate one piece of text. Blocking: never call on the main thread. Both packs must be
     * on the phone (English always is); returns null when they aren't or on any error, so the
     * caller keeps the original. Never downloads.
     */
    fun translateBlocking(text: String, from: String, to: String): String? {
        if (text.isBlank() || from == to) return text
        if (!isReady(from) || !isReady(to)) return null
        val key = "$from>$to>$text"
        synchronized(lineCache) { lineCache[key]?.let { return it } }
        return try {
            val t = synchronized(translators) {
                translators.getOrPut("$from>$to") {
                    Translation.getClient(TranslatorOptions.Builder().setSourceLanguage(from).setTargetLanguage(to).build())
                }
            }
            val out = Tasks.await(t.translate(text), 20, TimeUnit.SECONDS).trim()
            if (out.isEmpty()) null else out.also { synchronized(lineCache) { lineCache[key] = it } }
        } catch (t: Throwable) {
            Log.w(TAG, "translate $from>$to failed", t)
            null
        }
    }

    /** Line by line, keeping the line breaks (sign lines, page lines). */
    fun translateLinesBlocking(text: String, from: String, to: String): String? {
        if (from == to) return text
        val out = text.split('\n').map { line -> if (line.isBlank()) line else translateBlocking(line, from, to) ?: return null }
        return out.joinToString("\n")
    }

    /** Translate off the main thread and hand the answer back on it. */
    fun translateAsync(text: String, from: String, to: String, result: (String?) -> Unit) {
        val main = android.os.Handler(android.os.Looper.getMainLooper())
        worker.execute {
            val r = translateBlocking(text, from, to)
            main.post { result(r) }
        }
    }

    /** True if Google's code for this language matches ours (they are the same set today). */
    @Suppress("unused")
    fun googleCode(code: String): String? = TranslateLanguage.fromLanguageTag(code)
}
