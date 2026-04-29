# velk JetBrains plugin

Minimal plugin that launches [velk](https://github.com/vincentvella/velk)
in a JetBrains terminal panel. Works in IntelliJ IDEA, PyCharm, GoLand,
WebStorm, RubyMine, CLion, Rider, and the rest of the JetBrains
platform-based IDEs (2024.3+).

## Action

- **Tools → velk: Open REPL** — opens a JetBrains terminal tab running
  `velk` in the project's working directory.

## Settings

**Settings → Tools → velk**:

| field          | default | what                                                              |
| -------------- | ------- | ----------------------------------------------------------------- |
| Binary path    | `velk`  | Override if velk isn't on `PATH`.                                 |
| Extra args     | empty   | Space-separated; passed on every launch (e.g. `--repo-map`).      |

## Build + install (local)

Requires JDK 17+ and Gradle 8+ on `PATH` (`brew install gradle openjdk@17` on
macOS, or use Homebrew-managed `jenv`).

```sh
cd jetbrains
gradle buildPlugin
# → build/distributions/velk-0.0.1.zip
```

A Gradle wrapper (`./gradlew`) is intentionally not vendored — adding the
~60 KB jar to a Zig repo is more clutter than convenience for the JetBrains
plugin's tiny user base. If you want one, run `gradle wrapper` once and
commit it to your fork.

Then in any JetBrains IDE:
**Settings → Plugins → ⚙ → Install Plugin from Disk…** and pick the
`.zip`.

## Marketplace publishing (automated on tag)

The `jetbrains-marketplace` job in `.github/workflows/release.yml` runs
on every `v*` push. It bumps the `version = …` line in
`build.gradle.kts` to the tag, then runs `gradle publishPlugin`. Skips
cleanly when the token secret isn't set.

**One-time setup (maintainer):**

1. Create (or join) a vendor on the
   [JetBrains Marketplace](https://plugins.jetbrains.com/) and verify
   ownership of the `com.vincentvella.velk` plugin id (matches
   `plugin.xml`).
2. Generate a permanent token under
   **Profile → My Tokens → Generate New Token**.
3. Add it to the repo:
   ```sh
   gh secret set JETBRAINS_MARKETPLACE_TOKEN --body '<token>'
   ```
4. Optional: choose a release channel (`default`, `eap`, `beta`) via a
   repo variable:
   ```sh
   gh variable set JETBRAINS_PUBLISH_CHANNEL --body 'default'
   ```
5. Tag a release as usual; the job picks it up.

If the secret isn't set, the rest of the release pipeline still
publishes the binaries + bumps the homebrew tap. Users can install
the plugin from a locally-built `.zip` instead.

## Notes

- Reuses the existing JetBrains integrated terminal — no custom
  rendering. velk's TUI handles vim mode, mouse, OSC-52 clipboard,
  and markdown rendering natively.
- Supports IntelliJ Platform 2024.3+ (build 243+). Earlier builds may
  work but aren't tested.
