package com.mattmacosko.realtimeaicam.ui

import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material.icons.filled.VolumeUp
import androidx.compose.material3.Icon
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

private const val TUTORIAL_TEXT =
    "Welcome to RealTime AI Camera! Snap, detect, translate, all on device. " +
        "There are three modes. Object Detection identifies everyday objects in real time. " +
        "English Text to Speech reads printed English out loud. " +
        "Spanish to English translates printed Spanish instantly. " +
        "Controls: switch camera, toggle the lens, use the flashlight at four brightness levels, " +
        "pinch to zoom, reset or stop, speak results, copy text to history, and open settings. " +
        "Privacy first: everything runs on your device. No tracking, no accounts, no internet needed."

/** iOS AppInstructionsView (UI_SPEC §4) as a slide-up sheet. */
@Composable
fun InstructionsSheet(visible: Boolean, onDismiss: () -> Unit) {
    val context = LocalContext.current
    var speaking by remember { mutableStateOf(false) }
    var ttsReady by remember { mutableStateOf(false) }

    val tts = remember {
        var t: TextToSpeech? = null
        t = TextToSpeech(context) { status -> ttsReady = status == TextToSpeech.SUCCESS }
        t!!.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
            override fun onStart(utteranceId: String?) {}
            override fun onDone(utteranceId: String?) { speaking = false }
            @Deprecated("Deprecated in Java")
            override fun onError(utteranceId: String?) { speaking = false }
        })
        t
    }
    DisposableEffect(Unit) {
        onDispose {
            tts.stop()
            tts.shutdown()
        }
    }

    fun stopAudio() {
        tts.stop()
        speaking = false
    }

    BackHandler(enabled = visible) {
        stopAudio()
        onDismiss()
    }

    AnimatedVisibility(
        visible = visible,
        enter = slideInVertically(tween(300)) { it } + fadeIn(tween(200)),
        exit = slideOutVertically(tween(250)) { it } + fadeOut(tween(150)),
    ) {
        Column(
            Modifier
                .fillMaxSize()
                .padding(top = 24.dp)
                .clip(RoundedCornerShape(topStart = 10.dp, topEnd = 10.dp))
                .background(Color(0xFF1C1C1E))
        ) {
            // Drag handle + nav bar
            Box(
                Modifier
                    .align(Alignment.CenterHorizontally)
                    .padding(top = 6.dp)
                    .size(width = 36.dp, height = 5.dp)
                    .clip(CapsuleShape)
                    .background(Color.White.copy(alpha = 0.3f))
            )
            Box(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp)) {
                Text(
                    "Done",
                    fontSize = 17.sp,
                    color = IosColors.Blue,
                    modifier = Modifier
                        .align(Alignment.CenterStart)
                        .clickable(
                            interactionSource = remember { MutableInteractionSource() },
                            indication = null,
                        ) {
                            stopAudio()
                            onDismiss()
                        }
                        .padding(4.dp),
                )
                Text(
                    "Instructions",
                    fontSize = 17.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = Color.White,
                    modifier = Modifier.align(Alignment.Center),
                )
            }

            Column(
                Modifier
                    .fillMaxSize()
                    .verticalScroll(rememberScrollState())
                    .padding(24.dp)
                    .navigationBarsPadding(),
                verticalArrangement = Arrangement.spacedBy(20.dp),
            ) {
                Text(
                    "👋 Welcome to RealTime AI Camera!",
                    fontSize = 34.sp,
                    fontWeight = FontWeight.Bold,
                    color = Color.White,
                    lineHeight = 40.sp,
                )

                // Play / Stop audio tutorial
                Row(
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(12.dp))
                        .background(
                            (if (speaking) IosColors.Red else IosColors.Blue).copy(alpha = 0.18f),
                            RoundedCornerShape(12.dp),
                        )
                        .clickable(enabled = ttsReady) {
                            if (speaking) {
                                stopAudio()
                            } else {
                                speaking = true
                                tts.speak(TUTORIAL_TEXT, TextToSpeech.QUEUE_FLUSH, null, "tutorial")
                            }
                        }
                        .padding(16.dp),
                ) {
                    Spacer(Modifier.weight(1f))
                    Icon(
                        if (speaking) Icons.Default.Stop else Icons.Default.VolumeUp,
                        null,
                        tint = Color.White,
                        modifier = Modifier.size(20.dp),
                    )
                    Text(
                        if (speaking) "⏹ Stop Audio" else "🎧 Play Full Audio Tutorial",
                        fontSize = 17.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = Color.White,
                    )
                    Spacer(Modifier.weight(1f))
                }

                Text(
                    "Snap, Detect, Translate — all on-device.",
                    fontSize = 20.sp,
                    color = Color.White,
                )

                SectionHeader("✨ Modes")
                ModeBlock(
                    "🐶 Object Detection",
                    "Point the camera at everyday objects and hear what they are — 600+ classes, live bounding boxes, adjustable confidence.",
                )
                ModeBlock(
                    "🔠 English OCR",
                    "Reads printed English text out loud in real time. Copy it, or have it spoken.",
                )
                ModeBlock(
                    "🇲🇽→🇺🇸 Spanish to English Translate",
                    "Point at Spanish text — menus, signs, labels — and get instant English, fully offline.",
                )

                SectionHeader("🎛️ Controls")
                BodyLine("🔄 Switch Camera — flip between rear and front")
                BodyLine("🌐 Lens Toggle — wide / ultra-wide (when available)")
                BodyLine("🔦 Torch — 25% / 50% / 75% / 100%")
                BodyLine("🤏 Pinch to Zoom")
                BodyLine("🔁 Reset / Stop — clears text, translation, and stops speaking")
                BodyLine("🗣️ Speak — hear detected or translated text")
                BodyLine("📋 Copy to History — saved on this device")
                BodyLine("⚙️ Settings — history, tips, privacy")

                SectionHeader("🔒 Privacy First")
                BodyLine("Works 100% offline — even in Airplane Mode", secondary = true)
                BodyLine("No tracking, no analytics, no accounts", secondary = true)
                BodyLine("Camera frames are processed on-device only", secondary = true)
                BodyLine("Copy history stays on this device", secondary = true)

                Spacer(Modifier.height(24.dp))
            }
        }
    }
}

@Composable
private fun SectionHeader(text: String) {
    Text(text, fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = Color.White)
}

@Composable
private fun ModeBlock(title: String, body: String) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(title, fontSize = 22.sp, fontWeight = FontWeight.SemiBold, color = Color.White)
        Text(body, fontSize = 17.sp, color = Color.White.copy(alpha = 0.9f), lineHeight = 23.sp)
    }
}

@Composable
private fun BodyLine(text: String, secondary: Boolean = false) {
    Text(
        "• $text",
        fontSize = if (secondary) 15.sp else 17.sp,
        color = if (secondary) IosColors.Secondary else Color.White.copy(alpha = 0.9f),
        lineHeight = 22.sp,
    )
}
