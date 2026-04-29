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

## Marketplace publishing (automated on tag)

The `vscode-marketplace` job in `.github/workflows/release.yml` runs on
every `v*` push. It bumps `package.json` to the tag's version, compiles,
and runs `vsce publish`. Skips cleanly when the token secret isn't set,
so a fork can build artifacts without publishing.

**One-time setup (maintainer):**

1. Create (or reuse) a publisher in the
   [VS Code Marketplace publisher portal](https://marketplace.visualstudio.com/manage).
   The publisher id must match `vscode/package.json`'s `publisher` field
   (currently `vincentvella`).
2. In Azure DevOps, generate a Personal Access Token with the
   **Marketplace → Manage** scope. The token starts with a few letters
   then a long base32 string.
3. Add the token to this repo:
   ```sh
   gh secret set VSCODE_MARKETPLACE_TOKEN --body '<pat>'
   ```
4. Tag a release as usual; the job picks it up.

If the secret isn't set, the rest of the release pipeline still
publishes the binaries + bumps the homebrew tap. Users can install the
extension from the locally-built `.vsix` instead:

```sh
cd vscode && npm install && npm run package
code --install-extension velk-0.0.1.vsix
```

## Notes

- velk's TUI handles its own rendering (vim mode, OSC-52 clipboard, mouse,
  status line, markdown). VS Code's integrated terminal renders all of it
  natively — no webview overhead.
- `velk: Run on selection` is for short, scoped queries. The full agent
  loop with tool use is the **Open REPL** flow.
