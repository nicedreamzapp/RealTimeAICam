package com.mattmacosko.realtimeaicam.ui

import androidx.compose.ui.res.stringResource
import com.mattmacosko.realtimeaicam.AppLang
import com.mattmacosko.realtimeaicam.R
import androidx.compose.animation.ExitTransition
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.clearAndSetSemantics
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.slideInVertically
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
import androidx.compose.ui.semantics.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

// Rewritten for the new home (iOS parity, 2026-11-04): the same order as the home screen,
// Read and Translate merged, Settings on home, Help Me Aim, Live Cam.
/** One short paragraph, same words in the INFO GUIDE and the spoken tutorial (and on iOS), in the app's language. */
fun yourLanguageGuide(): String = com.mattmacosko.realtimeaicam.translation.YourLanguageRules.guide()

/** The spoken tutorial, in the app's language (2026-11-05: Spanish text in a Spanish voice). */
private fun tutorialText(): String = listOf(
    AppLang.str(R.string.e_tut_welcome),
    AppLang.str(R.string.e_tut_home),
    AppLang.str(R.string.e_tut_read, com.mattmacosko.realtimeaicam.translation.ReaderLanguages.all.size),
    AppLang.str(R.string.e_tut_object_detection),
    AppLang.str(R.string.e_tut_whats_this),
    AppLang.str(R.string.e_tut_help_me_aim),
    AppLang.str(R.string.e_tut_live_cam),
    AppLang.str(R.string.e_tut_models),
    yourLanguageGuide(),
    AppLang.str(R.string.e_tut_private),
).joinToString(" ")

/** Say the tutorial in a voice for the app's language (the picked voice when it speaks it). */
private fun speakTutorial(context: android.content.Context, tts: TextToSpeech) {
    VoicePrefs.applyFor(context, tts, AppLang.code())
    tts.speak(tutorialText(), TextToSpeech.QUEUE_FLUSH, null, "tutorial")
}

const val INSTRUCTIONS_TITLE_TAG = "instructionsTitle"
/** The sheet slides up in 300 ms; focus moves once it is in place. */
private const val INSTRUCTIONS_FOCUS_DELAY_MS = 450L

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
                if (speaking) speakTutorial(context, t!!)
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

    // Opening (first-time-user test, 2026-11-04): TalkBack only read the app's name, then the
    // scrolls were silent. Now its focus lands on the "Instructions" heading as the sheet opens,
    // so it says the heading and swipes go on through the guide. Waits out the camera permission
    // dialog that covers the sheet at first launch.
    val view = androidx.compose.ui.platform.LocalView.current
    androidx.compose.runtime.LaunchedEffect(visible) {
        if (!visible) return@LaunchedEffect
        kotlinx.coroutines.delay(INSTRUCTIONS_FOCUS_DELAY_MS)
        if (A11yFocus.awaitWindowFocus(view)) A11yFocus.moveToSoon(view, INSTRUCTIONS_TITLE_TAG)
    }

    val doneWord = stringResource(R.string.e_done)
    val welcome = stringResource(R.string.e_guide_welcome)
    val stopAction = stringResource(R.string.e_guide_stop_action)
    val playAction = stringResource(R.string.e_guide_play_action)
    val stopLabel = stringResource(R.string.e_guide_stop_label)
    val playLabel = stringResource(R.string.e_guide_play_label)

    BackHandler(enabled = visible) {
        stopAudio()
        onDismiss()
    }

    AnimatedVisibility(
        visible = visible,
        enter = slideInVertically(tween(300)) { it } + fadeIn(tween(200)),
        // Gone the moment Done is pressed (2026-11-04): while the sheet slid out it still
        // covered the home screen and swallowed the next tap, on Read for example.
        exit = ExitTransition.None,
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
                    stringResource(R.string.e_done),
                    fontSize = 17.sp,
                    color = IosColors.Blue,
                    modifier = Modifier
                        .align(Alignment.CenterStart)
                        .clickable(
                            interactionSource = remember { MutableInteractionSource() },
                            indication = null,
                            role = Role.Button,
                            onClickLabel = stringResource(R.string.e_guide_close_action),
                        ) {
                            stopAudio()
                            onDismiss()
                        }
                        .padding(4.dp)
                        .semantics { contentDescription = doneWord },
                )
                Text(
                    stringResource(R.string.e_guide_title),
                    fontSize = 17.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = Color.White,
                    modifier = Modifier
                        .align(Alignment.Center)
                        .semantics {
                            heading()
                            testTag = INSTRUCTIONS_TITLE_TAG
                        },
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
                    "👋 $welcome",
                    modifier = Modifier.semantics { contentDescription = welcome; heading() },
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
                            onClickLabel = if (speaking) stopAction else playAction,
                        ) {
                            if (speaking) {
                                stopAudio()
                            } else {
                                speaking = true
                                speakTutorial(context, tts)
                            }
                        }
                        .padding(16.dp)
                        .clearAndSetSemantics {
                            contentDescription = if (speaking) stopLabel else playLabel
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
                        if (speaking) "⏹ " + stringResource(R.string.e_guide_stop_button) else "🎧 " + stringResource(R.string.e_guide_play_button),
                        fontSize = 17.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = Color.White,
                    )
                    Spacer(Modifier.weight(1f))
                }

                Text(
                    stringResource(R.string.e_guide_tagline),
                    fontSize = 20.sp,
                    color = Color.White,
                )

                // The five tools, in the same order as the home screen.
                val languageCount = com.mattmacosko.realtimeaicam.translation.ReaderLanguages.all.size
                ModeBlock("📖 " + stringResource(R.string.e_home_read), stringResource(R.string.e_guide_read, languageCount))
                ModeBlock("🐶 " + stringResource(R.string.e_home_object_detection), stringResource(R.string.e_guide_object_detection))
                ModeBlock("📄 " + stringResource(R.string.e_home_whats_this), stringResource(R.string.e_guide_whats_this))
                ModeBlock("🎯 " + stringResource(R.string.e_home_help_me_aim), stringResource(R.string.e_guide_help_me_aim))
                ModeBlock("💬 " + stringResource(R.string.e_guide_live_cam_title), stringResource(R.string.e_guide_live_cam))
                ModeBlock("⚙️ " + stringResource(R.string.e_home_settings_label), stringResource(R.string.e_guide_settings))
                ModeBlock("🌍 " + stringResource(R.string.e_yl_title), stringResource(R.string.e_yl_guide))

                SectionHeader("🎛️ " + stringResource(R.string.e_guide_controls))
                BodyLine("🔄 " + stringResource(R.string.e_guide_switch_camera))
                BodyLine("🌐 " + stringResource(R.string.e_guide_lens))
                BodyLine("🔦 " + stringResource(R.string.e_guide_flashlight))
                BodyLine("🤏 " + stringResource(R.string.e_guide_pinch))

                SectionHeader("🔒 " + stringResource(R.string.e_guide_private_title))
                BodyLine(stringResource(R.string.e_guide_private_offline), secondary = true)
                BodyLine(stringResource(R.string.e_guide_private_no_accounts), secondary = true)

                SectionHeader("🙏 " + stringResource(R.string.e_guide_credits))
                BodyLine(stringResource(R.string.e_guide_credit_lfm), secondary = true)
                BodyLine(stringResource(R.string.e_guide_credit_quick), secondary = true)
                LicenseText(stringResource(R.string.e_guide_read_license), "licenses/LFM-Open-License-v1.0.txt")
                BodyLine(stringResource(R.string.e_guide_credit_llama), secondary = true)
                BodyLine(stringResource(R.string.e_guide_credit_yolo), secondary = true)

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
                .clickable(role = Role.Button, onClickLabel = if (open) stringResource(R.string.e_guide_hide_license) else stringResource(R.string.e_guide_show_license)) { open = !open }
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
