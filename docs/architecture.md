# Architecture and data invariants

## Purpose

Codex Models is a read-only macOS menu bar monitor for local Codex threads. Its job is visibility: show which conversations exist, which sub-agents belong to them, what model and reasoning effort Codex recorded, and whether the latest run is active or finished.

## Local sources

The reader opens two SQLite files under the configured Codex directory:

- `state_5.sqlite`: `threads` supplies names, titles, models, reasoning effort, source, archive state, and timestamps. `thread_spawn_edges` supplies parent/child relationships.
- `thread_history_1.sqlite`: the latest `thread_turns` row supplies `inProgress`, `completed`, `interrupted`, or `failed`.

Older `legacy` threads may not have a projected turn. For those threads, `session_index.jsonl` supplies the latest renamed title. If the history table has no state, the reader scans the end of the rollout log in 64 KiB blocks and accepts only lifecycle events: `task_started`, `task_complete`, `turn_aborted`, and `task_failed`.

The reader opens SQLite with `SQLITE_OPEN_READONLY`, uses a short busy timeout, and keeps the metadata/edge read in one transaction. It never writes to Codex's databases.

## Tree and filtering rules

Only named, non-archived interactive roots (`source=vscode` or `source=cli`) appear in the main list. Headless executions and empty sessions are omitted from the root list. Every archived node is removed at every depth, including archived children attached to a visible parent. Cycles in the edge table are cut during traversal.

The explicit conversation name wins over the initial title. A nameless sub-agent falls back to the final component of `agent_path`, then to its nickname, then to `Untitled conversation`.

The completed toggle filters only non-archived `completed` leaves. A completed parent stays visible when it still contains a visible child, so active work never loses its context. Unknown, interrupted, and failed states remain visible.

## Live monitoring

`ConversationsModel` starts its serial background reader at initialization and refreshes once per second, even while the menu bar panel is closed. A read already in flight prevents another read from stacking. The published tree changes only when the snapshot changes, preserving expansion state and avoiding unnecessary UI transitions.

The first successful snapshot establishes the known sub-agent IDs without creating a notification. Later descendants whose creation timestamp is after monitor startup become unread new-agent IDs. Acknowledgement clears the badge; archived IDs are removed from it. The badge is intentionally session-scoped and does not persist across launches.

## UI and positioning

The interface uses SwiftUI `MenuBarExtra` with `.menuBarExtraStyle(.window)`, the same native presentation pattern used by [Performance Viewer](https://github.com/sanztheo/PerformanceViewer/blob/da96cbe133bcfceaa6bf7a769128f91860d28dc1/Performance/PerformanceApp.swift). macOS owns anchoring, placement, and window sizing; Codex Models does not calculate popover coordinates or manage an `NSStatusItem`/`NSPopover` pair.

The panel is intentionally compact: 330 points wide, fixed 44-point rows, and a scrollable list beyond 300 points. Running rows show a small orange spinner on the left. Completed rows show a green checkmark on the right. The main menu bar icon remains fixed; only the row spinner animates, and it pauses when Reduce Motion is enabled.

## Login item

The main app calls `SMAppService.mainApp.register()` on first launch, matching the native macOS login-item mechanism used by Performance Viewer. Users can disable it in System Settings → General → Login Items.

## Verification

`--check` builds temporary SQLite fixtures and verifies:

- hierarchy, names, models, and reasoning effort;
- running → completed updates while the panel is closed;
- archived roots and children are hidden;
- completed filtering preserves active descendants;
- missing history produces `Unknown` instead of an invented state;
- read errors surface and recover automatically;
- the reader cannot write to SQLite;
- new-agent badge behavior follows `0 → 4 → 0 → 1 → 0` without duplicates or historical notifications;
- legacy title renames and lifecycle state are recovered across a block boundary.

The displayed model is declared runtime metadata. It does not claim to prove server-side routing after a service-level reroute.
