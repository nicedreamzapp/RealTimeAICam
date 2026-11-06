package com.mattmacosko.realtimeaicam.ui

import androidx.compose.ui.res.stringResource
import com.mattmacosko.realtimeaicam.R
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.mattmacosko.realtimeaicam.camera.SpeechAnnouncer
import com.mattmacosko.realtimeaicam.camera.SpeechProblem
import kotlinx.coroutines.delay

/**
 * Says why the app can't be heard, on the camera screens (2026-11-04, a 1-star Play review:
 * "no voice output, complete silence"). Volume at 0 shows a note; no working speech engine or
 * voice shows a button straight to the phone's text-to-speech settings. Nothing shows when
 * speech is fine. While shown it re-checks the volume once a second, so it goes away as soon
 * as the volume comes up.
 */
@Composable
fun SpeechProblemBanner(announcer: SpeechAnnouncer, modifier: Modifier = Modifier) {
    LaunchedEffect(announcer) {
        while (true) {
            announcer.checkVolume()
            delay(1_000)
        }
    }
    val problem by announcer.problem.collectAsState()
    // Your language's one-time download, offered on every camera screen until it is taken.
    Column(modifier, verticalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(8.dp)) {
        SpeechProblemCard(announcer, problem)
        YourLanguageDownloadRow(say = { announcer.speak(it) })
    }
}

@Composable
private fun SpeechProblemCard(announcer: SpeechAnnouncer, problem: SpeechProblem?) {
    val modifier = Modifier
    val missingLang by announcer.missingVoiceLanguage.collectAsState()
    val current = problem ?: return
    val context = LocalContext.current
    val message = when (current) {
        SpeechProblem.VOLUME_OFF -> stringResource(R.string.e_volume_off_line)
        SpeechProblem.NO_ENGINE -> stringResource(R.string.e_banner_no_engine)
        SpeechProblem.NO_VOICE -> stringResource(R.string.e_banner_no_voice)
        SpeechProblem.NO_LANGUAGE_VOICE -> stringResource(
            R.string.e_banner_no_language_voice,
            com.mattmacosko.realtimeaicam.translation.YourLanguageRules.noVoiceShown(missingLang ?: "en"),
        )
    }
    Column(
        modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(Color(0xE6B3261E), RoundedCornerShape(16.dp))
            .padding(14.dp)
            .testTag("speechProblemBanner")
            // The volume note is announced once by the announcer itself; the others are read
            // by TalkBack as they appear.
            .semantics { if (current != SpeechProblem.VOLUME_OFF) liveRegion = LiveRegionMode.Polite },
    ) {
        Text(message, color = Color.White, fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
        if (current != SpeechProblem.VOLUME_OFF) {
            Spacer(Modifier.height(10.dp))
            Button(
                onClick = { openSpeechSettings(context) },
                colors = ButtonDefaults.buttonColors(containerColor = Color.White, contentColor = Color.Black),
            ) { Text(stringResource(R.string.e_banner_open_speech_settings), fontSize = 16.sp, fontWeight = FontWeight.SemiBold) }
        }
    }
}

/** The phone's text-to-speech settings; plain Accessibility settings on phones that hide it. */
fun openSpeechSettings(context: Context) {
    val tries = listOf(
        Intent("com.android.settings.TTS_SETTINGS"),
        Intent(android.provider.Settings.ACTION_ACCESSIBILITY_SETTINGS),
        Intent(android.provider.Settings.ACTION_SETTINGS),
    )
    for (intent in tries) {
        try {
            context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            return
        } catch (_: ActivityNotFoundException) {
        } catch (_: SecurityException) {
        }
    }
}
