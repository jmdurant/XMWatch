plugins { id("com.android.application") version "9.1.1" }
android {
    enableKotlin = false
    namespace = "xmwatch.testing"
    compileSdk = 36
    defaultConfig {
        applicationId = "com.doctordurant.xmwatch.controllerprobe"
        minSdk = 28
        targetSdk = 36
        versionCode = 1
        versionName = "1"
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}
// Platform APIs only. No target application, AndroidX, Kotlin or test runtime dependency.
