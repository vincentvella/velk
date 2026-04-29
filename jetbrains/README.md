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

## Notes

- Reuses the existing JetBrains integrated terminal — no custom
  rendering. velk's TUI handles vim mode, mouse, OSC-52 clipboard,
  and markdown rendering natively.
- Marketplace publishing is a follow-up. Today the plugin installs
  from a locally-built `.zip`.
- Supports IntelliJ Platform 2024.3+ (build 243+). Earlier builds may
  work but aren't tested.
