package com.vincentvella.velk

import com.intellij.openapi.options.Configurable
import com.intellij.ui.components.JBLabel
import com.intellij.ui.components.JBTextField
import java.awt.GridBagConstraints
import java.awt.GridBagLayout
import java.awt.Insets
import javax.swing.JComponent
import javax.swing.JPanel

/**
 * Settings → Tools → velk panel. Two fields:
 *   Binary path:  defaults to "velk" (i.e. on PATH).
 *   Extra args:   space-separated; passed verbatim on every launch.
 */
class VelkConfigurable : Configurable {
    private val binaryPath = JBTextField()
    private val extraArgs = JBTextField()
    private var ui: JPanel? = null

    override fun getDisplayName(): String = "velk"

    override fun createComponent(): JComponent {
        val panel = JPanel(GridBagLayout())
        val gbc = GridBagConstraints()
        gbc.insets = Insets(4, 4, 4, 4)
        gbc.anchor = GridBagConstraints.WEST

        gbc.gridx = 0; gbc.gridy = 0
        panel.add(JBLabel("Binary path:"), gbc)
        gbc.gridx = 1; gbc.fill = GridBagConstraints.HORIZONTAL; gbc.weightx = 1.0
        binaryPath.toolTipText = "Path to velk binary. Defaults to 'velk' on PATH."
        panel.add(binaryPath, gbc)

        gbc.gridx = 0; gbc.gridy = 1; gbc.fill = GridBagConstraints.NONE; gbc.weightx = 0.0
        panel.add(JBLabel("Extra args:"), gbc)
        gbc.gridx = 1; gbc.fill = GridBagConstraints.HORIZONTAL; gbc.weightx = 1.0
        extraArgs.toolTipText = "Space-separated args appended to every velk invocation."
        panel.add(extraArgs, gbc)

        reset()
        ui = panel
        return panel
    }

    override fun isModified(): Boolean {
        val s = VelkSettings.getInstance().state
        return binaryPath.text != s.binaryPath ||
            extraArgs.text != s.extraArgs.joinToString(" ")
    }

    override fun apply() {
        val s = VelkSettings.getInstance().state
        s.binaryPath = binaryPath.text.trim().ifEmpty { "velk" }
        s.extraArgs = extraArgs.text.trim()
            .split(Regex("\\s+"))
            .filter { it.isNotEmpty() }
            .toMutableList()
    }

    override fun reset() {
        val s = VelkSettings.getInstance().state
        binaryPath.text = s.binaryPath
        extraArgs.text = s.extraArgs.joinToString(" ")
    }

    override fun disposeUIResources() {
        ui = null
    }
}
