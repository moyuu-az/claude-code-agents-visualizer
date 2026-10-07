# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org).
Each release on GitHub uses its section below as release notes.

## [0.1.0] - 2026-10-07

The first release: every Claude Code session on your Mac, on one screen.

### Added

- **Dashboard** (⌘1): every Claude Code session grouped by project, with live status — *Needs input*, *Running*,
  *Done* (turn finished, waiting for your next prompt) or *Ended*. Git worktrees fold into their main repository.
- **Subagents** of live sessions as a tree under each session: type, description, live stopwatch, the tool in
  flight, and how each one ended (completed, failed, stopped, interrupted).
- **Agent graph** (⌘2): projects → sessions → agents as a living network. Particles flow along the paths where
  work is happening, each node shows its model (e.g. `Opus 5.5 · xhigh`), and an activity log lists agents
  starting and finishing and sessions starting, finishing turns or needing you.
- **One click opens the session in Claude for Mac.** Sessions started in a terminal or IDE are imported after a
  confirmation, or you can copy the `claude --resume` command instead.
- **Menu bar extra** with the number of sessions that need you and a list of live sessions.
- Liquid Glass design on macOS 26 (translucent materials on macOS 14 and 15), light and dark mode,
  English and Japanese, VoiceOver labels, Reduce Motion support.
- Filters (live / 24 hours / 7 days / all) and search across titles, projects, paths, branches and agents.
- Read-only by design: no network requests, no writes to Claude Code's or Claude for Mac's files. Continuous
  animations run in Core Animation, so the app stays near 0% CPU while agents work.

### 日本語

Mac 上のすべての Claude Code セッションを 1 画面で俯瞰する、最初のリリースです。

- **ダッシュボード**（⌘1）: セッションをプロジェクトごとに表示し、状態（入力待ち / 実行中 / 完了 / 終了）を
  リアルタイムに更新します。git worktree はメインのリポジトリにまとめます。
- **サブエージェント**: 稼働中のセッションの下にツリーで表示します（種類、説明、経過時間、実行中のツール、終わり方）。
- **エージェントグラフ**（⌘2）: プロジェクト → セッション → エージェントのネットワーク図です。作業中の経路には
  光る粒子が流れ、各ノードにモデル名を表示します。アクティビティログにはエージェントの起動・完了や、
  セッションの状態の変化が流れます。
- **クリックで Claude for Mac のセッションを開けます**。ターミナルや IDE で始めたセッションは、確認のうえで
  取り込みます。
- メニューバーに入力待ちの件数と稼働中のセッションの一覧を表示します。
- Liquid Glass（macOS 26）、ライト / ダーク、英語 / 日本語、VoiceOver、「視差効果を減らす」に対応しています。
- 読み取り専用で、ネットワーク通信はしません。

### Install / インストール

Download `ClaudeCodeAgentsVisualizer-0.1.0.dmg` and drag the app to Applications (or unzip the `.zip`).
The app is ad-hoc signed and not notarized: on the first launch macOS blocks it. Open **System Settings ›
Privacy & Security** and click **Open Anyway** (on macOS 14, right-click the app and choose **Open**).
Verify downloads with `SHA256SUMS.txt`.

`ClaudeCodeAgentsVisualizer-0.1.0.dmg` を開いてアプリを「アプリケーション」へドラッグしてください（`.zip` を
展開しても使えます）。公証されていないため、初回起動は macOS にブロックされます。**システム設定 › プライバシーと
セキュリティ** で **このまま開く** を選んでください（macOS 14 では右クリックして **開く**）。
`SHA256SUMS.txt` でファイルを検証できます。

Requires macOS 14 or later and Claude Code. Opening sessions needs Claude for Mac.
動作環境は macOS 14 以降と Claude Code です。セッションを開くには Claude for Mac が必要です。

[0.1.0]: https://github.com/moyuu-az/claude-code-agents-visualizer/releases/tag/v0.1.0
