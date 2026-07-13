package com.mattmacosko.realtimeaicam.camera

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import com.mattmacosko.realtimeaicam.detection.Detection
import kotlinx.coroutines.flow.MutableStateFlow

/**
 * Faithful port of the iOS SpeechManager announcement rulebook
 * (project 601/SpeechManager.swift). The exact rules and numbers:
 *
 *  - announcementInterval = 1.0s   minimum gap between announcement CYCLES
 *  - classCooldown        = 45.0s  per EXACT class name repeat cooldown
 *  - interObjectDelay     = 0.8s   pause between queued objects
 *  - never process a cycle while speaking or while the queue is draining
 *  - all qualifying detections in one cycle are queued and spoken in order
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
    private var ready = false
    private var appliedVoice: String? = null

    @Volatile private var isSpeaking = false
    @Volatile private var isProcessingQueue = false
    private val announcementQueue = ArrayDeque<String>()
    private var lastAnnouncementTime = 0L
    private val lastSpokenByClass = HashMap<String, Long>()
    private var utteranceSeq = 0L

    private val tts = TextToSpeech(context.applicationContext) { status ->
        ready = status == TextToSpeech.SUCCESS
    }.apply {
        setOnUtteranceProgressListener(object : UtteranceProgressListener() {
            override fun onStart(utteranceId: String?) {
                this@SpeechAnnouncer.isSpeaking = true
                speakingNow.value = true
            }

            override fun onDone(utteranceId: String?) {
                this@SpeechAnnouncer.isSpeaking = false
                speakingNow.value = false
                // iOS: schedule next queued object after interObjectDelay
                if (utteranceId?.startsWith("announce-") == true) {
                    mainHandler.postDelayed({ processNextInQueue() }, INTER_OBJECT_DELAY_MS)
                }
            }

            @Deprecated("Deprecated in Java")
            override fun onError(utteranceId: String?) {
                this@SpeechAnnouncer.isSpeaking = false
                speakingNow.value = false
                isProcessingQueue = false
            }

            override fun onStop(utteranceId: String?, interrupted: Boolean) {
                this@SpeechAnnouncer.isSpeaking = false
                speakingNow.value = false
            }
        })
    }

    /** iOS setSpeechEnabled/handleToggleSpeech behavior. */
    fun setEnabled(on: Boolean) {
        if (on == enabled.value) return
        if (on) {
            enabled.value = true
            // iOS announceSpeechEnabled(): clears queue, speaks confirmation
            announcementQueue.clear()
            isProcessingQueue = false
            speakInternal("Speech enabled", "toggle-${utteranceSeq++}")
        } else {
            stop() // also sets enabled=false, like iOS stopSpeech()
        }
    }

    /** iOS processDetectionsForSpeech — called once per processed frame. */
    fun announce(detections: List<Detection>) {
        if (!enabled.value || !ready) return

        val now = SystemClock.elapsedRealtime()

        // Rule: minimum 1s between announcement cycles
        if (now - lastAnnouncementTime < ANNOUNCEMENT_INTERVAL_MS) return
        // Rule: never interrupt current speech or a draining queue
        if (isSpeaking || isProcessingQueue) return

        val toAnnounce = ArrayList<String>()
        for (detection in detections) {
            val exactName = detection.className // exact name, no normalization
            val lastSpoken = lastSpokenByClass[exactName] ?: 0L
            if (now - lastSpoken >= CLASS_COOLDOWN_MS) {
                toAnnounce.add(exactName.lowercase()) // name only, no confidence
                lastSpokenByClass[exactName] = now
            }
        }

        lastAnnouncementTime = now

        if (toAnnounce.isNotEmpty()) {
            announcementQueue.clear()
            announcementQueue.addAll(toAnnounce)
            processNextInQueue()
        }

        // Rule: clean up per-class entries older than 60s
        lastSpokenByClass.entries.removeAll { now - it.value > CLEANUP_AGE_MS }
    }

    private fun processNextInQueue() {
        if (announcementQueue.isEmpty() || isSpeaking || !enabled.value) {
            if (announcementQueue.isEmpty()) isProcessingQueue = false
            return
        }
        isProcessingQueue = true
        val next = announcementQueue.removeFirst()
        speakInternal(next, "announce-${utteranceSeq++}")
    }

    /** iOS speak(_:): interrupting speech for welcome lines etc. */
    fun speak(text: String) {
        if (!ready) return
        announcementQueue.clear()
        isProcessingQueue = false
        speakInternal(text, "speak-${utteranceSeq++}")
    }

    private fun speakInternal(text: String, id: String) {
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
    fun stop() {
        tts.stop()
        isSpeaking = false
        speakingNow.value = false
        isProcessingQueue = false
        announcementQueue.clear()
        lastAnnouncementTime = 0L
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
