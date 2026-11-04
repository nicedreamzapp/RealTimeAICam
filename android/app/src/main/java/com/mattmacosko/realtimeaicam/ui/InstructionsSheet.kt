package com.mattmacosko.realtimeaicam.ui

import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.clearAndSetSemantics
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
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

// Rewritten for the new home (iOS parity, 2026-11-04): the same order as the home screen,
// Read and Translate merged, Settings on home, Help Me Aim, Live Cam.
/** One short paragraph, same words in the INFO GUIDE and the spoken tutorial (and on iOS). */
const val YOUR_LANGUAGE_GUIDE = "Your language: in Settings, pick the language you want to hear. The first time, tap Download once; after that it works offline. Read, Object Detection, Help Me Aim and What's this? then speak in your language. Buttons stay in English for now."

private val TUTORIAL_TEXT = listOf(
    "Welcome to the RealTime A I Camera.",
    "The home screen has two buttons at the top, Settings and Info and guide, then five tools, then the voice button. Swipe through them, or touch the screen to explore.",
    "Read. Point at printed text and hear it out loud. The Language button at the top picks English, or one of ${com.mattmacosko.realtimeaicam.translation.ReaderLanguages.all.size} languages to translate into English. Russian, Ukrainian, Chinese, Japanese, Korean, Thai and Arabic need their own reader, downloaded once the first time you pick them, then offline. Tap it to step to the next one, or with TalkBack swipe up or down on it. The small button next to Speak switches between Auto read, which is on to start and reads new text by itself, Mute, and Tap to read.",
    "Object Detection names the things around you as you move the phone.",
    "What's this? takes one careful look. Mail and pages get the point of them, like who sent it and what's due. A room gets a description. Afterwards, hold to ask a follow up question.",
    "Help Me Aim takes a good photo for you. Choose Face, Picture or Page, or Something Else and say what you want. It tells you which way to move, counts down, and saves the photo with a description. For things it doesn't know by sight, like a wallet, it looks closely and tells you where it is. Double tap anywhere to take the picture yourself.",
    "Live Cam is coming soon. It lets you talk with the camera. Ask out loud about what's in front of you and hear the answer.",
    "In Settings, Models, the app already picked the best A I for your phone. You can choose Most accurate or Fastest there.",
    YOUR_LANGUAGE_GUIDE,
    "Everything runs on your phone and works offline. No accounts and no tracking.",
).joinToString(" ")

/** iOS AppInstructionsView (UI_SPEC §4) as a slide-up sheet. */
@Composable
fun InstructionsSheet(visible: Boolean, onDismiss: () -> Unit) {
    val context = LocalContext.current
    var speaking by remember { mutableStateOf(false) }
    var ttsReady by remember { mutableStateOf(false) }

    val tts = remember {
        var t: TextToSpeech? = null
        t = TextToSpeech(context) { status ->
            ttsReady = status == TextToSpeech.SUCCESS
            if (ttsReady) {
                // Cold first launch: the guide may have been asked for before the engine was up.
                try {
                    if (t!!.isLanguageAvailable(java.util.Locale.getDefault()) < TextToSpeech.LANG_AVAILABLE) {
                        t!!.setLanguage(java.util.Locale.US)
                    }
                } catch (_: Throwable) {}
                try { VoicePrefs.apply(context, t!!) } catch (_: Throwable) {}
                if (speaking) t!!.speak(TUTORIAL_TEXT, TextToSpeech.QUEUE_FLUSH, null, "tutorial")
            } else {
                speaking = false
            }
        }
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
                            role = Role.Button,
                            onClickLabel = "Close the instructions",
                        ) {
                            stopAudio()
                            onDismiss()
                        }
                        .padding(4.dp)
                        .semantics { contentDescription = "Done" },
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
                    modifier = Modifier.semantics { contentDescription = "Welcome to RealTime AI Camera!"; heading() },
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
                        .clickable(
                            enabled = ttsReady,
                            role = Role.Button,
                            onClickLabel = if (speaking) {
                                "Stop the spoken instructions"
                            } else {
                                "Speak a full guide to the app"
                            },
                        ) {
                            if (speaking) {
                                stopAudio()
                            } else {
                                speaking = true
                                tts.speak(TUTORIAL_TEXT, TextToSpeech.QUEUE_FLUSH, null, "tutorial")
                            }
                        }
                        .padding(16.dp)
                        .clearAndSetSemantics {
                            contentDescription = if (speaking) {
                                "Stop audio tutorial"
                            } else {
                                "Play full audio tutorial"
                            }
                        },
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
                    "Your camera, out loud. Everything runs on your phone.",
                    fontSize = 20.sp,
                    color = Color.White,
                )

                // The five tools, in the same order as the home screen.
                val languageCount = com.mattmacosko.realtimeaicam.translation.ReaderLanguages.all.size
                ModeBlock(
                    "📖 Read",
                    "Point at printed text and hear it read out loud. The Language pill at the top picks English or one of " +
                        "$languageCount languages, like Spanish, French, Russian, Chinese or Arabic, and translates it into English. " +
                        "Each language downloads once, then works offline. Russian, Ukrainian, Chinese, Japanese, Korean, Thai " +
                        "and Arabic also download their reader the first time you pick them; tap the card to get it. Until " +
                        "its pack is on the phone, Spanish still translates " +
                        "with the built-in dictionary. Auto read is on to start: new text is spoken by itself, once. " +
                        "The small button next to Speak switches between Auto read, Mute and Tap to read. Copy keeps the text in your history.",
                )
                ModeBlock(
                    "🐶 Object Detection",
                    "Names the things around you as you move the phone, nonstop, fast and offline.",
                )
                ModeBlock(
                    "📄 What's this?",
                    "One careful look. Point at a page, a bill, a package or a room and press the button. Mail and pages get " +
                        "the point of them: who sent it, what it is, what's due. A room or a thing gets a description. " +
                        "Afterwards, hold to ask a follow-up question about the same photo.",
                )
                ModeBlock(
                    "🎯 Help Me Aim",
                    "Takes a good photo for you. Choose Face, Picture or Page, or Something Else and say or type what you want, " +
                        "like keys, a mug or your dog. The app tells you which way to move, counts down and takes the picture, " +
                        "then saves it to your gallery with a description written into it. It knows hundreds of everyday things; " +
                        "for anything else, like a wallet, it looks closely with the describing AI and tells you where it is. " +
                        "Double tap anywhere to take the picture yourself.",
                )
                ModeBlock(
                    "💬 Live Cam",
                    "Coming soon. Talk with the camera. Ask out loud about what's in front of you and hear the answer, then keep asking.",
                )
                ModeBlock(
                    "⚙️ Settings",
                    "The Settings button at the top of the home screen. Models: the app picks the best describing AI for your " +
                        "phone by itself and downloads it once, on Wi-Fi. Mail, money and medicine always get the most accurate " +
                        "one your phone can run. In Settings, then Models, you can choose Most accurate or Fastest, or pick one " +
                        "yourself. Settings also has the countdown before photos, the app's own voice or TalkBack, and your copy " +
                        "history. The voice button at the bottom of the home screen changes the voice.",
                )
                ModeBlock(
                    "🌍 Your language",
                    YOUR_LANGUAGE_GUIDE,
                )

                SectionHeader("🎛️ Camera controls")
                BodyLine("🔄 Switch camera, front or back")
                BodyLine("🌐 Lens toggle, wide or ultra-wide (Object Detection, when the phone has one)")
                BodyLine("🔦 Flashlight, one tap on, one tap off")
                BodyLine("🤏 Pinch to zoom")

                SectionHeader("🔒 Private by design")
                BodyLine("Everything runs on your phone and works offline, even in Airplane Mode. The bigger AI models and translation languages download once, then stay on your phone.", secondary = true)
                BodyLine("No accounts, no tracking, no location access. Nothing you point the camera at is uploaded.", secondary = true)

                SectionHeader("🙏 Credits")
                BodyLine(
                    "What's this? runs LFM3-Omni-2B by Liquid AI, on this phone, under the LFM Open License v1.0. " +
                        "Nice Dreamz converted it to GGUF in three sizes (Sharp Q8_0, Clear Q3_K_M, Balanced IQ2_XS); the weights are otherwise unchanged.",
                    secondary = true,
                )
                BodyLine("Quick: Vision Narrator 0.8B by Nice Dreamz, fine-tuned from Qwen3.5-0.8B by Alibaba Cloud (Apache-2.0)", secondary = true)
                LicenseText("Read the LFM Open License v1.0", "licenses/LFM-Open-License-v1.0.txt")
                BodyLine("On-device engine: llama.cpp by ggml-org (MIT)", secondary = true)
                BodyLine("Object Detection: YOLOv8 by Ultralytics (AGPL-3.0), trained on Open Images V7 by Google (CC BY 4.0)", secondary = true)

                Spacer(Modifier.height(24.dp))
            }
        }
    }
}

@Composable
private fun SectionHeader(text: String) {
    Text(
        text, fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = Color.White,
        modifier = Modifier.semantics { contentDescription = text.withoutEmoji(); heading() },
    )
}

@Composable
private fun ModeBlock(title: String, body: String) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(
            title, fontSize = 22.sp, fontWeight = FontWeight.SemiBold, color = Color.White,
            modifier = Modifier.semantics { contentDescription = title.withoutEmoji(); heading() },
        )
        Text(body, fontSize = 17.sp, color = Color.White.copy(alpha = 0.9f), lineHeight = 23.sp)
    }
}

/** A license shipped in assets/, shown in full when tapped (LFM Open License 4(a)). */
@Composable
private fun LicenseText(label: String, asset: String) {
    val context = LocalContext.current
    var open by remember { mutableStateOf(false) }
    val body = remember(open) {
        if (!open) "" else try {
            context.assets.open(asset).bufferedReader().use { it.readText() }
        } catch (t: Throwable) { "" }
    }
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(
            (if (open) "▾ " else "▸ ") + label,
            modifier = Modifier
                .clickable(role = Role.Button, onClickLabel = if (open) "Hide the license" else "Show the license") { open = !open }
                .semantics { contentDescription = label },
            fontSize = 15.sp,
            color = Color(0xFF64B5F6),
            lineHeight = 22.sp,
        )
        if (open && body.isNotEmpty()) {
            Text(body, fontSize = 13.sp, color = IosColors.Secondary, lineHeight = 18.sp)
        }
    }
}

@Composable
private fun BodyLine(text: String, secondary: Boolean = false) {
    Text(
        "• $text",
        modifier = Modifier.semantics { contentDescription = text.withoutEmoji() },
        fontSize = if (secondary) 15.sp else 17.sp,
        color = if (secondary) IosColors.Secondary else Color.White.copy(alpha = 0.9f),
        lineHeight = 22.sp,
    )
}
