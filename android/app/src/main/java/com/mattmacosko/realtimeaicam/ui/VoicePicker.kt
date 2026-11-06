package com.mattmacosko.realtimeaicam.ui

import androidx.compose.ui.semantics.clearAndSetSemantics
import android.content.Context
import android.speech.tts.TextToSpeech
import android.speech.tts.Voice
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.res.stringResource
import com.mattmacosko.realtimeaicam.R
import java.util.Locale

/** Persisted voice selection shared by every TTS instance in the app. */
object VoicePrefs {
    const val KEY = "selectedVoice"
    private const val KEY_DISPLAY = "selectedVoiceDisplay"
    private const val KEY_EMOJI = "selectedVoiceEmoji"

    fun get(context: Context): String? =
        context.getSharedPreferences("rtaicam", Context.MODE_PRIVATE).getString(KEY, null)

    /**
     * Synchronously restores the persisted selection (name + label) so the
     * Home pill shows the right voice immediately, before TTS init finishes.
     */
    fun getOption(context: Context): VoiceOption? {
        val prefs = context.getSharedPreferences("rtaicam", Context.MODE_PRIVATE)
        val name = prefs.getString(KEY, null) ?: return null
        val display = prefs.getString(KEY_DISPLAY, null) ?: return null
        return VoiceOption(
            voiceName = name,
            display = display,
            emoji = prefs.getString(KEY_EMOJI, null) ?: "🧑",
            enhanced = false,
        )
    }

    fun set(context: Context, option: VoiceOption) {
        context.getSharedPreferences("rtaicam", Context.MODE_PRIVATE)
            .edit()
            .putString(KEY, option.voiceName)
            .putString(KEY_DISPLAY, option.display)
            .putString(KEY_EMOJI, option.emoji)
            .apply()
    }

    /**
     * The voice for speaking [lang] on [tts] (2026-11-05): the picked voice when it speaks
     * [lang]; else the engine's current voice when that one does; else the best installed voice
     * for [lang]; else the engine's own voice for that language. Never a voice of another
     * language (a Spanish line in an English voice, or the reverse).
     */
    fun applyFor(context: Context, tts: TextToSpeech, lang: String) {
        try {
            val all = tts.voices.orEmpty()
            val picked = get(context)?.let { n -> all.firstOrNull { it.name == n } }
            if (picked != null && com.mattmacosko.realtimeaicam.camera.SpeechVoices.speaks(picked.locale.language, lang)) {
                if (tts.voice?.name != picked.name) tts.voice = picked
                return
            }
            if (com.mattmacosko.realtimeaicam.camera.SpeechVoices.speaks(tts.voice?.locale?.language, lang)) return
            val best = all
                .filter {
                    com.mattmacosko.realtimeaicam.camera.SpeechVoices.speaks(it.locale.language, lang) &&
                        !it.isNetworkConnectionRequired &&
                        it.features?.contains(TextToSpeech.Engine.KEY_FEATURE_NOT_INSTALLED) != true
                }
                .sortedWith(compareByDescending<Voice> { it.quality }.thenBy { it.name })
                .firstOrNull()
            if (best != null) tts.voice = best else tts.setLanguage(Locale.forLanguageTag(lang))
        } catch (_: Throwable) {
            // Some engines throw on .voices: keep the engine's voice.
        }
    }

    /** Applies the persisted voice to a TTS instance (no-op if unavailable). */
    fun apply(context: Context, tts: TextToSpeech) {
        val name = get(context) ?: return
        try {
            tts.voices?.firstOrNull { it.name == name }?.let { tts.voice = it }
        } catch (e: Exception) {
            // Some engines throw on .voices — ignore
        }
    }
}

data class VoiceOption(
    val voiceName: String,
    val display: String,
    val emoji: String,
    val enhanced: Boolean,
)

/**
 * Owns a TTS instance for the Home voice picker: lists the voices for the app's
 * language (English voices in English, Spanish voices in Spanish, 2026-11-05;
 * iOS §1.7/§1.8), tracks + persists the selection, speaks the iOS welcome line
 * on selection. The announcer uses the pick for lines in the pick's language.
 */
class VoicePickerModel(private val context: Context) {
    var voices by mutableStateOf<List<VoiceOption>>(emptyList())
        private set
    var selected by mutableStateOf<VoiceOption?>(null)
        private set

    private var tts: TextToSpeech? = null
    private var ttsReady = false
    /** The app language the list was made for. */
    private var lang: String = com.mattmacosko.realtimeaicam.AppLang.code()

    /** The app's language changed (Your language set to Spanish, or back): list its voices. */
    fun setLanguage(code: String) {
        if (code == lang) return
        lang = code
        if (ttsReady) loadVoices()
    }

    init {
        // Show the persisted voice immediately (TTS init can take seconds)
        selected = VoicePrefs.getOption(context)
        tts = TextToSpeech(context) { status ->
            if (status == TextToSpeech.SUCCESS) { ttsReady = true; loadVoices() }
        }
    }

    private fun voiceEmoji(v: Voice): String {
        val n = v.name.lowercase()
        return when {
            "female" in n || "#female" in n || Regex("-[a-z]{2}f-").containsMatchIn(n) -> "👩"
            "male" in n || Regex("-[a-z]{2}m-").containsMatchIn(n) -> "👨"
            else -> "🧑"
        }
    }

    private fun displayName(v: Voice, index: Int): String {
        val ui = Locale.forLanguageTag(lang)
        val base = v.locale.getDisplayName(ui).replaceFirstChar { it.titlecase(ui) }
            .replace("English (United States)", "English (US)")
            .replace("English (United Kingdom)", "English (UK)")
            .replace("Español (Estados Unidos)", "Español (EE. UU.)")
        val tag = if (v.quality >= Voice.QUALITY_HIGH) " " + com.mattmacosko.realtimeaicam.AppLang.str(com.mattmacosko.realtimeaicam.R.string.e_voice_enhanced_tag) else ""
        return "$base ${index + 1}$tag"
    }

    private fun loadVoices() {
        val t = tts ?: return
        val forLang = try {
            // Every English voice the phone has, best first. The .take(10) that
            // used to sit here meant any voice the user enabled AFTER install
            // sorted below the built-ins and fell off the end, so they could
            // never pick it. Reported by Joseph Weakland on AppleVis 2026-09-13
            // against the iPhone build, which had the same cap. The popup below
            // scrolls now, so a long list is a scroll, not unreachable buttons.
            t.voices.orEmpty()
                .filter {
                    com.mattmacosko.realtimeaicam.camera.SpeechVoices.speaks(it.locale.language, lang) &&
                        !it.isNetworkConnectionRequired
                }
                .sortedWith(compareByDescending<Voice> { it.quality }.thenBy { it.name })
        } catch (e: Exception) {
            emptyList()
        }
        var perLocale = HashMap<String, Int>()
        voices = forLang.map { v ->
            val idx = perLocale.getOrDefault(v.locale.toString(), 0)
            perLocale[v.locale.toString()] = idx + 1
            VoiceOption(
                voiceName = v.name,
                display = displayName(v, idx),
                emoji = voiceEmoji(v),
                enhanced = v.quality >= Voice.QUALITY_HIGH,
            )
        }
        val persisted = VoicePrefs.get(context)
        selected = voices.firstOrNull { it.voiceName == persisted } ?: voices.firstOrNull()
        // Migration: older builds persisted only the voice name — store the
        // label too so the next cold start shows it instantly.
        selected?.let { if (it.voiceName == persisted) VoicePrefs.set(context, it) }
    }

    fun select(option: VoiceOption) {
        selected = option
        VoicePrefs.set(context, option)
        val t = tts ?: return
        VoicePrefs.apply(context, t)
        // iOS playWelcomeMessage()
        t.speak(
            com.mattmacosko.realtimeaicam.AppLang.str(com.mattmacosko.realtimeaicam.R.string.e_voice_welcome),
            TextToSpeech.QUEUE_FLUSH, null, "welcome",
        )
    }

    fun shutdown() {
        tts?.stop()
        tts?.shutdown()
        tts = null
    }
}

@Composable
fun rememberVoicePickerModel(context: Context): VoicePickerModel {
    val model = remember { VoicePickerModel(context) }
    DisposableEffect(Unit) { onDispose { model.shutdown() } }
    // The context is re-made in the new language when the app's language changes.
    val lang = com.mattmacosko.realtimeaicam.AppLang.code()
    androidx.compose.runtime.LaunchedEffect(lang) { model.setLanguage(lang) }
    return model
}

/** Voice grid popup (spec §1.8): 2-column grid anchored above the pill. */
@Composable
fun VoiceGridPopup(
    model: VoicePickerModel,
    onDismiss: () -> Unit,
) {
    val closeListLabel = stringResource(R.string.e_voice_close_list_action)
    val closeList = stringResource(R.string.e_voice_close_list)
    val useVoice = stringResource(R.string.e_voice_use)
    val selectedWord = stringResource(R.string.e_selected)
    val notSelectedWord = stringResource(R.string.e_not_selected)
    // Full-screen scrim to dismiss on outside tap
    Box(
        Modifier
            .fillMaxSize()
            .clickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = null,
                onClickLabel = closeListLabel,
                onClick = onDismiss,
            )
            .semantics { contentDescription = closeList },
        contentAlignment = Alignment.BottomCenter,
    ) {
        Column(
            verticalArrangement = Arrangement.spacedBy(8.dp),
            modifier = Modifier
                .padding(bottom = 200.dp)
                .width(280.dp)
                .heightIn(max = 360.dp)
                .clip(RoundedCornerShape(12.dp))
                .background(Color.Black.copy(alpha = 0.85f), RoundedCornerShape(12.dp))
                .border(1.dp, IosColors.Purple.copy(alpha = 0.4f), RoundedCornerShape(12.dp))
                .clickable(
                    interactionSource = remember { MutableInteractionSource() },
                    indication = null,
                ) { /* consume */ }
                .verticalScroll(rememberScrollState())
                .padding(8.dp),
        ) {
            if (model.voices.isEmpty()) {
                Text(
                    stringResource(R.string.e_voice_none),
                    fontSize = 13.sp,
                    color = Color.White.copy(alpha = 0.7f),
                    textAlign = TextAlign.Center,
                    modifier = Modifier.padding(16.dp),
                )
            }
            model.voices.chunked(2).forEach { rowVoices ->
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    rowVoices.forEach { option ->
                        val isSelected = option.voiceName == model.selected?.voiceName
                        Column(
                            horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.spacedBy(4.dp),
                            modifier = Modifier
                                .weight(1f)
                                .clip(RoundedCornerShape(8.dp))
                                .background(
                                    if (isSelected) IosColors.Purple.copy(alpha = 0.5f)
                                    else Color.Black.copy(alpha = 0.6f),
                                    RoundedCornerShape(8.dp),
                                )
                                .clickable(
                                    role = Role.Button,
                                    onClickLabel = useVoice,
                                ) {
                                    model.select(option)
                                    onDismiss()
                                }
                                .padding(vertical = 6.dp, horizontal = 4.dp)
                                .clearAndSetSemantics {
                                    contentDescription = option.display
                                    stateDescription = if (isSelected) selectedWord else notSelectedWord
                                },
                        ) {
                            Text(option.emoji, fontSize = 20.sp)
                            Text(
                                option.display,
                                fontSize = 11.sp,
                                fontWeight = FontWeight.Medium,
                                color = Color.White,
                                textAlign = TextAlign.Center,
                                maxLines = 2,
                            )
                        }
                    }
                    if (rowVoices.size == 1) Box(Modifier.weight(1f))
                }
            }
        }
    }
}
