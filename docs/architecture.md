# Architecture and data invariants

## Purpose

Codex Models is a read-only macOS menu bar monitor for local Codex threads. Its job is visibility: show which conversations exist, which sub-agents belong to them, what model and reasoning effort Codex recorded, and whether the latest run is active or finished.

## Local sources

The reader opens two SQLite files under the configured Codex directory:

- `state_5.sqlite`: `threads` supplies names, titles, models, reasoning effort, source, archive state, working directory (`cwd`), and timestamps. `thread_spawn_edges` supplies parent/child relationships.
- `thread_history_1.sqlite`: the latest `thread_turns` row supplies a fallback status: `inProgress`, `completed`, `interrupted`, or `failed`.

Older threads use `session_index.jsonl` for the latest renamed title. For every visible thread, including paginated threads and sub-agents, the reader scans the end of the rollout log in 64 KiB blocks and accepts only lifecycle events: `task_started`, `task_complete`, `turn_aborted`, and `task_failed`. The latest recognized journal event takes precedence over the history projection: after a resume, that projection can remain stuck on an older `inProgress` turn even after later turns finish. Missing, unreadable, or unrecognized journals retain the database fallback; without either source the status is unknown. No inactivity timeout guesses that a long-running task has finished.

The reader opens SQLite with `SQLITE_OPEN_READONLY`, uses a short busy timeout, and keeps the metadata/edge read in one transaction. It never writes to Codex's databases.

## Tree and filtering rules

Only named, non-archived interactive roots (`source=vscode` or `source=cli`) appear in the main list. Headless executions and empty sessions are omitted from the root list. Every archived node is removed at every depth, including archived children attached to a visible parent. Cycles in the edge table are cut during traversal.

The explicit conversation name wins over the initial title. A nameless sub-agent falls back to the final component of `agent_path`, then to its nickname, then to `Untitled conversation`.

With the completed toggle off, every `completed`, `interrupted`, or `failed` row is hidden at every depth. Its remaining children are promoted to the nearest visible ancestor (or the root list), so active work remains accessible without displaying completed parents. Turning the toggle on restores the original hierarchy. Unknown states remain visible because missing status data does not prove that a task has stopped.

## Live monitoring

`ConversationsModel` starts its serial background reader at initialization and refreshes once per second, even while the menu bar panel is closed. A read already in flight prevents another read from stacking. The published tree changes only when the snapshot changes, preserving expansion state and avoiding unnecessary UI transitions.

The first successful snapshot establishes the known sub-agent IDs without creating a notification. Later descendants whose creation timestamp is after monitor startup become unread new-agent IDs. Acknowledgement clears the badge; archived IDs are removed from it. The badge is intentionally session-scoped and does not persist across launches.

## UI and positioning

The interface uses SwiftUI `MenuBarExtra` with `.menuBarExtraStyle(.window)`, the same native presentation pattern used by [Performance Viewer](https://github.com/sanztheo/PerformanceViewer/blob/da96cbe133bcfceaa6bf7a769128f91860d28dc1/Performance/PerformanceApp.swift). macOS owns anchoring, placement, and window sizing; Codex Models does not calculate popover coordinates or manage an `NSStatusItem`/`NSPopover` pair.

The panel is intentionally compact: 330 points wide, fixed 56-point rows, and a scrollable list beyond 300 points. Running rows show a small orange spinner on the left. Completed rows show a green checkmark on the right. The main menu bar icon remains fixed; only the row spinner animates, and it pauses when Reduce Motion is enabled.

A small information button at the right of each row owns the full-title popover. Hovering that button for 400 ms shows a compact light bubble with multiline wrapping; clicking it also toggles the bubble for keyboard access. Leaving the button cancels or dismisses the bubble, and removing the row dismisses it as well. Hovering the title or the rest of the row never opens this popover, so clicking a task remains unobstructed. The same row implementation handles parents and nested sub-agents. Model metadata retains its native help text.

## Working directory

Each row displays the final component of its own `threads.cwd` beside a folder icon. This is the recorded working directory, not an inferred repository name. Children keep their own path even when filtering promotes them. Missing paths produce no folder label. The full path appears only in the information-button popover alongside the title and parent; hovering the folder or title does not open it. No extra filesystem traversal is needed.

`--check` covers paths with spaces, distinct child directories, preservation after filtering, and absent paths.

## Task navigation and running duration

Clicking a title opens `codex://threads/<UUID>` through macOS, using the thread-link route emitted by the installed Codex app. Invalid identifiers disable navigation. The separate chevron only expands or collapses children. No conversation data is sent to a web service.

Every child retains its direct parent's resolved title before filtering, including when a stopped parent is hidden and the child is promoted. The parent appears below the child's title; its full name is available in the information-button popover.

The running timer uses the timestamp on the latest `task_started` journal event, accepting ISO 8601 with or without fractional seconds. It measures the current turn, not conversation age; terminal events clear it. Missing timestamps or a database-only running status show no duration. SwiftUI's native timer text updates without extra database reads or animation loops.

Verification: `--check` covers parent context after filtering, valid/invalid navigation IDs, both timestamp formats, missing timestamps, and terminal-state timer removal. In the menu panel, click a title to open its task, use the chevron independently, and check parent text and elapsed time with Reduce Motion enabled.

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
- paginated journal completion overrides a stale running projection, updates the background count, and tracks subsequent starts, interruptions, and failures; missing journals preserve the database fallback.

The displayed model is declared runtime metadata. It does not claim to prove server-side routing after a service-level reroute.

## Remaining account quota

The menu bar label is `icon | 27%`. Keep the separator and percentage in one `Text`: the native menu bar extracts a single text label, so separate `Text` views can drop the percentage. `QuotaModel` polls immediately and every 30 seconds even with the panel closed, independently of the conversation reader. Each serial background read starts the installed Codex CLI's `app-server --stdio`, initializes JSON-RPC, and calls the documented `account/rateLimits/read` endpoint. No prompt or conversation is submitted. The existing CLI login and inherited `CODEX_HOME` are used; Codex Models does not read or log credentials. This adds an authenticated network request through Codex services, not a local token estimate.

`rateLimitsByLimitId.codex` is authoritative when the map exists; the legacy `rateLimits` response is used only when the map is absent. Spark and other buckets never stand in for the main Codex quota. Remaining percentage is `100 - usedPercent`, clamped to 0–100 and rounded down. The smallest available remaining percentage across primary and secondary is shown. Primary is not assumed to mean five hours: the service may return a weekly primary window. The tooltip shows each returned window and its reset time in local time.

A missing quota or failed refresh shows `—`, never an invented 100% or an apparently current cached value. The next poll retries automatically. Reads do not overlap; response size is bounded and each read has a 15-second timeout. The subprocess is terminated and reaped after success, error, or timeout. CLI discovery checks the user's `.local/bin`, the ChatGPT/Codex application bundles, standard Homebrew paths, and `PATH`. Users must have a signed-in Codex CLI; the app does not initiate login or redeem resets.

Verification: `--check` uses synthetic quota responses and a temporary fake CLI to cover weekly primary windows, bucket selection, limiting windows, missing quotas, stdio initialization, timeout, periodic refresh while no window exists, unavailable state, and recovery. No quota check contacts a real account. Build/install validation should separately confirm the real account value and inspect the menu bar label and native help tooltip.
