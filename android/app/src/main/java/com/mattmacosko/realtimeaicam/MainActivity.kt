package com.mattmacosko.realtimeaicam

import android.Manifest
import android.content.pm.PackageManager
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.content.ContextCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import com.mattmacosko.realtimeaicam.camera.DetectionPipeline
import com.mattmacosko.realtimeaicam.detection.DetectorConfig
import com.mattmacosko.realtimeaicam.detection.YoloDetector
import com.mattmacosko.realtimeaicam.ui.AppMode
import com.mattmacosko.realtimeaicam.ui.MainScreen

class MainActivity : ComponentActivity() {

    private lateinit var pipeline: DetectionPipeline

    private var hasCameraPermission by mutableStateOf(false)
    private var appMode by mutableStateOf(AppMode.Home)

    private val permissionLauncher =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            hasCameraPermission = granted
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()

        // iOS parity: status bar hidden, content edge-to-edge (UI_SPEC §0)
        WindowCompat.setDecorFitsSystemWindows(window, false)
        WindowInsetsControllerCompat(window, window.decorView).apply {
            hide(WindowInsetsCompat.Type.statusBars())
            systemBarsBehavior =
                WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }

        // Benchmark/debug overrides (defaults: gpu + fp32, see DetectorConfig):
        //   adb shell am start -n com.mattmacosko.realtimeaicam/.MainActivity \
        //     -e model fp16 -e backend cpu -e threads 8
        val defaults = DetectorConfig()
        val config = DetectorConfig(
            modelAsset = when (intent.getStringExtra("model")) {
                "fp16" -> YoloDetector.MODEL_ASSET_FP16
                "fp32" -> YoloDetector.MODEL_ASSET_FP32
                else -> defaults.modelAsset
            },
            backend = intent.getStringExtra("backend") ?: defaults.backend,
            numThreads = intent.getStringExtra("threads")?.toIntOrNull() ?: defaults.numThreads,
        )
        pipeline = DetectionPipeline(this, config)

        hasCameraPermission = ContextCompat.checkSelfPermission(
            this, Manifest.permission.CAMERA
        ) == PackageManager.PERMISSION_GRANTED

        if (!hasCameraPermission) {
            permissionLauncher.launch(Manifest.permission.CAMERA)
        }

        setContent {
            MainScreen(
                mode = appMode,
                onModeChange = { appMode = it },
                hasCameraPermission = hasCameraPermission,
                onRequestPermission = { permissionLauncher.launch(Manifest.permission.CAMERA) },
                pipeline = pipeline,
                versionLabel = versionLabel(),
            )
        }
    }

    override fun onStop() {
        super.onStop()
        // iOS parity: backgrounding fully resets to Home (UI_SPEC §9)
        appMode = AppMode.Home
    }

    override fun onDestroy() {
        super.onDestroy()
        pipeline.shutdown()
    }

    private fun versionLabel(): String {
        val pInfo = packageManager.getPackageInfo(packageName, 0)
        @Suppress("DEPRECATION")
        return "v${pInfo.versionName} (${pInfo.versionCode})"
    }
}
