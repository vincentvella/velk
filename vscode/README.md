# velk VS Code extension

Minimal extension that launches the [velk](https://github.com/vincentvella/velk)
terminal AI harness in a VS Code terminal panel.

## Commands

- **`velk: Open REPL`** — opens (or focuses) a terminal panel running `velk`.
  Reuses the existing panel if you've already opened one.
- **`velk: Run on selection`** — prompts for a one-shot instruction, sends
  the current editor selection (or the whole file) along with it, and
  streams velk's stdout into a fresh `velk` Output Channel.

## Settings

| key                | default | what                                                                      |
| ------------------ | ------- | ------------------------------------------------------------------------- |
| `velk.binaryPath`  | `velk`  | Path to the velk binary. Override if velk isn't on `PATH`.                |
| `velk.extraArgs`   | `[]`    | Args passed on every launch (e.g. `["--model","claude-opus-4-7"]`).       |

## Build + install (local)

```sh
cd vscode
npm install
npm run package      # → produces velk-<version>.vsix

# Install into your local VS Code:
code --install-extension velk-0.0.1.vsix
```

## Notes

- velk's TUI handles its own rendering (vim mode, OSC-52 clipboard, mouse,
  status line, markdown). VS Code's integrated terminal renders all of it
  natively — no webview overhead.
- `velk: Run on selection` is for short, scoped queries. The full agent
  loop with tool use is the **Open REPL** flow.
- Marketplace publishing is a follow-up. Today the extension installs from
  a locally-built `.vsix`.
