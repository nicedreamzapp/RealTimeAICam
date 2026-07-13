package com.mattmacosko.realtimeaicam.ui

import android.content.Context
import android.speech.tts.TextToSpeech
import android.speech.tts.Voice
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
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
 * Owns a TTS instance for the Home voice picker: lists up to 10 English
 * voices (iOS §1.7/§1.8), tracks + persists the selection, speaks the
 * iOS welcome line on selection.
 */
class VoicePickerModel(private val context: Context) {
    var voices by mutableStateOf<List<VoiceOption>>(emptyList())
        private set
    var selected by mutableStateOf<VoiceOption?>(null)
        private set

    private var tts: TextToSpeech? = null

    init {
        // Show the persisted voice immediately (TTS init can take seconds)
        selected = VoicePrefs.getOption(context)
        tts = TextToSpeech(context) { status ->
            if (status == TextToSpeech.SUCCESS) loadVoices()
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
        val base = v.locale.getDisplayName(Locale.ENGLISH)
            .replace("English (United States)", "English (US)")
            .replace("English (United Kingdom)", "English (UK)")
        val tag = if (v.quality >= Voice.QUALITY_HIGH) " (Enhanced)" else ""
        return "$base ${index + 1}$tag"
    }

    private fun loadVoices() {
        val t = tts ?: return
        val english = try {
            t.voices.orEmpty()
                .filter { it.locale.language == "en" && !it.isNetworkConnectionRequired }
                .sortedByDescending { it.quality }
                .take(10)
        } catch (e: Exception) {
            emptyList()
        }
        var perLocale = HashMap<String, Int>()
        voices = english.map { v ->
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
            "Welcome to the RealTime AI Detection app. Thank you for choosing this voice!",
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
    return model
}

/** Voice grid popup (spec §1.8): 2-column grid anchored above the pill. */
@Composable
fun VoiceGridPopup(
    model: VoicePickerModel,
    onDismiss: () -> Unit,
) {
    // Full-screen scrim to dismiss on outside tap
    Box(
        Modifier
            .fillMaxSize()
            .clickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = null,
                onClick = onDismiss,
            ),
        contentAlignment = Alignment.BottomCenter,
    ) {
        Column(
            verticalArrangement = Arrangement.spacedBy(8.dp),
            modifier = Modifier
                .padding(bottom = 200.dp)
                .width(280.dp)
                .clip(RoundedCornerShape(12.dp))
                .background(Color.Black.copy(alpha = 0.85f), RoundedCornerShape(12.dp))
                .border(1.dp, IosColors.Purple.copy(alpha = 0.4f), RoundedCornerShape(12.dp))
                .clickable(
                    interactionSource = remember { MutableInteractionSource() },
                    indication = null,
                ) { /* consume */ }
                .padding(8.dp),
        ) {
            if (model.voices.isEmpty()) {
                Text(
                    "No voices available",
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
                                .clickable {
                                    model.select(option)
                                    onDismiss()
                                }
                                .padding(vertical = 6.dp, horizontal = 4.dp),
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
