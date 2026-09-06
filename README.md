# Codex Models — Live macOS Sub-Agent Monitor

![Codex Models — live Codex sub-agent monitor](docs/assets/codex-models-banner.png)

> A minimal macOS menu bar app that shows live Codex conversations, sub-agents, models, reasoning effort, and run state.

Codex Models is a small, native SwiftUI utility for developers who run several Codex agents in parallel. It reads Codex's local metadata in read-only mode and keeps the view current without sending prompts, transcripts, or credentials anywhere.

## Features

- Live parent/child conversation tree, refreshed every second.
- Exact model and reasoning-effort metadata recorded by Codex.
- Orange spinner for running work and a green checkmark for completed work.
- Archived conversations and archived sub-agents are always hidden.
- One-click toggle for completed, non-archived conversations.
- Numbered badge for newly launched sub-agents; opening the panel acknowledges it.
- Native `MenuBarExtra` window positioning, matching the reliable macOS menu bar pattern used by Performance Viewer.
- Launch-at-login registration through `SMAppService`.
- No network access, no external dependencies, and no data export.

## Install

Requirements: macOS 13 or later and the Apple Swift toolchain.

```sh
git clone https://github.com/sanztheo/codex-models.git
cd codex-models
bash build.sh
bash Scripts/install-to-applications.sh
```

The installer copies `Codex Models.app` to `/Applications` and launches it, so Spotlight can find it by searching for **Codex Models**. On first launch, macOS registers the app as a login item. Manage that entry in **System Settings → General → Login Items**.

## Development checks

Build the local app and run the read-only fixture checks:

```sh
bash build.sh
"../Codex Models.app/Contents/MacOS/CodexModels" --check
```

`--check` covers the conversation tree, legacy metadata, archived filtering, live state changes, read errors and recovery, new-agent badge behavior, and the read-only SQLite contract.

For a regular window preview instead of the menu bar extra:

```sh
"../Codex Models.app/Contents/MacOS/CodexModels" --preview
```

## Data and privacy

The app reads two local SQLite databases under `~/.codex`:

- `state_5.sqlite` for conversation metadata and parent/child edges.
- `thread_history_1.sqlite` for the latest recorded run state.

Legacy conversations use `session_index.jsonl` for renamed titles and inspect only lifecycle events at the end of their rollout log when the newer history table has no state. Message content is not displayed or stored. The app never writes to Codex's databases and makes no network requests.

The displayed model is the model Codex recorded for that conversation. It is useful runtime evidence, but it is not a cryptographic guarantee of server-side routing after a later reroute.

## Project layout

```text
Sources/App.swift       SwiftUI views, live monitor, menu bar scene
Sources/Data.swift      Read-only SQLite reader and conversation tree
Sources/Checks.swift    Lightweight executable verification checks
Scripts/                Icon generation and /Applications installer
docs/architecture.md    Data invariants and verification notes
```

## License

MIT. See [LICENSE](LICENSE).
