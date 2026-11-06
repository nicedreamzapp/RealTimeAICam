package com.mattmacosko.realtimeaicam.ui

import androidx.compose.ui.res.stringResource
import com.mattmacosko.realtimeaicam.AppLang
import com.mattmacosko.realtimeaicam.R
import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.ChevronRight
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
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.mattmacosko.realtimeaicam.narrator.ModelDownloader
import com.mattmacosko.realtimeaicam.narrator.ModelLevel
import com.mattmacosko.realtimeaicam.narrator.ModelPicker
import com.mattmacosko.realtimeaicam.narrator.ModelPriority
import com.mattmacosko.realtimeaicam.narrator.NarratorEngine
import com.mattmacosko.realtimeaicam.narrator.PhotoKind
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

private val Teal = Color(0xFF30B0C7)

/**
 * Settings > Models (1.24), built for TalkBack first.
 *
 * In Settings it is ONE row: "Models. Using Quick, the best fit for this phone.
 * Double-tap to change." Someone who never wants to touch it hears one line and
 * swipes on. Double-tap opens a full-screen list of big rows, one swipe stop
 * each, every row read as one sentence, every choice said out loud. Delete and
 * stop live in TalkBack's actions menu, never as extra stops. The rows are full
 * width and at least 64 dp tall, so explore-by-touch finds them too.
 */
@Composable
fun ModelsCard() {
    val context = LocalContext.current
    val states by ModelDownloader.states.collectAsState()
    var open by remember { mutableStateOf(false) }
    var refresh by remember { mutableIntStateOf(0) }
    @Suppress("UNUSED_EXPRESSION") states; refresh
    val summary = modelsSummary(context)
    val changeLabel = stringResource(R.string.e_models_change)
    val changeHint = stringResource(R.string.e_models_change_hint)
    val modelsWord = stringResource(R.string.e_models)
    val cardLabel = stringResource(R.string.e_models_card_label, summary)

    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 64.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(IosColors.MaterialLight.copy(alpha = 0.35f), RoundedCornerShape(12.dp))
            .border(1.dp, Color.White.copy(alpha = 0.15f), RoundedCornerShape(12.dp))
            .clickable(role = Role.Button, onClickLabel = changeLabel) { open = true }
            .clearAndSetSemantics {
                contentDescription = cardLabel
                role = Role.Button
                onClick(changeHint) { open = true; true }
            }
            .padding(16.dp),
    ) {
        Icon(Icons.Default.Memory, null, tint = Teal, modifier = Modifier.size(22.dp))
        Column(Modifier.weight(1f).padding(horizontal = 12.dp)) {
            Text(modelsWord, fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = Color.White)
            Text(summary, fontSize = 14.sp, color = IosColors.Gray)
        }
        Icon(Icons.Default.ChevronRight, null, tint = IosColors.Gray)
    }

    if (open) ModelsChooser(onDone = { open = false; refresh++ })
}

/** One line: what is in use and why. Said the same on screen and by TalkBack. */
private fun modelsSummary(context: Context): String {
    val current = ModelDownloader.states.value.entries.firstOrNull { it.value is ModelDownloader.State.Downloading }
    if (current != null) {
        val pct = ((current.value as ModelDownloader.State.Downloading).progress * 100).toInt()
        return AppLang.str(R.string.e_models_getting, current.key.title, pct)
    }
    if (ModelPicker.balancedSeconds(context) == null) {
        return AppLang.str(R.string.e_models_using_builtin)
    }
    val using = ModelPicker.level(context, PhotoKind.SCENE)
    if (ModelPicker.manualLevel(context) != null) return AppLang.str(R.string.e_models_using_picked, using.title)
    val page = ModelPicker.ideal(context, PhotoKind.PAGE)
    val scene = ModelPicker.ideal(context, PhotoKind.SCENE)
    if (!page.isInstalled(context) || !scene.isInstalled(context)) {
        return AppLang.str(R.string.e_models_using_for_now, using.title, page.title)
    }
    if (page == scene) return AppLang.str(R.string.e_models_using_best, page.title)
    return AppLang.str(R.string.e_models_using_split, page.title, scene.title)
}

/** Everything about one model in one sentence, after its name. */
private fun rowSentence(context: Context, level: ModelLevel): String {
    val parts = mutableListOf(level.blurb)
    val state = ModelDownloader.state(context, level)
    when {
        !level.fitsThisPhone(context) -> parts += AppLang.str(R.string.e_models_too_big)
        state is ModelDownloader.State.Downloading -> parts += AppLang.str(R.string.e_models_downloading, (state.progress * 100).toInt())
        state is ModelDownloader.State.Queued -> parts += AppLang.str(R.string.e_models_waiting)
        state is ModelDownloader.State.Verifying -> parts += AppLang.str(R.string.e_models_checking)
        level.isBundled -> {}
        level.isInstalled(context) -> parts += AppLang.str(R.string.e_models_on_phone)
        else -> parts += AppLang.str(R.string.e_models_not_downloaded, level.sizeText())
    }
    if (state is ModelDownloader.State.Failed) parts += AppLang.str(R.string.e_models_last_failed)
    if (level.fitsThisPhone(context)) {
        ModelPicker.estimate(context, level, PhotoKind.SCENE)?.let { parts += AppLang.str(R.string.e_models_answers_in, ModelPicker.spoken(it)) }
    }
    parts += AppLang.str(R.string.e_models_accuracy, level.score)
    return parts.joinToString(" ")
}

@Composable
private fun ModelsChooser(onDone: () -> Unit) {
    val context = LocalContext.current
    val view = LocalView.current
    val scope = rememberCoroutineScope()
    val states by ModelDownloader.states.collectAsState()
    var refresh by remember { mutableIntStateOf(0) }
    @Suppress("UNUSED_EXPRESSION") states; refresh

    fun say(text: String) { A11yAnnounce.say(view, text) }
    val choice = ModelPicker.manualLevel(context)
    val priority = ModelPicker.priority(context)

    Dialog(onDismissRequest = onDone, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        // A dialog is its own window and resets LocalContext to the phone's language: put the
        // app's language back, or a Spanish app shows this sheet in English (Cricket, 11/05).
        val dialogContext = androidx.compose.ui.platform.LocalContext.current
        val appLang = com.mattmacosko.realtimeaicam.AppLang.code()
        val localized = remember(dialogContext, appLang) { com.mattmacosko.realtimeaicam.AppLang.localized(dialogContext) }
        androidx.compose.runtime.CompositionLocalProvider(
            androidx.compose.ui.platform.LocalContext provides localized,
        ) {
        Column(Modifier.fillMaxSize().background(Color.Black)) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp),
            ) {
                Text(stringResource(R.string.e_models), fontSize = 22.sp, fontWeight = FontWeight.SemiBold, color = Color.White,
                    modifier = Modifier.weight(1f).semantics { heading() })
                Text(
                    stringResource(R.string.e_done), fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = IosColors.Blue,
                    modifier = Modifier
                        .heightIn(min = 48.dp)
                        .clickable(role = Role.Button, onClick = onDone)
                        .padding(12.dp),
                )
            }
            LazyColumn(
                verticalArrangement = Arrangement.spacedBy(8.dp),
                modifier = Modifier.fillMaxSize().padding(horizontal = 16.dp),
            ) {
                item {
                    Text(
                        stringResource(R.string.e_models_intro),
                        fontSize = 16.sp, color = Color.White, modifier = Modifier.padding(vertical = 8.dp),
                    )
                }
                item { SectionTitle(stringResource(R.string.e_models_what_matters)) }
                for (p in ModelPriority.entries) item {
                    BigRow(p.title, p.explanation, selected = p == priority) {
                        ModelPicker.setPriority(context, p)
                        ModelDownloader.fetchWanted(context, automatic = true)
                        say(AppLang.str(R.string.e_models_selected, p.title))
                        refresh++
                    }
                }
                item { SectionTitle(stringResource(R.string.e_models_which)) }
                item {
                    BigRow(stringResource(R.string.e_models_automatic), modelsSummary(context), selected = choice == null) {
                        ModelPicker.setManualLevel(context, null)
                        ModelDownloader.fetchWanted(context, automatic = true)
                        say(AppLang.str(R.string.e_models_automatic_selected, modelsSummary(context)))
                        refresh++
                    }
                }
                for (level in ModelLevel.entries) item {
                    val state = ModelDownloader.state(context, level)
                    val deleteWord = stringResource(R.string.e_models_delete_word)
                    val stopWord = stringResource(R.string.e_models_stop_word)
                    var visibleWord: String? = null
                    val actions = buildList {
                        if (!level.isBundled && level.isInstalled(context)) add(
                            CustomAccessibilityAction(AppLang.str(R.string.e_models_delete_action, level.title, level.sizeText())) {
                                ModelDownloader.delete(context, level)
                                NarratorEngine.get(context).select(ModelLevel.BALANCED)
                                if (choice == level) ModelPicker.setManualLevel(context, null)
                                say(AppLang.str(R.string.e_models_deleted, level.title, level.sizeText()))
                                refresh++; true
                            },
                        ).also { if (visibleWord == null) visibleWord = deleteWord }
                        if (state is ModelDownloader.State.Downloading || state is ModelDownloader.State.Queued) add(
                            CustomAccessibilityAction(AppLang.str(R.string.e_models_stop_action, level.title)) {
                                ModelDownloader.delete(context, level)
                                say(AppLang.str(R.string.e_models_stopped, level.title))
                                refresh++; true
                            },
                        ).also { if (visibleWord == null) visibleWord = stopWord }
                    }
                    BigRow(
                        level.title, rowSentence(context, level), selected = choice == level,
                        note = level.technicalLine(),
                        dimmed = !level.fitsThisPhone(context),
                        progress = (state as? ModelDownloader.State.Downloading)?.progress,
                        actions = actions,
                        // Sighted people get the same delete as a visible word on the row.
                        visibleAction = actions.firstOrNull()?.let { a -> (visibleWord ?: a.label) to a.action },
                    ) {
                        if (!level.fitsThisPhone(context)) {
                            say(AppLang.str(R.string.e_models_level_too_big, level.title))
                        } else {
                            ModelPicker.setManualLevel(context, level)
                            if (level.isInstalled(context)) {
                                say(AppLang.str(R.string.e_models_level_selected_ready, level.title))
                            } else {
                                // The downloader says the rest ("Getting Sharp, 2 GB…"), once.
                                say(AppLang.str(R.string.e_models_selected, level.title))
                                ModelDownloader.start(context, level)
                            }
                        }
                        refresh++
                    }
                }
                item { Spacer(Modifier.heightIn(min = 72.dp)) }
            }
        }
        }
    }
}

@Composable
private fun SectionTitle(text: String) {
    Text(text, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = IosColors.Gray,
        modifier = Modifier.padding(top = 12.dp).semantics { heading() })
}

/** Full width, at least 64 dp, ONE TalkBack stop that reads the whole sentence and "selected". */
@Composable
private fun BigRow(
    title: String,
    detail: String,
    selected: Boolean,
    dimmed: Boolean = false,
    note: String? = null,
    progress: Float? = null,
    actions: List<CustomAccessibilityAction> = emptyList(),
    visibleAction: Pair<String, () -> Boolean>? = null,
    onPick: () -> Unit,
) {
    val selectedWord = stringResource(R.string.e_selected)
    val notSelectedWord = stringResource(R.string.e_not_selected)
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 64.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(Color.White.copy(alpha = if (selected) 0.16f else 0.08f))
            .clickable(role = Role.RadioButton, onClick = onPick)
            .clearAndSetSemantics {
                contentDescription = if (note != null) "$title. $detail $note" else "$title. $detail"
                stateDescription = if (selected) selectedWord else notSelectedWord
                this.selected = selected
                role = Role.RadioButton
                onClick { onPick(); true }
                if (actions.isNotEmpty()) customActions = actions
            }
            .padding(14.dp),
    ) {
        Icon(
            if (selected) Icons.Default.CheckCircle else Icons.Default.RadioButtonUnchecked, null,
            tint = if (selected) Teal else IosColors.Gray, modifier = Modifier.size(26.dp),
        )
        Column(Modifier.weight(1f).padding(start = 12.dp), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(title, fontSize = 17.sp, fontWeight = FontWeight.SemiBold,
                color = if (dimmed) IosColors.Gray else Color.White)
            Text(detail, fontSize = 14.sp, color = IosColors.Gray)
            if (note != null) Text(note, fontSize = 12.sp, color = IosColors.Gray)
            if (progress != null) LinearProgressIndicator(progress = { progress }, color = Teal,
                modifier = Modifier.fillMaxWidth())
            if (visibleAction != null) Text(
                visibleAction.first, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = IosColors.Red,
                modifier = Modifier.clickable { visibleAction.second() }.padding(vertical = 4.dp),
            )
        }
    }
}

