package com.vincentvella.velk

import com.intellij.openapi.application.ApplicationManager
import com.intellij.openapi.components.PersistentStateComponent
import com.intellij.openapi.components.Service
import com.intellij.openapi.components.State
import com.intellij.openapi.components.Storage

/**
 * Application-level settings persisted under
 * `~/Library/Application Support/JetBrains/<ide>/options/velk.xml`
 * (or the equivalent on Linux/Windows).
 */
@State(name = "VelkSettings", storages = [Storage("velk.xml")])
@Service(Service.Level.APP)
class VelkSettings : PersistentStateComponent<VelkSettings.State> {
    data class State(
        var binaryPath: String = "velk",
        var extraArgs: MutableList<String> = mutableListOf(),
    )

    private var state = State()

    override fun getState(): State = state
    override fun loadState(s: State) {
        state = s
    }

    companion object {
        fun getInstance(): VelkSettings =
            ApplicationManager.getApplication().getService(VelkSettings::class.java)
    }
}
