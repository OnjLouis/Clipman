plugins {
    id("com.android.application") version "8.7.3" apply false
    id("org.jetbrains.kotlin.android") version "2.0.21" apply false
    id("org.jetbrains.kotlin.plugin.compose") version "2.0.21" apply false
    id("org.jetbrains.kotlin.plugin.serialization") version "2.0.21" apply false
}

val clipmanBuildRoot = providers.gradleProperty("clipmanBuildRoot").orNull
if (!clipmanBuildRoot.isNullOrBlank()) {
    allprojects {
        layout.buildDirectory.set(file("$clipmanBuildRoot/$name"))
    }
}
