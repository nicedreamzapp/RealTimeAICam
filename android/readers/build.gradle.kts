// On-demand reader for Russian, Ukrainian, Thai and Arabic: Tesseract4Android (Apache-2.0).
// Delivered by Play only when someone picks one of those languages (dist:on-demand), so the
// base download carries none of it. The language files come from our own server (ScriptReaders).
plugins {
    id("com.android.dynamic-feature")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.mattmacosko.realtimeaicam.readers"
    compileSdk = 36

    defaultConfig {
        minSdk = 26
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    packaging {
        // Same phones as the base app (arm64 + 32-bit arm); the library also ships x86 builds.
        jniLibs {
            excludes += listOf("lib/x86/**", "lib/x86_64/**")
            useLegacyPackaging = false
        }
    }
}

dependencies {
    implementation(project(":app"))
    implementation("com.github.adaptech-cz.Tesseract4Android:tesseract4android:4.8.0")
}
