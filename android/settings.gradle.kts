pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
        // Tesseract4Android (Apache-2.0) is published only on JitPack; only that group comes from it.
        maven {
            url = uri("https://jitpack.io")
            content { includeGroup("com.github.adaptech-cz.Tesseract4Android") }
        }
    }
}

rootProject.name = "RealTime AI Cam"
include(":app")
include(":vision_model")
// On-demand reader for Russian, Ukrainian, Thai and Arabic (Tesseract), never in the base download.
include(":readers")
