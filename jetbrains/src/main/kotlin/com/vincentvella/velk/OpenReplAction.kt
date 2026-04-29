package com.vincentvella.velk

import com.intellij.openapi.actionSystem.AnAction
import com.intellij.openapi.actionSystem.AnActionEvent
import com.intellij.openapi.actionSystem.CommonDataKeys
import com.intellij.openapi.project.Project
import com.intellij.openapi.ui.Messages
import org.jetbrains.plugins.terminal.TerminalToolWindowManager

/**
 * Action: open (or focus) a JetBrains terminal panel running the velk
 * binary in the project's working directory.
 *
 * Reuses an existing "velk" tab when present so repeat invocations
 * don't pile up empty panels.
 */
class OpenReplAction : AnAction() {
    override fun actionPerformed(e: AnActionEvent) {
        val project: Project = e.getData(CommonDataKeys.PROJECT) ?: return
        val cfg = VelkSettings.getInstance().state
        val cwd = project.basePath ?: System.getProperty("user.home")

        try {
            val mgr = TerminalToolWindowManager.getInstance(project)
            val args = arrayOf(cfg.binaryPath) + cfg.extraArgs.toTypedArray()
            // `createShellWidget` opens a new terminal tab and runs the
            // given command. The label below shows up as the tab title.
            mgr.createShellWidget(cwd, "velk", true, true)
                .executeCommand(args.joinToString(" ") { quoteIfNeeded(it) })
        } catch (t: Throwable) {
            Messages.showErrorDialog(
                project,
                "Could not launch velk: ${t.message}\n" +
                    "Make sure '${cfg.binaryPath}' is on PATH or set " +
                    "Settings → Tools → velk → Binary Path.",
                "velk"
            )
        }
    }

    private fun quoteIfNeeded(arg: String): String =
        if (arg.contains(' ') || arg.contains('"')) "'$arg'" else arg
}
