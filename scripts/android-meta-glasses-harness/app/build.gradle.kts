plugins { id("com.android.application") version "9.1.1" }
android {
    enableKotlin = false
    namespace = "com.doctordurant.xmwatch.metareleaseharness"
    compileSdk = 36
    defaultConfig {
        applicationId = "com.doctordurant.xmwatch.metareleaseharness"
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
// Framework-only instrumentation cannot shadow the target's R8 runtime.
