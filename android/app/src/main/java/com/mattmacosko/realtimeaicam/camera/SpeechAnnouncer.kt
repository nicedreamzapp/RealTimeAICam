package com.mattmacosko.realtimeaicam.camera

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityManager
import com.mattmacosko.realtimeaicam.detection.Detection
import kotlinx.coroutines.flow.MutableStateFlow

/**
 * Live Object Detection speech. Started as a port of the iOS SpeechManager
 * rulebook (project 601/SpeechManager.swift); both phones now follow these
 * rules, changed together on 2026-09-25 after Blind Android Users testing:
 *
 *  - announcementInterval = 1.0s   minimum gap between announcement CYCLES
 *  - classCooldown        = 45.0s  per EXACT class name repeat cooldown
 *  - interObjectDelay     = 0.8s   pause between queued objects
 *  - never process a cycle while speaking or while the queue is draining
 *  - at most 3 names a cycle, the most central object first (distance of the
 *    box centre from the frame centre, then the bigger box) — Warren wanted
 *    the thing he is pointing at, not the edges of the shot
 *  - a queued name is dropped if that object has left the latest frame, so it
 *    stops talking about what you already moved off
 *  - with the app's own voice off, the whole cycle goes to TalkBack as ONE
 *    announcement and the next cycle waits until it has had time to be heard;
 *    one announcement per frame made TalkBack cut each off after a letter
 *  - spoken text is the lowercase class name only (no confidence)
 *  - per-class entries older than 60s are cleaned up each cycle
 *  - enabling speech announces "Speech enabled"; disabling stops immediately,
 *    clears the queue, and resets the cycle timer
 *  - stopSpeech() (camera flip / Back / mode change) interrupts instantly
 */
class SpeechAnnouncer(context: Context) {

    private companion object {
        const val ANNOUNCEMENT_INTERVAL_MS = 1_000L
        const val CLASS_COOLDOWN_MS = 45_000L
        const val INTER_OBJECT_DELAY_MS = 800L
        const val CLEANUP_AGE_MS = 60_000L
        const val MAX_PER_CYCLE = 3
        const val GOOGLE_TTS = "com.google.android.tts"
    }

    val enabled = MutableStateFlow(false)

    /**
     * True only while TTS audio is actually playing (iOS LiveOCRView
     * isSpeaking). Driven by the real utterance lifecycle: set in onStart,
     * cleared in onDone/onError/onStop and by stop(). Never set eagerly at
     * request time — iOS fixed a "stuck green with no audio" bug this way.
     */
    val speakingNow = MutableStateFlow(false)

    private val appContext = context.applicationContext
    private val mainHandler = Handler(Looper.getMainLooper())
    @Volatile private var ready = false
    private var appliedVoice: String? = null

    @Volatile private var isSpeaking = false
    /** Last utterance the engine finished (done, error or stopped); lets speakAndWait wait for its own line. */
    @Volatile private var lastFinishedId: String? = null
    @Volatile private var isProcessingQueue = false
    private val announcementQueue = ArrayDeque<Pair<String, String>>() // class name, spoken name
    /** Class names in the most recent frame, for dropping stale queued names. */
    @Volatile private var inView: Set<String> = emptySet()
    /** Screen-reader mode has no "done" callback; the next cycle waits until this time. */
    @Volatile private var screenReaderBusyUntil = 0L
    private var lastAnnouncementTime = 0L
    private val lastSpokenByClass = java.util.concurrent.ConcurrentHashMap<String, Long>()
    private var utteranceSeq = 0L

    /**
     * Cold first launch (2026-10-23, a 1-star Play review: "no voice output"). The speech
     * engine starts asynchronously, and on a fresh install it can take seconds. Anything the
     * app said before then was silently dropped, and nothing ever retried. Now:
     *  - the latest line asked for before the engine is up is kept and said the moment it is;
     *  - if the phone's default engine fails to start, Google's engine is tried once;
     *  - if the engine has no voice for the phone's language, US English is used;
     *  - if no engine works at all, lines go to TalkBack instead of nowhere.
     */
    @Volatile private var pendingLine: Pair<String, String>? = null
    @Volatile private var engineFailed = false
    private var triedGoogleEngine = false

    private fun createEngine(enginePackage: String?): TextToSpeech {
        val holder = arrayOfNulls<TextToSpeech>(1)
        val onInit = TextToSpeech.OnInitListener { status ->
            mainHandler.post { onEngineInit(holder[0], status) }
        }
        val engine = if (enginePackage == null) TextToSpeech(appContext, onInit)
        else TextToSpeech(appContext, onInit, enginePackage)
        holder[0] = engine
        engine.setOnUtteranceProgressListener(progressListener)
        return engine
    }

    private fun onEngineInit(engine: TextToSpeech?, status: Int) {
        if (engine == null || engine !== tts) return
        if (status != TextToSpeech.SUCCESS) {
            if (!triedGoogleEngine && engine.defaultEngine != GOOGLE_TTS) {
                triedGoogleEngine = true
                try { engine.shutdown() } catch (_: Throwable) {}
                tts = createEngine(GOOGLE_TTS)
                return
            }
            engineFailed = true
            pendingLine?.let { announceToScreenReader(it.first) }
            pendingLine = null
            return
        }
        ensureLanguage(engine)
        ready = true
        val line = pendingLine
        pendingLine = null
        if (line != null) {
            speakInternal(line.first, line.second)
        } else {
            // Load the voice now, silently, so the first thing the app says (the "three" of a
            // countdown) is not waiting on a cold voice. Google TTS takes ~3.5 s to load one.
            warmVoice()
        }
    }

    /** No voice data for the phone's language (or none picked yet): fall back to US English. */
    private fun ensureLanguage(engine: TextToSpeech) {
        try {
            val current = engine.voice?.locale ?: java.util.Locale.getDefault()
            val ok = engine.isLanguageAvailable(current) >= TextToSpeech.LANG_AVAILABLE &&
                engine.voice?.features?.contains(TextToSpeech.Engine.KEY_FEATURE_NOT_INSTALLED) != true
            if (!ok) engine.setLanguage(java.util.Locale.US)
        } catch (_: Throwable) {}
    }

    private val progressListener: UtteranceProgressListener by lazy {
        object : UtteranceProgressListener() {
            override fun onStart(utteranceId: String?) {
                this@SpeechAnnouncer.isSpeaking = true
                speakingNow.value = true
            }

            override fun onDone(utteranceId: String?) {
                lastFinishedId = utteranceId
                this@SpeechAnnouncer.isSpeaking = false
                speakingNow.value = false
                // iOS: schedule next queued object after interObjectDelay
                if (utteranceId?.startsWith("announce-") == true) {
                    mainHandler.postDelayed({ processNextInQueue() }, INTER_OBJECT_DELAY_MS)
                }
            }

            @Deprecated("Deprecated in Java")
            override fun onError(utteranceId: String?) {
                lastFinishedId = utteranceId
                this@SpeechAnnouncer.isSpeaking = false
                speakingNow.value = false
                isProcessingQueue = false
            }

            override fun onStop(utteranceId: String?, interrupted: Boolean) {
                lastFinishedId = utteranceId
                this@SpeechAnnouncer.isSpeaking = false
                speakingNow.value = false
            }
        }
    }

    // Declared after progressListener: createEngine() reads it while this initialises.
    private var tts: TextToSpeech = createEngine(null)

    /** iOS setSpeechEnabled/handleToggleSpeech behavior. */
    fun setEnabled(on: Boolean) {
        if (on == enabled.value) return
        if (on) {
            enabled.value = true
            // iOS announceSpeechEnabled(): clears queue, speaks confirmation
            announcementQueue.clear()
            isProcessingQueue = false
            sayOrHold("Speech enabled", "toggle-${utteranceSeq++}")
        } else {
            stop() // also sets enabled=false, like iOS stopSpeech()
        }
    }

    /** iOS processDetectionsForSpeech — called once per processed frame. */
    fun announce(detections: List<Detection>) {
        if (!enabled.value || !ready) return

        val now = SystemClock.elapsedRealtime()
        inView = detections.mapTo(HashSet()) { it.className }

        // Rule: minimum 1s between announcement cycles
        if (now - lastAnnouncementTime < ANNOUNCEMENT_INTERVAL_MS) return
        // Rule: never interrupt current speech or a draining queue
        if (isSpeaking || isProcessingQueue || now < screenReaderBusyUntil) return

        val ordered = AnnouncementRules.centralFirst(detections.map {
            AnnouncementRules.Seen(it.className, it.rect.centerX(), it.rect.centerY(), it.rect.width() * it.rect.height())
        })
        val toAnnounce = ArrayList<Pair<String, String>>()
        for (exactName in ordered) {
            if (toAnnounce.size >= MAX_PER_CYCLE) break
            val lastSpoken = lastSpokenByClass[exactName] ?: 0L
            if (now - lastSpoken >= CLASS_COOLDOWN_MS) {
                // Name only, no confidence, and without label notes: "Bat (Animal)"
                // is said "bat" (iOS SpeechManager, 2026-09-16).
                val spoken = try { SpeakableText.className(exactName) } catch (t: Throwable) { exactName.lowercase() }
                toAnnounce.add(exactName to spoken)
                lastSpokenByClass[exactName] = now
            }
        }

        lastAnnouncementTime = now

        if (toAnnounce.isNotEmpty()) {
            if (!speaksAloud) {
                // TalkBack gets the cycle as one line; announcing each name as it
                // came made every announcement interrupt the one before it.
                val line = toAnnounce.joinToString(", ") { it.second }
                screenReaderBusyUntil = now + AnnouncementRules.estimatedMs(line)
                announceToScreenReader(line)
            } else {
                mainHandler.post {
                    announcementQueue.clear()
                    announcementQueue.addAll(toAnnounce)
                    processNextInQueue()
                }
            }
        }

        // Rule: clean up per-class entries older than 60s
        lastSpokenByClass.entries.removeAll { now - it.value > CLEANUP_AGE_MS }
    }

    private fun processNextInQueue() {
        // Drop names whose object has already left the picture.
        while (announcementQueue.isNotEmpty() && !inView.contains(announcementQueue.first().first)) {
            val gone = announcementQueue.removeFirst()
            lastSpokenByClass.remove(gone.first) // unsaid, so it may be said when it comes back
        }
        if (announcementQueue.isEmpty() || isSpeaking || !enabled.value) {
            if (announcementQueue.isEmpty()) isProcessingQueue = false
            return
        }
        isProcessingQueue = true
        val next = announcementQueue.removeFirst()
        speakInternal(next.second, "announce-${utteranceSeq++}")
    }

    /**
     * iOS speak(_:): interrupting speech for read text, summaries, welcome lines.
     * Says numbers and addresses the way a person would ("three ninety-three
     * Westgate Drive", phone numbers digit by digit, card numbers only by their
     * last four). What's on screen and what gets copied stay as read. The same
     * rewrite reaches TalkBack when the app is set not to speak aloud.
     */
    /**
     * Say a short line and return only once it has been heard. The countdown
     * uses this: each word used to flush the one before it, and on a slow phone
     * the engine was still starting "three" when "two" arrived, so people heard
     * only "one". Also waits for the engine itself, which is still starting up
     * when the screen has just opened.
     */
    /**
     * Get the voice ready before a countdown: wait for the engine to finish starting
     * (it is still starting when a screen has just opened, and speakAndWait gives up
     * on a line after 3 s, so "three" was dropped), then play a short silence so the
     * audio output is awake. On a cold speaker the first ~300 ms of sound is lost, which
     * also clipped "three" (Matt, 2026-09-27: "it only said 2 1").
     */
    private fun warmVoice() {
        val mute = android.os.Bundle().apply { putFloat(TextToSpeech.Engine.KEY_PARAM_VOLUME, 0f) }
        try { tts.speak("one", TextToSpeech.QUEUE_ADD, mute, "warm-init") } catch (_: Throwable) {}
    }

    suspend fun prepareToSpeak(timeoutMs: Long = 8000) {
        val start = SystemClock.elapsedRealtime()
        while (!ready && SystemClock.elapsedRealtime() - start < timeoutMs) kotlinx.coroutines.delay(50)
        if (!ready || !speaksAloud) return
        // "ready" only means the engine is bound. The voice itself loads on the first real
        // synthesis (about a second, longer after Android frees it for memory), and while it
        // loaded, "two" flushed "three" before it was ever heard. So synthesise a word at zero
        // volume first, wait for it to finish, then a short silence to wake the speaker.
        val warm = "warm-${utteranceSeq++}"
        val mute = android.os.Bundle().apply { putFloat(TextToSpeech.Engine.KEY_PARAM_VOLUME, 0f) }
        tts.speak("three", TextToSpeech.QUEUE_FLUSH, mute, warm)
        while (lastFinishedId != warm && SystemClock.elapsedRealtime() - start < timeoutMs) {
            kotlinx.coroutines.delay(20)
        }
        val id = "wake-${utteranceSeq++}"
        tts.playSilentUtterance(300, TextToSpeech.QUEUE_ADD, id)
        while (lastFinishedId != id && SystemClock.elapsedRealtime() - start < timeoutMs) {
            kotlinx.coroutines.delay(20)
        }
    }

    suspend fun speakAndWait(text: String, timeoutMs: Long = 3000) {
        val start = SystemClock.elapsedRealtime()
        while (!ready && SystemClock.elapsedRealtime() - start < timeoutMs) kotlinx.coroutines.delay(50)
        if (!ready) return
        val id = "wait-${utteranceSeq++}"
        speakInternal(text, id)
        if (!speaksAloud) return  // TalkBack says it; no callback to wait for
        while (lastFinishedId != id && SystemClock.elapsedRealtime() - start < timeoutMs) {
            kotlinx.coroutines.delay(30)
        }
    }

    fun speak(text: String) {
        announcementQueue.clear()
        isProcessingQueue = false
        // Never let a text rewrite cost the person their speech: if a pattern
        // misbehaves on some device, say the text as read.
        val spoken = try { SpeakableText.make(text) } catch (t: Throwable) { text }
        if (spoken.isBlank()) return
        sayOrHold(spoken, "speak-${utteranceSeq++}")
    }

    /** Speak now if the engine is up; otherwise keep the latest line and say it when it is. */
    private fun sayOrHold(text: String, id: String) {
        when {
            ready -> speakInternal(text, id)
            engineFailed || !speaksAloud -> announceToScreenReader(text)
            else -> pendingLine = text to id
        }
    }

    /**
     * Off means the app stays quiet and hands the line to TalkBack instead.
     * Asked for on AppleVis by Cash (2026-09-12): with a screen reader running,
     * the app's own voice and the reader talk over each other, and the person
     * who needs it most hears two voices at once.
     */
    private val speaksAloud: Boolean
        get() = appContext.getSharedPreferences("rtcam", Context.MODE_PRIVATE)
            .getBoolean("speakAnswersAloud", true)

    private fun speakInternal(text: String, id: String) {
        // Debug builds log every spoken line so a cable test can read what was said.
        if ((appContext.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0) android.util.Log.d("RTCamSpeech", text)
        if (!speaksAloud || engineFailed) {
            // TalkBack reads this in the user's OWN voice and rate, which is the
            // whole point of the setting. Also the fallback when no speech engine works.
            announceToScreenReader(text)
            return
        }
        // Honor the Home-screen voice selection (persisted)
        val wanted = com.mattmacosko.realtimeaicam.ui.VoicePrefs.get(appContext)
        if (wanted != null && wanted != appliedVoice) {
            com.mattmacosko.realtimeaicam.ui.VoicePrefs.apply(appContext, tts)
            appliedVoice = wanted
        }
        tts.speak(text, TextToSpeech.QUEUE_FLUSH, null, id)
    }

    /**
     * iOS stopSpeech(): immediate stop, clear queue, reset cycle timer, and
     * force-disable speech (exactly like iOS — prevents late callbacks from
     * speaking again). Called on camera flip, Back navigation, mode changes.
     */
    private fun announceToScreenReader(text: String) {
        val am = appContext.getSystemService(Context.ACCESSIBILITY_SERVICE) as? AccessibilityManager
        if (am == null || !am.isEnabled) return
        val event = AccessibilityEvent.obtain(AccessibilityEvent.TYPE_ANNOUNCEMENT)
        event.className = SpeechAnnouncer::class.java.name
        event.packageName = appContext.packageName
        event.text.add(text)
        am.sendAccessibilityEvent(event)
    }

    fun stop() {
        pendingLine = null
        tts.stop()
        isSpeaking = false
        speakingNow.value = false
        isProcessingQueue = false
        announcementQueue.clear()
        lastAnnouncementTime = 0L
        screenReaderBusyUntil = 0L
        enabled.value = false
    }

    /** iOS resetSpeechState(): also clears the per-class cooldowns. */
    fun resetState() {
        stop()
        lastSpokenByClass.clear()
    }

    fun shutdown() {
        stop()
        tts.shutdown()
    }
}

/** The pure parts of the announcement rules, kept apart so they can be unit tested. */
object AnnouncementRules {
    data class Seen(val className: String, val centerX: Float, val centerY: Float, val area: Float)

    /** Distinct class names, the one nearest the frame centre first, ties to the bigger box. */
    fun centralFirst(seen: List<Seen>): List<String> =
        seen.sortedWith(
            compareBy<Seen> { (it.centerX - 0.5f) * (it.centerX - 0.5f) + (it.centerY - 0.5f) * (it.centerY - 0.5f) }
                .thenByDescending { it.area }
        ).map { it.className }.distinct()

    /** Rough time a screen reader takes to say [line]. */
    fun estimatedMs(line: String): Long = 400L + 70L * line.length
}
