// velk VS Code extension — minimal v1.
//
// Two commands:
//   - velk.openRepl       Launches a VS Code terminal panel running velk.
//   - velk.runOnSelection Sends the current editor selection (or whole file)
//                         to velk as a one-shot prompt and shows the output.
//
// We deliberately do not embed velk in a webview. The TUI already does its
// own rendering (vim mode, OSC-52 clipboard, mouse, status line, etc.) and
// VS Code's integrated terminal handles all of that natively.

import * as vscode from 'vscode';
import { spawn } from 'child_process';

interface Config {
  binaryPath: string;
  extraArgs: string[];
}

function readConfig(): Config {
  const c = vscode.workspace.getConfiguration('velk');
  return {
    binaryPath: c.get<string>('binaryPath', 'velk'),
    extraArgs: c.get<string[]>('extraArgs', []),
  };
}

function workspaceCwd(): string | undefined {
  const folders = vscode.workspace.workspaceFolders;
  if (!folders || folders.length === 0) {
    return undefined;
  }
  return folders[0].uri.fsPath;
}

/** velk.openRepl — open (or focus) a terminal panel running `velk`. */
function openRepl() {
  const cfg = readConfig();
  const cwd = workspaceCwd();
  const existing = vscode.window.terminals.find((t) => t.name === 'velk');
  if (existing) {
    existing.show();
    return;
  }
  const term = vscode.window.createTerminal({
    name: 'velk',
    shellPath: cfg.binaryPath,
    shellArgs: cfg.extraArgs,
    cwd,
  });
  term.show();
}

/** velk.runOnSelection — one-shot prompt with the current selection.
 *
 *  If there's no selection, the whole document is used. We invoke
 *  `velk --no-tui --max-cost 1.00 -- <prompt>` and stream its stdout
 *  into a fresh OutputChannel so the user can see the response without
 *  losing focus on the editor. */
async function runOnSelection() {
  const editor = vscode.window.activeTextEditor;
  if (!editor) {
    vscode.window.showInformationMessage('velk: no active editor');
    return;
  }
  const sel = editor.selection;
  const text = sel.isEmpty ? editor.document.getText() : editor.document.getText(sel);
  if (text.trim().length === 0) {
    vscode.window.showInformationMessage('velk: selection is empty');
    return;
  }

  const promptInput = await vscode.window.showInputBox({
    prompt: 'velk prompt (selection will be appended)',
    placeHolder: 'e.g. "explain this", "find the bug", "rewrite as iterator"',
  });
  if (promptInput === undefined) {
    return;
  }

  const cfg = readConfig();
  const channel = vscode.window.createOutputChannel('velk');
  channel.show(true);
  channel.appendLine(`▶ ${cfg.binaryPath} --no-tui ${cfg.extraArgs.join(' ')} <prompt>`);
  channel.appendLine('');

  const fullPrompt = `${promptInput}\n\n---\n${text}`;
  const args = ['--no-tui', ...cfg.extraArgs, fullPrompt];
  const child = spawn(cfg.binaryPath, args, {
    cwd: workspaceCwd(),
    env: process.env,
  });
  child.stdout.on('data', (b: Buffer) => channel.append(b.toString('utf8')));
  child.stderr.on('data', (b: Buffer) => channel.append(b.toString('utf8')));
  child.on('close', (code) => {
    channel.appendLine('');
    channel.appendLine(`▶ exited ${code}`);
  });
  child.on('error', (err) => {
    channel.appendLine(`velk: spawn failed: ${err.message}`);
    vscode.window.showErrorMessage(
      `velk: failed to spawn '${cfg.binaryPath}'. Set velk.binaryPath in settings.`
    );
  });
}

export function activate(context: vscode.ExtensionContext) {
  context.subscriptions.push(
    vscode.commands.registerCommand('velk.openRepl', openRepl),
    vscode.commands.registerCommand('velk.runOnSelection', runOnSelection)
  );
}

export function deactivate() {}
