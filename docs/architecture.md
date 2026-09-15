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

## Energy and journal reading

`RolloutReader` owns journal scanning and its cache on the existing serial reader queue. Each poll checks file attributes; unchanged regular files reuse only their lifecycle status and turn-start timestamp. Size, modification date, file identity and permissions participate in invalidation. Missing or unreadable files discard the cached result and preserve the database fallback. Symlinks bypass the cache because their attributes do not describe target changes. Entries disappear when their paths leave the visible tree. A file changed during a scan is not cached.

Backward reads still use 64 KiB blocks and preserve lifecycle precedence and timestamp parsing. Each block is scanned once; fragments of a long JSONL line are assembled once at its beginning. The previous loop repeatedly copied and split the growing line, giving quadratic work on large transcript/tool-output lines. No transcript content survives a scan. Changed files are scanned backward to the latest lifecycle event; this is not an incremental tailer.

The one-second conversation cadence and 30-second quota cadence remain, including while the panel is closed. Both timers allow 10% tolerance so macOS can coalesce wakeups, following [Apple's timer energy guidance](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/Timers.html). The build enables Swift `-O` speed optimization; it does not use `-Ounchecked`, so fixture preconditions remain active. Event-driven database/journal monitoring is deferred: this correction removes the measured hot loop without changing the freshness or recovery contract.

`--check` includes a 2 MiB line, repeated unchanged polls, partial-record append/completion, in-place truncation, same-size/date file replacement, deletion and recovery. Existing fixtures continue checking live status and badges without a window. `Checks.swift` remains one cohesive executable harness despite exceeding the 300-line review signal; the journal implementation has its own responsibility in `RolloutReader.swift`.

For performance verification, sample the running process and compare CPU time over equal intervals with the panel closed. Activity Monitor's Energy Impact is a relative current score; its 12-hour average retains earlier activity and cannot immediately demonstrate an improvement. Do not equate CPU percentage with that score. Quota subprocess costs and open-panel animation are separate from the local journal reader.

Local verification on 2026-09-15 (Apple Silicon, macOS 27; Swift 6.4 with the installed macOS 26.5 SDK): the old process used 20.70 CPU seconds over 20.03 seconds (103.35%). The installed corrected process used 1.07 CPU seconds over 20.01 seconds (5.35%), then 1.91 over 35.01 seconds after settling (5.46%), with the menu panel unopened after relaunch. These are process CPU measurements during ongoing Codex activity, not battery or Energy Impact scores. The real reader returned six roots/three active tasks in 240 ms cold and 22 ms warm. Full executable checks passed, as did installed-binary hash matching and signature verification. Automated visual inspection was unavailable because the macOS UI tool timed out; this correction does not change the panel layout.

## UI and positioning

The interface uses SwiftUI `MenuBarExtra` with `.menuBarExtraStyle(.window)`, the same native presentation pattern used by [Performance Viewer](https://github.com/sanztheo/PerformanceViewer/blob/da96cbe133bcfceaa6bf7a769128f91860d28dc1/Performance/PerformanceApp.swift). macOS owns anchoring, placement, and window sizing; Codex Models does not calculate popover coordinates or manage an `NSStatusItem`/`NSPopover` pair.

The graphite panel follows the approved OpenAI-inspired mockup at a compact native scale: 330 points wide, 52-point parent rows, 36-point nested rows, and a scrollable list beyond 280 points. The header groups identity, active count, and remaining quota above the two filter segments. The Terminées segment includes stopped conversations alongside active ones, preserving the existing filter contract. There is no redundant settings menu; refresh stays in the footer and login-item settings remain in macOS System Settings.

Trees start expanded; a session-local set records only explicitly collapsed IDs, so newly arriving descendants are visible immediately. Root groups have hairline separators; nested rows use a thin tree guide and omit redundant directory/parent labels. Hover fills a row subtly. Running parents show an orange ring beside their timer; running children use a static orange dot. Other states retain explicit labels. The main menu bar icon remains fixed; only the parent ring animates, and it pauses when Reduce Motion is enabled. The panel and menu bar share one QuotaModel; opening the panel does not start a second poller. The quota progress bar displays the same remaining percentage as the menu label and disappears when unavailable.

A small information button at the right of each row owns the full-title popover. Hovering that button for 400 ms shows a compact light bubble with multiline wrapping; clicking it also toggles the bubble for keyboard access. Leaving the button cancels or dismisses the bubble, and removing the row dismisses it as well. Hovering the title or the rest of the row never opens this popover, so clicking a task remains unobstructed. The same row implementation handles parents and nested sub-agents. Model metadata retains its native help text.

## Working directory

Each top-level visible row displays the final component of its own `threads.cwd`. Nested rows keep directory details in their information popover to reduce repetition. This is the recorded working directory, not an inferred repository name. Children keep their own path even when filtering promotes them. Missing paths produce no folder label. The full path appears only in the information-button popover alongside the title and parent; hovering the folder or title does not open it. No extra filesystem traversal is needed.

`--check` covers paths with spaces, distinct child directories, preservation after filtering, and absent paths.

## Task navigation and running duration

Clicking a title opens `codex://threads/<UUID>` through macOS, using the thread-link route emitted by the installed Codex app. Invalid identifiers disable navigation. The separate chevron only expands or collapses children. No conversation data is sent to a web service.

Every child retains its direct parent's resolved title before filtering, including when a stopped parent is hidden and the child is promoted. A promoted child shows the parent below its title; nested children omit the repeated parent label. The full parent name remains available in the information-button popover in either case.

The running timer uses the timestamp on the latest `task_started` journal event, accepting ISO 8601 with or without fractional seconds. It measures the current turn, not conversation age; terminal events clear it. Missing timestamps or a database-only running status show no duration. SwiftUI's native timer text updates without extra database reads or animation loops.

Verification: `--check` covers parent context after filtering, valid/invalid navigation IDs, both timestamp formats, missing timestamps, and terminal-state timer removal. In both `--preview` and the installed menu panel, check the 330-point width, initial expanded hierarchy, chevron collapse/reopen, both filter segments, row hover and information popover, and the quota tooltip. Click a title to open its task, use the chevron independently, and check promoted parent text and elapsed time with Reduce Motion enabled. Refresh must update both existing readers; keyboard navigation must reach the filters, task links, information buttons, and footer actions.

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
