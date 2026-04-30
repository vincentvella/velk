// velk JetBrains plugin — minimal v1, terminal-launcher only.
//
// Build a plugin .zip:    ./gradlew buildPlugin
// Output:                 build/distributions/velk-<version>.zip
// Install in IntelliJ:    Settings → Plugins → ⚙ → Install Plugin from Disk…

plugins {
    id("org.jetbrains.intellij.platform") version "2.4.0"
    kotlin("jvm") version "2.0.21"
}

group = "com.vincentvella"
version = "0.0.1"

repositories {
    mavenCentral()
    intellijPlatform { defaultRepositories() }
}

dependencies {
    intellijPlatform {
        // Pin to a recent stable IntelliJ Community release. Plugin
        // gets compiled against this and works on Community + Ultimate
        // + most JetBrains IDEs that share the platform.
        intellijIdeaCommunity("2024.3")
        // The integrated terminal lives in a bundled plugin we have
        // to depend on explicitly so its classes are on the compile
        // classpath. plugin.xml already declares the same id.
        bundledPlugin("org.jetbrains.plugins.terminal")
    }
    implementation("org.jetbrains.kotlin:kotlin-stdlib")
}

intellijPlatform {
    pluginConfiguration {
        ideaVersion {
            sinceBuild = "243"
            untilBuild = provider { null }
        }
    }
    // Publishing config — token reads from $PUBLISH_TOKEN, channel
    // from $PUBLISH_CHANNEL (default = stable Marketplace listing).
    // The CI release.yml job sets both. For manual local publishing,
    // set PUBLISH_TOKEN in your shell before running
    // `gradle publishPlugin`.
    publishing {
        token = providers.environmentVariable("PUBLISH_TOKEN")
        channels = providers.environmentVariable("PUBLISH_CHANNEL").orElse("default").map { listOf(it) }
    }
}

kotlin {
    jvmToolchain(17)
}
