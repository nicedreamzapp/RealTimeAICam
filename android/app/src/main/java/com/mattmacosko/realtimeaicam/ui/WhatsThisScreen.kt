package com.mattmacosko.realtimeaicam.ui

import android.content.Context
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageCapture
import androidx.camera.core.ImageCaptureException
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import com.mattmacosko.realtimeaicam.camera.SpeechAnnouncer
import com.mattmacosko.realtimeaicam.narrator.NarratorEngine
import com.mattmacosko.realtimeaicam.narrator.NarratorPrompt
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import java.io.File
import kotlin.coroutines.resume

/**
 * One photo, one spoken answer. The iPhone's "What's this?" screen, rebuilt on
 * llama.cpp: press the button, the model looks at the shot and says what it is.
 * Everything runs on the phone — no network call anywhere in this file.
 */
@Composable
fun WhatsThisScreen(onBack: () -> Unit) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val scope = rememberCoroutineScope()

    val speech = remember { SpeechAnnouncer(context) }
    val engine = remember { NarratorEngine.get(context) }
    var status by remember { mutableStateOf("Getting ready…") }
    var busy by remember { mutableStateOf(false) }
    var answer by remember { mutableStateOf("") }

    val imageCapture = remember {
        ImageCapture.Builder()
            .setCaptureMode(ImageCapture.CAPTURE_MODE_MINIMIZE_LATENCY)
            .build()
    }

    // Loading 736 MB takes a moment; do it while the user is still aiming.
    LaunchedEffect(Unit) {
        val ok = withContext(Dispatchers.IO) { engine.ensureLoaded() }
        status = if (ok) "Point at anything and press the button" else MODEL_MISSING
    }

    DisposableEffect(Unit) {
        onDispose {
            speech.stop()
            speech.shutdown()
        }
    }

    Box(Modifier.fillMaxSize().background(Color.Black)) {
        AndroidView(
            factory = { ctx ->
                PreviewView(ctx).apply {
                    scaleType = PreviewView.ScaleType.FILL_CENTER
                    bindCamera(ctx, this, lifecycleOwner, imageCapture)
                }
            },
            modifier = Modifier.fillMaxSize(),
        )

        Column(
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .fillMaxWidth()
                .navigationBarsPadding()
                .padding(16.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            if (answer.isNotEmpty()) {
                Text(
                    answer,
                    color = Color.White,
                    fontSize = 18.sp,
                    modifier = Modifier
                        .clip(RoundedCornerShape(14.dp))
                        .background(Color(0xCC000000))
                        .padding(14.dp),
                )
            }
            Text(status, color = Color(0xFFBBBBBB), fontSize = 15.sp)

            ModeButton(
                IosColors.Purple, scale = 1f, screenWidth = 390.dp,
                onClick = {
                    if (busy) return@ModeButton
                    busy = true
                    answer = ""
                    status = "Working it out…"
                    scope.launch {
                        val said = runOnce(context, engine, imageCapture)
                        answer = said
                        status = if (said.isEmpty()) {
                            "Could not read that one. Try again."
                        } else {
                            "Point at anything and press the button"
                        }
                        if (said.isNotEmpty()) speech.speak(said)
                        busy = false
                    }
                },
                label = "What's this?",
                clickLabel = "Take a photo and hear what it is",
            ) {
                Text("What's this?", color = Color.White,
                     fontSize = 22.sp, fontWeight = FontWeight.SemiBold)
            }
        }

        Box(Modifier.align(Alignment.TopStart).padding(12.dp)) { BackPill(onBack) }
    }
}

private const val MODEL_MISSING =
    "The vision model is not installed on this phone yet."

/** Capture → decide page or scene → ask the model. All off the main thread. */
private suspend fun runOnce(
    context: Context,
    engine: NarratorEngine,
    imageCapture: ImageCapture,
): String {
    val photo = File(context.cacheDir, "whats-this.jpg")
    if (!takePhoto(context, imageCapture, photo)) return ""
    // The iPhone routes paper to the strict mail reader and everything else to
    // the scene describer. ML Kit standing in for document detection: a page is
    // a shot with real printed text on it.
    val question = if (looksLikeAPage(context, photo)) {
        NarratorPrompt.PAGE_QUESTION
    } else {
        NarratorPrompt.SCENE_QUESTION
    }
    return withContext(Dispatchers.IO) { engine.describe(photo, question) }
}

private suspend fun takePhoto(
    context: Context,
    imageCapture: ImageCapture,
    target: File,
): Boolean = suspendCancellableCoroutine { cont ->
    val options = ImageCapture.OutputFileOptions.Builder(target).build()
    imageCapture.takePicture(
        options,
        ContextCompat.getMainExecutor(context),
        object : ImageCapture.OnImageSavedCallback {
            override fun onImageSaved(result: ImageCapture.OutputFileResults) {
                if (cont.isActive) cont.resume(true)
            }
            override fun onError(exc: ImageCaptureException) {
                if (cont.isActive) cont.resume(false)
            }
        },
    )
}

private suspend fun looksLikeAPage(context: Context, photo: File): Boolean =
    suspendCancellableCoroutine { cont ->
        try {
            val image = InputImage.fromFilePath(context, android.net.Uri.fromFile(photo))
            TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)
                .process(image)
                .addOnSuccessListener { text ->
                    val lines = text.textBlocks.sumOf { it.lines.size }
                    if (cont.isActive) cont.resume(lines >= 3 && text.text.length >= 20)
                }
                .addOnFailureListener { if (cont.isActive) cont.resume(false) }
        } catch (t: Throwable) {
            if (cont.isActive) cont.resume(false)
        }
    }

private fun bindCamera(
    context: Context,
    previewView: PreviewView,
    lifecycleOwner: androidx.lifecycle.LifecycleOwner,
    imageCapture: ImageCapture,
) {
    val future = ProcessCameraProvider.getInstance(context)
    future.addListener({
        val provider = future.get()
        val preview = Preview.Builder().build()
            .also { it.setSurfaceProvider(previewView.surfaceProvider) }
        provider.unbindAll()
        provider.bindToLifecycle(
            lifecycleOwner, CameraSelector.DEFAULT_BACK_CAMERA, preview, imageCapture,
        )
    }, ContextCompat.getMainExecutor(context))
}
