package com.mattmacosko.realtimeaicam.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.Translate
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.res.stringResource
import com.mattmacosko.realtimeaicam.AppLang
import com.mattmacosko.realtimeaicam.R
import com.mattmacosko.realtimeaicam.translation.YourLanguage
import com.mattmacosko.realtimeaicam.translation.YourLanguageRules

/**
 * "Download <Name> once, then it works offline". Shown only when Your language is not English
 * and its pack isn't on the phone. The pack downloads ONLY on this tap (Matt's rule: nothing
 * downloads until the person clearly wants it). [say] speaks the progress lines.
 */
@Composable
fun YourLanguageDownloadRow(say: (String) -> Unit, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val ready by YourLanguage.readyPacks.collectAsState()
    val downloading by YourLanguage.downloading.collectAsState()
    val choice by YourLanguage.choice.collectAsState()
    val code = remember(choice) { YourLanguage.code(context) }
    if (code == YourLanguageRules.ENGLISH || code in ready) return
    val busy = downloading == code
    val label = if (busy) YourLanguageRules.downloadingLine(code) else YourLanguageRules.downloadRow(code)
    val downloadWord = stringResource(R.string.e_download)
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(IosColors.Blue.copy(alpha = 0.85f), RoundedCornerShape(14.dp))
            .clickable(enabled = !busy, role = Role.Button, onClickLabel = downloadWord) {
                YourLanguage.download(context, code, say = { line -> android.os.Handler(android.os.Looper.getMainLooper()).post { say(line) } })
            }
            .padding(horizontal = 14.dp, vertical = 12.dp)
            .testTag("yourLanguageDownload")
            .clearAndSetSemantics {
                contentDescription = label
                role = Role.Button
                if (!busy) onClick(label = downloadWord) {
                    YourLanguage.download(context, code, say = { line -> android.os.Handler(android.os.Looper.getMainLooper()).post { say(line) } })
                    true
                }
            },
    ) {
        Icon(Icons.Default.Download, null, tint = Color.White, modifier = Modifier.size(20.dp))
        Text(label, color = Color.White, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
        if (busy) { Spacer(Modifier.weight(1f)); AnimatedLoader(20.dp) }
    }
}

/** Settings: "Your language" with English and the 17 Read languages, plus the download row. */
@Composable
fun YourLanguageSettingsCard(say: (String) -> Unit) {
    val context = LocalContext.current
    val choice by YourLanguage.choice.collectAsState()
    val ready by YourLanguage.readyPacks.collectAsState()
    val code = remember(choice) { YourLanguage.code(context) }
    var open by remember { mutableStateOf(false) }
    val closeList = stringResource(R.string.e_yl_close_list)
    val chooseLanguage = stringResource(R.string.e_yl_choose)
    val yourLanguage = stringResource(R.string.e_yl_title)
    val selectedWord = stringResource(R.string.e_selected)
    val readyWord = stringResource(R.string.e_yl_ready_state)
    val needsDownload = stringResource(R.string.e_yl_needs_download)
    Column(
        verticalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(IosColors.MaterialLight.copy(alpha = 0.35f), RoundedCornerShape(12.dp))
            .padding(16.dp)
            .testTag("yourLanguageCard"),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .clickable(role = Role.Button, onClickLabel = if (open) closeList else chooseLanguage) { open = !open }
                .semantics(mergeDescendants = true) {
                    contentDescription = yourLanguage
                    stateDescription = YourLanguageRules.name(code)
                },
        ) {
            Icon(Icons.Default.Translate, null, tint = IosColors.Green, modifier = Modifier.size(20.dp))
            Column(Modifier.weight(1f).padding(start = 8.dp)) {
                Text(yourLanguage, fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = Color.White)
                Text(
                    stringResource(R.string.e_yl_card_note),
                    fontSize = 12.sp, color = IosColors.Gray,
                )
            }
            Text(
                YourLanguageRules.name(code),
                fontSize = 15.sp, fontWeight = FontWeight.Medium, color = IosColors.Purple,
                modifier = Modifier.padding(start = 8.dp),
            )
        }
        if (open) {
            YourLanguageRules.codes.forEach { c ->
                val isSel = c == code
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(8.dp))
                        .background(if (isSel) IosColors.Purple.copy(alpha = 0.45f) else Color.White.copy(alpha = 0.06f))
                        .clickable(role = Role.Button) {
                            YourLanguage.set(context, c)
                            open = false
                            // Said in the app's language as it is NOW: picking Spanish switches the app to Spanish.
                            val n = YourLanguageRules.nameInSentence(c)
                            say(
                                if (c == YourLanguageRules.ENGLISH || c in YourLanguage.readyPacks.value) AppLang.str(R.string.e_yl_is, n)
                                else AppLang.str(R.string.e_yl_is_download, n, YourLanguageRules.downloadRow(c))
                            )
                        }
                        .padding(horizontal = 12.dp, vertical = 10.dp)
                        .testTag("yourLanguage_$c")
                        .clearAndSetSemantics {
                            contentDescription = YourLanguageRules.name(c)
                            selected = isSel
                            stateDescription = when {
                                isSel -> selectedWord
                                c == YourLanguageRules.ENGLISH || c in ready -> readyWord
                                else -> needsDownload
                            }
                        },
                ) {
                    Text(YourLanguageRules.name(c), fontSize = 15.sp, color = Color.White, modifier = Modifier.weight(1f))
                    if (isSel) Text("✓", fontSize = 15.sp, color = Color.White)
                }
            }
        }
        YourLanguageDownloadRow(say)
    }
}

/** One voice for app-level lines (Your language download progress, the first-launch line). */
object AppVoice {
    @Volatile private var voice: com.mattmacosko.realtimeaicam.camera.SpeechAnnouncer? = null
    fun get(context: android.content.Context): com.mattmacosko.realtimeaicam.camera.SpeechAnnouncer =
        voice ?: synchronized(this) {
            voice ?: com.mattmacosko.realtimeaicam.camera.SpeechAnnouncer(context.applicationContext).also { voice = it }
        }
}
