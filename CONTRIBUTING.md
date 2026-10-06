# Contributing

Thanks for helping! Issues and pull requests are welcome in English or Japanese.

## Setup

Xcode is optional: the Swift toolchain from the Command Line Tools (`xcode-select --install`) builds and tests
everything.

```bash
scripts/test.sh            # unit and integration tests (swift-testing)
swift build                # debug build
scripts/build-app.sh       # release .app in build/
python3 scripts/demo.py    # run the app against made-up sessions
```

## Ground rules

- **Read-only.** The app must never write to `~/.claude` or Claude for Mac's files, and must not make network
  requests.
- **Never trust the files.** They are internal formats that change without notice. Decode leniently, skip what
  cannot be read, and never let one bad file break the dashboard. Validate anything that ends up in a URL or a
  shell command.
- **Tests first for bugs.** A bug fix starts with a test in `Tests/AgentsVisualizerCoreTests` that fails without
  the fix. Status logic changes need tests for the normal case, failures and edge cases.
- **No per-frame SwiftUI work.** Continuous animations go through Core Animation
  (`Sources/AgentsVisualizer/LayerAnimations.swift`); a SwiftUI `TimelineView` or `repeatForever` animation
  re-lays out the whole dashboard every frame. Check `ps -o %cpu= -p <pid>` stays near 0 while agents run.
- **No `@State` attribute.** On the macOS 27 SDK it is a macro whose plugin ships only with Xcode; store a
  `State` value instead (see `AgentList`).
- **Screenshots use demo data** (`scripts/demo.py`), never your real sessions.
- Commits follow [Conventional Commits](https://www.conventionalcommits.org) (`feat:`, `fix:`, `docs:`, …).

## Reporting a misread session

`AgentsVisualizer --dump-json` (the binary inside the app bundle) prints what the dashboard sees. Redact titles
and paths before attaching it to an issue, and mention your Claude Code version (`claude --version`).
