plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
    id("org.jetbrains.kotlin.plugin.serialization")
}

val sharedBuildInfo = file("../../src/BuildInfo.cs").readText()
val sharedBuildStamp = Regex("BuildStampUtcMs\\s*=\\s*(\\d+)L")
    .find(sharedBuildInfo)
    ?.groupValues
    ?.get(1)
    ?: error("Could not read the shared Clipman build stamp.")

android {
    namespace = "me.onj.clipman"
    compileSdk = 35

    defaultConfig {
        applicationId = "me.onj.clipman"
        minSdk = 26
        targetSdk = 35
        versionCode = 4
        versionName = "2.0.4"
        buildConfigField("String", "CLIPMAN_BUILD_STAMP_UTC_MS", "\"$sharedBuildStamp\"")
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

kotlin {
    jvmToolchain(17)
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2024.12.01")
    implementation(composeBom)
    androidTestImplementation(composeBom)

    implementation("androidx.activity:activity-compose:1.10.0")
    implementation("androidx.biometric:biometric:1.1.0")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.7")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")

    debugImplementation("androidx.compose.ui:ui-tooling")
}
