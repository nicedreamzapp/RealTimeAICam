package com.mattmacosko.realtimeaicam.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Memory
import androidx.compose.material.icons.filled.RadioButtonUnchecked
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.mattmacosko.realtimeaicam.narrator.ModelDownloader
import com.mattmacosko.realtimeaicam.narrator.ModelLevel
import com.mattmacosko.realtimeaicam.narrator.ModelPicker
import com.mattmacosko.realtimeaicam.narrator.ModelPriority
import com.mattmacosko.realtimeaicam.narrator.NarratorEngine
import com.mattmacosko.realtimeaicam.narrator.PhotoKind
import com.mattmacosko.realtimeaicam.narrator.SpeedCheck
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Settings > Models (1.24): which What's this? level answers and how the
 * automatic pick leans. Each row shows its size and how long an answer takes on
 * this phone.
 */
@Composable
fun ModelsCard() {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val states by ModelDownloader.states.collectAsState()
    var refresh by remember { mutableIntStateOf(0) }
    var checking by remember { mutableStateOf(false) }
    @Suppress("UNUSED_EXPRESSION") refresh; states

    val choice = ModelPicker.manualLevel(context)
    val priority = ModelPicker.priority(context)
    val measured = ModelPicker.balancedSeconds(context) != null

    Column(
        verticalArrangement = Arrangement.spacedBy(10.dp),
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(IosColors.MaterialLight.copy(alpha = 0.35f), RoundedCornerShape(12.dp))
            .border(1.dp, Color.White.copy(alpha = 0.15f), RoundedCornerShape(12.dp))
            .padding(16.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Default.Memory, null, tint = Color(0xFF30B0C7), modifier = Modifier.size(22.dp))
            Text("  Models", fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = Color.White)
        }
        val summary = when {
            checking -> "Checking this phone's speed with one test photo…"
            !measured -> "Your first What's this? photo measures this phone's speed, then the best level for it downloads on Wi-Fi."
            else -> {
                val page = ModelPicker.ideal(context, PhotoKind.PAGE)
                val scene = ModelPicker.ideal(context, PhotoKind.SCENE)
                if (page == scene) "Automatic uses ${page.title} on this phone."
                else "Automatic uses ${page.title} for mail, money and medicine, and ${scene.title} for everything else."
            }
        }
        Text(summary, fontSize = 14.sp, color = IosColors.Gray)

        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
            for (p in ModelPriority.entries) {
                val on = p == priority
                Text(
                    p.title,
                    fontSize = 14.sp,
                    color = Color.White,
                    fontWeight = if (on) FontWeight.SemiBold else FontWeight.Normal,
                    modifier = Modifier
                        .weight(1f)
                        .clip(RoundedCornerShape(8.dp))
                        .background(if (on) Color.White.copy(alpha = 0.25f) else Color.White.copy(alpha = 0.08f))
                        .clickable(role = Role.RadioButton) {
                            ModelPicker.setPriority(context, p)
                            ModelDownloader.fetchWanted(context, automatic = true)
                            refresh++
                        }
                        .semantics { selected = on }
                        .padding(vertical = 8.dp, horizontal = 12.dp),
                )
            }
        }

        LevelRow(null, choice == null, measured) {
            ModelPicker.setManualLevel(context, null)
            ModelDownloader.fetchWanted(context, automatic = true)
            refresh++
        }
        for (level in ModelLevel.entries) {
            LevelRow(level, choice == level, measured) {
                if (level.fitsThisPhone(context)) {
                    ModelPicker.setManualLevel(context, level)
                    if (!level.isInstalled(context)) ModelDownloader.start(context, level)
                    refresh++
                }
            }
        }

        Text(
            if (checking) "Checking speed…" else "Check this phone's speed again",
            fontSize = 14.sp,
            color = IosColors.Blue,
            modifier = Modifier
                .clickable(enabled = !checking, role = Role.Button,
                    onClickLabel = "Time one test photo and update every estimate") {
                    checking = true
                    scope.launch {
                        withContext(Dispatchers.IO) { SpeedCheck.run(context) }
                        checking = false
                        refresh++
                    }
                }
                .padding(vertical = 4.dp),
        )
    }
}

@Composable
private fun LevelRow(level: ModelLevel?, selected: Boolean, measured: Boolean, onPick: () -> Unit) {
    val context = LocalContext.current
    val state = level?.let { ModelDownloader.state(context, it) }
    val title = level?.let { "${it.title}  ·  ${it.score}/100" } ?: "Automatic (recommended)"
    val detail = when {
        level == null -> "Picks the smartest level this phone runs in time, and gives mail, money and medicine the most accurate one."
        !level.fitsThisPhone(context) -> "${level.blurb} Needs more memory than this phone has."
        else -> {
            val size = if (level.isBundled) "No download." else "${level.sizeText()}."
            if (!measured) "${level.blurb} $size"
            else "${level.blurb} $size A scene takes ${ModelPicker.spoken(ModelPicker.estimate(context, level, PhotoKind.SCENE))}, " +
                "a page ${ModelPicker.spoken(ModelPicker.estimate(context, level, PhotoKind.PAGE))}."
        }
    }
    Row(
        verticalAlignment = Alignment.Top,
        modifier = Modifier
            .fillMaxWidth()
            .clickable(role = Role.RadioButton, onClick = onPick)
            .semantics(mergeDescendants = true) { this.selected = selected }
            .padding(vertical = 4.dp),
    ) {
        Icon(
            if (selected) Icons.Default.CheckCircle else Icons.Default.RadioButtonUnchecked, null,
            tint = if (selected) Color(0xFF30B0C7) else IosColors.Gray,
            modifier = Modifier.size(24.dp),
        )
        Column(Modifier.padding(start = 10.dp), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(title, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = Color.White)
            Text(detail, fontSize = 12.sp, color = IosColors.Gray)
            if (level != null && !level.isBundled) when (state) {
                is ModelDownloader.State.Ready -> SmallAction("Delete (frees ${level.sizeText()})", IosColors.Red) {
                    ModelDownloader.delete(context, level)
                    NarratorEngine.get(context).select(ModelLevel.BALANCED)
                }
                is ModelDownloader.State.Queued -> Text("Waiting to download", fontSize = 12.sp, color = IosColors.Gray)
                is ModelDownloader.State.Downloading -> LinearProgressIndicator(
                    progress = { state.progress },
                    color = Color(0xFF30B0C7),
                    modifier = Modifier.fillMaxWidth().semantics {
                        contentDescription = "Downloading, ${(state.progress * 100).toInt()} percent"
                    },
                )
                is ModelDownloader.State.Verifying -> Text("Checking the download…", fontSize = 12.sp, color = IosColors.Gray)
                is ModelDownloader.State.Failed -> {
                    Text("Download failed: ${state.why}", fontSize = 12.sp, color = IosColors.Red)
                    SmallAction("Download ${level.sizeText()}", IosColors.Blue) { ModelDownloader.start(context, level) }
                }
                else -> if (level.fitsThisPhone(context)) {
                    SmallAction("Download ${level.sizeText()}", IosColors.Blue) { ModelDownloader.start(context, level) }
                }
            }
        }
    }
}

@Composable
private fun SmallAction(label: String, color: Color, onClick: () -> Unit) {
    Text(
        label, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = color,
        modifier = Modifier.clickable(role = Role.Button, onClick = onClick).padding(vertical = 2.dp),
    )
}
