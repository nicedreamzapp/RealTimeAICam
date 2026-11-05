package com.mattmacosko.realtimeaicam.camera

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioManager
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
 * Why the app's voice can't be heard right now, for the banner on each camera screen
 * (2026-11-04, Play review: "no voice output, complete silence").
 */
enum class SpeechProblem {
    /** The volume of the stream the app's voice plays on is at 0. */
    VOLUME_OFF,
    /** No text-to-speech engine started (none installed, or it never answered). */
    NO_ENGINE,
    /** The engine started but has no voice it can use (language data missing). */
    NO_VOICE,
    /** Your language is set but the phone has no voice for it; English is spoken meanwhile. */
    NO_LANGUAGE_VOICE,
}

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
        const val YL_EN = "en"
        const val ANNOUNCEMENT_INTERVAL_MS = 1_000L
        const val CLASS_COOLDOWN_MS = 45_000L
        const val INTER_OBJECT_DELAY_MS = 800L
        const val CLEANUP_AGE_MS = 60_000L
        const val MAX_PER_CYCLE = 3
        const val GOOGLE_TTS = "com.google.android.tts"
        /** An engine that hasn't answered by then is treated as missing (banner + TalkBack). */
        const val ENGINE_START_LIMIT_MS = 8_000L
    }

    /**
     * What stands between the app's voice and the person's ears, or null when nothing does.
     * Shown as a banner by [com.mattmacosko.realtimeaicam.ui.SpeechProblemBanner].
     */
    val problem = MutableStateFlow<SpeechProblem?>(null)

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
    /** The engine started but couldn't get a usable voice (setLanguage failed, voice data missing). */
    @Volatile private var voiceFailed = false
    /** The engine hasn't answered within [ENGINE_START_LIMIT_MS]; lines go to TalkBack meanwhile. */
    @Volatile private var engineSlow = false
    private var triedGoogleEngine = false
    private var volumeWasOff = false
    /** Last line handed to the engine, so an engine error can still reach TalkBack. */
    @Volatile private var lastLine: Pair<String, String>? = null

    /**
     * Your language (2026-11-04). When set (not English), [speak] translates each English line
     * into it before saying it, in a voice for that language. Help Me Aim and What's this? set
     * this; Read and Object Detection pass the language per line instead.
     */
    @Volatile var localizeTo: String? = null
    /** Object Detection: English class name -> the name to say, in [namesLanguage]. */
    @Volatile var nameFor: ((String) -> String?)? = null
    @Volatile var namesLanguage: String = YL_EN
    /** Language of each utterance id still to be spoken (English when absent). */
    private val utteranceLanguage = java.util.concurrent.ConcurrentHashMap<String, String>()
    /** Your language with no voice on the phone: the banner names it. */
    val missingVoiceLanguage = MutableStateFlow<String?>(null)
    private var noVoiceSaid = false
    private var englishVoice: android.speech.tts.Voice? = null
    @Volatile private var speakSeq = 0L

    /**
     * The voice plays as accessibility speech (2026-11-04). On media volume, which many TalkBack
     * users keep at 0, the app was silent. With TalkBack on this follows TalkBack's own volume;
     * with it off Android routes it with media volume, which [checkVolume] watches.
     */
    private val speechAttributes: AudioAttributes = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_ASSISTANCE_ACCESSIBILITY)
        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
        .build()

    /** The app's own voice can't be used right now; send lines to TalkBack instead. */
    private val voiceUnavailable: Boolean
        get() = engineFailed || voiceFailed || (!ready && engineSlow)

    private fun createEngine(enginePackage: String?): TextToSpeech {
        val holder = arrayOfNulls<TextToSpeech>(1)
        val onInit = TextToSpeech.OnInitListener { status ->
            mainHandler.post { onEngineInit(holder[0], status) }
        }
        val engine = if (enginePackage == null) TextToSpeech(appContext, onInit)
        else TextToSpeech(appContext, onInit, enginePackage)
        holder[0] = engine
        try { engine.setAudioAttributes(speechAttributes) } catch (_: Throwable) {}
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
            updateProblem()
            return
        }
        ensureLanguage(engine)
        ready = true
        engineSlow = false
        updateProblem()
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

    /**
     * No voice data for the phone's language (or none picked yet): fall back to US English.
     * If that fails too, the engine can't say anything: lines go to TalkBack and the banner
     * offers the phone's text-to-speech settings, where a voice can be downloaded.
     */
    private fun ensureLanguage(engine: TextToSpeech) {
        voiceFailed = try {
            val current = engine.voice?.locale ?: java.util.Locale.getDefault()
            val ok = engine.isLanguageAvailable(current) >= TextToSpeech.LANG_AVAILABLE &&
                engine.voice?.features?.contains(TextToSpeech.Engine.KEY_FEATURE_NOT_INSTALLED) != true
            if (ok) false else !SpeechChecks.languageUsable(engine.setLanguage(java.util.Locale.US))
        } catch (_: Throwable) { false }
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
                // A result read aloud to the end: the one success moment for the rating card.
                if (utteranceId?.startsWith("result-") == true) {
                    mainHandler.post { com.mattmacosko.realtimeaicam.RatePrompt.noteResultSpoken(appContext) }
                }
                // iOS: schedule next queued object after interObjectDelay
                if (utteranceId?.startsWith("announce-") == true) {
                    mainHandler.postDelayed({ processNextInQueue() }, INTER_OBJECT_DELAY_MS)
                }
            }

            @Deprecated("Deprecated in Java")
            override fun onError(utteranceId: String?) {
                onUtteranceError(utteranceId, TextToSpeech.ERROR)
            }

            override fun onError(utteranceId: String?, errorCode: Int) {
                onUtteranceError(utteranceId, errorCode)
            }

            override fun onStop(utteranceId: String?, interrupted: Boolean) {
                lastFinishedId = utteranceId
                this@SpeechAnnouncer.isSpeaking = false
                speakingNow.value = false
            }
        }
    }

    /**
     * The engine couldn't say a line (no voice data, output failed, service died). Before
     * 2026-11-04 only the old one-argument onError was handled and the line just vanished.
     * Now the line still reaches TalkBack, and a missing voice raises the banner.
     */
    private fun onUtteranceError(utteranceId: String?, errorCode: Int) {
        lastFinishedId = utteranceId
        isSpeaking = false
        speakingNow.value = false
        isProcessingQueue = false
        android.util.Log.w("RTCamSpeech", "speech error $errorCode on $utteranceId")
        if (utteranceId == null || utteranceId.startsWith("warm") || utteranceId.startsWith("wake")) return
        mainHandler.post {
            if (SpeechChecks.meansNoVoice(errorCode)) {
                voiceFailed = true
                updateProblem()
            }
            val line = lastLine
            if (line != null && line.second == utteranceId) announceToScreenReader(line.first)
        }
    }

    // Declared after progressListener: createEngine() reads it while this initialises.
    private var tts: TextToSpeech = createEngine(null)

    init {
        // An engine that never answers used to leave the app waiting in silence forever.
        mainHandler.postDelayed({
            if (!ready && !engineFailed) {
                engineSlow = true
                pendingLine?.let { announceToScreenReader(it.first) }
                pendingLine = null
                updateProblem()
            }
        }, ENGINE_START_LIMIT_MS)
        mainHandler.post { checkVolume() }
    }

    /**
     * Re-check the volume (the camera screens call this about once a second while shown).
     * When the speech stream is at 0 the banner shows, and TalkBack says so once, since the
     * app's own voice can't be heard.
     */
    fun checkVolume() {
        val off = SpeechChecks.volumeOff(speaksAloud, currentSpeechVolume())
        if (off && !volumeWasOff) announceToScreenReader(SpeechChecks.VOLUME_OFF_LINE)
        volumeWasOff = off
        updateProblem()
    }

    /** Volume of the stream the app's voice is heard on: TalkBack's when it runs, else media. */
    private fun currentSpeechVolume(): Int? = try {
        val audio = appContext.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
        val stream = if (screenReaderOn()) AudioManager.STREAM_ACCESSIBILITY else AudioManager.STREAM_MUSIC
        audio?.getStreamVolume(stream)
    } catch (_: Throwable) { null }

    private fun updateProblem() {
        problem.value = SpeechChecks.problem(
            speaksAloud = speaksAloud,
            engineFailed = engineFailed || (!ready && engineSlow),
            voiceFailed = voiceFailed,
            volumeOff = volumeWasOff,
        ) ?: if (speaksAloud && missingVoiceLanguage.value != null) SpeechProblem.NO_LANGUAGE_VOICE else null
    }

    /**
     * The best voice the phone has for [lang] that works offline and is installed, or null.
     * Null too while the engine is still starting (callers then assume one exists).
     */
    private fun voiceFor(lang: String): android.speech.tts.Voice? = try {
        val want = java.util.Locale(lang).language
        tts.voices.orEmpty()
            .filter {
                (it.locale.language == want || com.mattmacosko.realtimeaicam.translation.YourLanguageRules.normalize(it.locale.language) == lang) &&
                    !it.isNetworkConnectionRequired &&
                    it.features?.contains(TextToSpeech.Engine.KEY_FEATURE_NOT_INSTALLED) != true
            }
            .sortedWith(compareByDescending<android.speech.tts.Voice> { it.quality }.thenBy { it.name })
            .firstOrNull()
    } catch (_: Throwable) { null }

    /** True when [lang] can be said aloud (or goes to TalkBack, which has its own voices). */
    fun canSpeak(lang: String): Boolean {
        if (lang == YL_EN || !speaksAloud || !ready) return true
        return voiceFor(lang) != null
    }

    /**
     * The language to speak results in right now: Your language when its pack is on the phone
     * and there is a voice for it, otherwise English (exactly today's behaviour). With no voice,
     * says so once in English and shows the speech-settings button.
     */
    fun outputLanguage(): String {
        val lang = com.mattmacosko.realtimeaicam.translation.YourLanguage.active(appContext)
        if (lang == YL_EN) { if (missingVoiceLanguage.value != null) { missingVoiceLanguage.value = null; updateProblem() }; return YL_EN }
        if (canSpeak(lang)) { if (missingVoiceLanguage.value != null) { missingVoiceLanguage.value = null; updateProblem() }; return lang }
        if (missingVoiceLanguage.value != lang) { missingVoiceLanguage.value = lang; updateProblem() }
        if (!noVoiceSaid) {
            noVoiceSaid = true
            val line = com.mattmacosko.realtimeaicam.translation.YourLanguageRules.noVoiceLine(lang)
            android.util.Log.i("RTCamSpeech", "no voice for $lang")
            mainHandler.post { sayOrHold(line, "speak-${utteranceSeq++}") }
        }
        return YL_EN
    }

    private fun screenReaderOn(): Boolean = UiCue.screenReaderOn(appContext)

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
        if (!enabled.value) return
        // The voice isn't up yet: with TalkBack on, names go to TalkBack instead of waiting in
        // silence (2026-11-04). With nobody to hear them, wait as before so no name is used up.
        val viaVoice = speaksAloud && !voiceUnavailable
        if (viaVoice && !ready) return
        if (!viaVoice && speaksAloud && !screenReaderOn()) return

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
                val spoken = nameFor?.invoke(exactName)
                    ?: try { SpeakableText.className(exactName) } catch (t: Throwable) { exactName.lowercase() }
                toAnnounce.add(exactName to spoken)
                lastSpokenByClass[exactName] = now
            }
        }

        lastAnnouncementTime = now

        if (toAnnounce.isNotEmpty()) {
            if (!viaVoice) {
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
        val id = "announce-${utteranceSeq++}"
        if (nameFor != null && namesLanguage != YL_EN) utteranceLanguage[id] = namesLanguage
        speakInternal(next.second, id)
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
        while (!ready && !voiceUnavailable && SystemClock.elapsedRealtime() - start < timeoutMs) kotlinx.coroutines.delay(50)
        if (!ready || !speaksAloud || voiceUnavailable) return
        // "ready only means the engine is bound. The voice itself loads on the first real
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
        while (!ready && !voiceUnavailable && SystemClock.elapsedRealtime() - start < timeoutMs) kotlinx.coroutines.delay(50)
        if (!ready || voiceUnavailable) {
            // The countdown used to give up here in silence. TalkBack says it instead.
            announceToScreenReader(text)
            return
        }
        val id = "wait-${utteranceSeq++}"
        val lang = localizeTarget()
        if (lang != YL_EN) {
            val said = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                com.mattmacosko.realtimeaicam.translation.YourLanguage.translateBlocking(text, YL_EN, lang)
            }
            if (said != null) utteranceLanguage[id] = lang
            speakInternal(said ?: text, id)
        } else {
            speakInternal(text, id)
        }
        if (!speaksAloud) return  // TalkBack says it; no callback to wait for
        while (lastFinishedId != id && SystemClock.elapsedRealtime() - start < timeoutMs) {
            kotlinx.coroutines.delay(30)
        }
    }

    fun speak(text: String) = speakLine(text, result = false)

    /**
     * A short screen cue, said once ([UiCue]): TalkBack announces it when TalkBack is on, the
     * app's voice says it when it is off (2026-11-04: "Live Cam is coming soon" was heard twice).
     */
    fun cue(text: String) {
        // Your language (11/04 review): the cue is put into it first when its pack is on the
        // phone, and said in that language; otherwise English, as everywhere else.
        val lang = com.mattmacosko.realtimeaicam.translation.YourLanguage.active(appContext)
        if (lang == YL_EN) { cueIn(text, YL_EN); return }
        val mine = ++cueSeq
        com.mattmacosko.realtimeaicam.translation.YourLanguage.translateAsync(text, YL_EN, lang) { said ->
            if (mine != cueSeq) return@translateAsync
            if (said.isNullOrBlank()) cueIn(text, YL_EN) else cueIn(said, lang)
        }
    }

    @Volatile private var cueSeq = 0L

    private fun cueIn(text: String, lang: String) {
        when (UiCue.route(UiCue.screenReaderOn(appContext))) {
            UiCue.Route.SCREEN_READER -> {
                if (debuggable) android.util.Log.i("RTCamSpeech", "via TalkBack: $text")
                announceToScreenReader(text)
            }
            UiCue.Route.APP_VOICE -> speakIn(text, lang)
        }
    }

    private val debuggable: Boolean
        get() = (appContext.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0

    /**
     * A result (a read page, a translation, an answer, a description). Same as [speak], but when
     * the voice finishes it to the end it counts as a success for the rating card.
     */
    fun speakResult(text: String) = speakLine(text, result = true)

    /**
     * Say text that is already in [lang] (Read output, translated answers), in a voice for it.
     * English goes through the usual number/address rewrite; other languages only lose markdown.
     */
    fun speakIn(text: String, lang: String, result: Boolean = false) {
        if (lang == YL_EN) { speakLine(text, result, localize = false); return }
        announcementQueue.clear()
        isProcessingQueue = false
        speakSeq++
        val spoken = try { SpeakableText.stripFormatting(text) } catch (t: Throwable) { text }
        if (spoken.isBlank()) return
        val id = "${if (result) "result" else "speak"}-${utteranceSeq++}"
        utteranceLanguage[id] = lang
        sayOrHold(spoken, id)
    }

    /** Your language for [speak]'s English lines on this screen, or English. */
    private fun localizeTarget(): String {
        val to = localizeTo ?: return YL_EN
        if (to == YL_EN) return YL_EN
        return outputLanguage()
    }

    private fun speakLine(text: String, result: Boolean, localize: Boolean = true) {
        announcementQueue.clear()
        isProcessingQueue = false
        val lang = if (localize) localizeTarget() else YL_EN
        val prefix = if (result) "result" else "speak"
        if (lang != YL_EN) {
            // Translate first (a few ms once the pack is loaded), then say it, unless a newer line
            // was asked for meanwhile: the same "the latest line wins" as QUEUE_FLUSH.
            val mine = ++speakSeq
            com.mattmacosko.realtimeaicam.translation.YourLanguage.translateAsync(text, YL_EN, lang) { said ->
                if (mine != speakSeq) return@translateAsync
                if (said == null) { speakEnglish(text, prefix); return@translateAsync }
                val clean = try { SpeakableText.stripFormatting(said) } catch (t: Throwable) { said }
                if (clean.isBlank()) return@translateAsync
                val id = "$prefix-${utteranceSeq++}"
                utteranceLanguage[id] = lang
                sayOrHold(clean, id)
            }
            return
        }
        speakSeq++
        speakEnglish(text, prefix)
    }

    private fun speakEnglish(text: String, prefix: String) {
        // Never let a text rewrite cost the person their speech: if a pattern
        // misbehaves on some device, say the text as read.
        val spoken = try { SpeakableText.make(text) } catch (t: Throwable) { text }
        if (spoken.isBlank()) return
        sayOrHold(spoken, "$prefix-${utteranceSeq++}")
    }

    /** Speak now if the engine is up; otherwise keep the latest line and say it when it is. */
    private fun sayOrHold(text: String, id: String) {
        when {
            ready -> speakInternal(text, id)
            voiceUnavailable || !speaksAloud -> announceToScreenReader(text)
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
        val lang = utteranceLanguage.remove(id) ?: YL_EN
        if (!speaksAloud || voiceUnavailable) {
            // Debug builds log each line by the way it was said: a TalkBack line logged as the
            // app's voice read as the same words said twice (first-time-user test, 2026-11-04).
            if (debuggable) android.util.Log.i("RTCamSpeech", "via TalkBack: $text")
            // TalkBack reads this in the user's OWN voice and rate, which is the
            // whole point of the setting. Also the fallback when no speech engine works.
            announceToScreenReader(text)
            if (id.startsWith("result-")) {
                // No "done" from TalkBack: count it once it has had time to be heard.
                mainHandler.postDelayed({ com.mattmacosko.realtimeaicam.RatePrompt.noteResultSpoken(appContext) },
                    AnnouncementRules.estimatedMs(text))
            }
            return
        }
        if (lang != YL_EN) {
            // Your language: a voice for it (the Home voice picker lists English voices only).
            val v = voiceFor(lang)
            if (v != null && tts.voice?.name != v.name) {
                if (englishVoice == null) englishVoice = tts.voice
                try { tts.voice = v } catch (_: Throwable) {}
                appliedVoice = null
            }
            if (v == null) outputLanguage() // says once that no voice is installed
            android.util.Log.i("RTCamSpeech", "[$lang] voice=${v?.name}")
        } else {
            // Honor the Home-screen voice selection (persisted)
            val wanted = com.mattmacosko.realtimeaicam.ui.VoicePrefs.get(appContext)
            if (wanted != null && wanted != appliedVoice) {
                com.mattmacosko.realtimeaicam.ui.VoicePrefs.apply(appContext, tts)
                appliedVoice = wanted
            } else if (wanted == null && englishVoice != null && tts.voice?.locale?.language != YL_EN) {
                try { tts.voice = englishVoice } catch (_: Throwable) {}
            }
        }
        lastLine = text to id
        // Debug builds log every line handed to the app's voice, so a cable test can read it
        // (lines sent to TalkBack are logged as "via TalkBack" instead, at info level).
        if (debuggable) android.util.Log.d("RTCamSpeech", text)
        if (tts.speak(text, TextToSpeech.QUEUE_FLUSH, null, id) == TextToSpeech.ERROR) {
            // Refused outright (engine died, bad state): don't let the line vanish.
            announceToScreenReader(text)
        }
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
        speakSeq++ // a line still being translated is not said after a stop
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

/** The pure parts of the "can the voice be heard" checks, kept apart so they can be unit tested. */
object SpeechChecks {
    const val VOLUME_OFF_LINE = "Volume is off. Turn it up to hear the app."

    /** setLanguage's answer means a voice will actually speak. */
    fun languageUsable(result: Int): Boolean = result >= TextToSpeech.LANG_AVAILABLE

    /** Engine error codes that mean no usable voice is installed. */
    fun meansNoVoice(errorCode: Int): Boolean = errorCode == TextToSpeech.ERROR_NOT_INSTALLED_YET

    /** Only the app's own voice is affected by its volume; TalkBack users get TalkBack's. */
    fun volumeOff(speaksAloud: Boolean, volume: Int?): Boolean = speaksAloud && volume == 0

    /** Most important first: no engine, then no voice, then volume. */
    fun problem(speaksAloud: Boolean, engineFailed: Boolean, voiceFailed: Boolean, volumeOff: Boolean): SpeechProblem? = when {
        !speaksAloud -> null
        engineFailed -> SpeechProblem.NO_ENGINE
        voiceFailed -> SpeechProblem.NO_VOICE
        volumeOff -> SpeechProblem.VOLUME_OFF
        else -> null
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
