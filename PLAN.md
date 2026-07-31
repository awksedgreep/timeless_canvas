# TimelessCanvas Improvement Plan

Phased overhaul addressing performance at high series cardinality (~1M series),
browser/input compatibility, usability, and test coverage. Based on a full code
review performed 2026-07-31.

Status legend: `[x]` done · `[ ]` pending

## Phase 0 — Test foundation ✅ (2026-07-31)

- [x] `test/support/` harness: test Phoenix endpoint + router mounting `live_canvas`,
      session-based test auth hook, Agent-backed `FakePersistence` (all 13 callbacks,
      `seed_canvas/1`), ETS-programmable `FakeDataSource` (`put(fun, value)`),
      icon placeholder seeding (Iconify raises without generated assets)
- [x] 97 unit tests: `Canvas`, `History`, `Serializer`, `ViewBox`,
      `VariableResolver`, `Element`, `MetricFormatter` (`async: true`)
- [x] 20 LiveViewTest smoke tests: mount/render, auth paths, placement, move,
      delete/undo/redo, save round-trip, data-source error tolerance
      (`async: false` — shared Manager/StreamManager singletons)
- [x] CI: `.github/workflows/ci.yml` — format check, `--warnings-as-errors`, tests
- [x] New test-only dep: `lazy_html` (required by phoenix_live_view 1.2 test helpers)

## Phase 1 — Server-side performance (the 1M-series killers)

- [ ] Bounded query contract on the `DataSource` behaviour:
      `list_hosts(filter, limit)`, `list_label_values(label, filter, limit)`,
      `list_series(metric, matchers, limit)`; implement in
      `timeless_stack/lib/timeless_stack/ui_data_source.ex` with ETS cache + TTL
      background refresh (today: N+1 full-store scans per call — `ui_data_source.ex:145-193`)
- [ ] Execute queries in the caller process (config via ETS/persistent_term);
      `DataSource.Manager` keeps only registration state (today every query from
      every client serializes through one GenServer — `manager.ex:186-206`)
- [ ] Batch host status checks into one grouped logs query per tick
      (today: up to 2 log queries per host element per tick — `ui_data_source.ex:309-336`)
- [ ] Cap `available_series` at the assign boundary + group by metric + typeahead
      (uncapped at `canvas_live.ex:3487-3502`, rendered element-per-series 3×)
- [ ] Remove `all_hosts` / per-variable option universes from socket assigns;
      route `ta:filter` to bounded server-side queries (`canvas_live.ex:121,1246-1263`)
- [ ] Async mount: data loading behind `connected?/1` + `start_async`, skeleton
      states (today mount runs 4-8 full scans synchronously before first paint)

## Phase 2 — Render path and polling

- [ ] Per-canvas shared poller process: batch element queries per tick, broadcast
      on per-canvas PubSub topics; LiveViews merge only changed entries
      (today: N clients × G graphs × sequential queries every 2s — `canvas_live.ex:2545,2743`)
- [ ] Client-side graph updates: `push_event` point deltas into a
      `phx-update="ignore"` region; remove per-render `Jason.encode!` data
      attributes (`canvas_components.ex:539-689,203,289`)
- [ ] Viewbox changes assign only `view_box`; register elements/streams only when
      membership changes; idempotent `StreamManager` registration (today every
      pan/zoom tears down and recreates all stream subscriptions — `canvas_live.ex:1156-1184`)
- [ ] Batch stream broadcasts (~250ms windows) instead of per-log-line on a
      global topic (`stream_manager.ex:167-185`)

## Phase 3 — Browser/input fixes (independent of 1-2)

- [ ] Wheel rewrite (`canvas_hook.js:419`): normalize `deltaMode`, exponential
      factor from delta magnitude, `ctrlKey`+wheel = pinch zoom, plain wheel = pan,
      Safari `gesturestart/gesturechange` (today only the sign of deltaY is used —
      mouse feels dead, trackpad zooms wildly, Safari pinch zooms the page)
- [ ] Touch: `touch-action: none` on the SVG, `pointercancel` +
      `lostpointercapture`, try/catch pointer capture
- [ ] rAF-coalesce pointermove/pan/drag/marquee; cache CTM/rect at drag start
      (today: forced layout per event — `canvas_hook.js:264-318`)
- [ ] Tooltip: parse `data-points` once in `updated()`, rAF-coalesce hover
      (today: `JSON.parse` of up to 300 points per mousemove — `canvas_hook.js:744`)
- [ ] Timeline hook: cache `Intl.DateTimeFormat`, rebuild ticks only on range
      change, fix `destroyed()` document-listener leak, `touchcancel`
- [ ] Ship the missing `CanvasDebugCopy` hook (referenced at `canvas_live.ex:354`,
      never exported); add `package.json` + document hook registration
- [ ] CSS: `100dvh` fallback, `:has()` fallback, replace hover `filter` /
      selection `drop-shadow` with stroke changes, drop dead `will-change`,
      tone down `backdrop-filter` over the live SVG

## Phase 4 — Usability

- [ ] Surface autosave failures + persistent saved/unsaved indicator
      (today silently discarded — `canvas_live.ex:2536-2543`)
- [ ] `schedule_autosave()` on undo/redo (data-loss bug: undone changes lost on reload)
- [ ] Warn + hold autosave when `Serializer.decode` fails instead of silently
      overwriting the stored blob (also: `decode(%{})` errors, so every fresh
      canvas falls through this path — fix the fresh-canvas shape too)
- [ ] Read-only: `data-can-edit` gates drag/resize in JS; server rejection pushes
      an explicit reset (today viewers' ghost drags stick visually)
- [ ] Keyboard scoping: bind shortcuts to the SVG, exempt `[tabindex]`/buttons
      (today Backspace on the focused timeline deletes the selection); free
      Ctrl+C/X/V when text is selected; Esc closes overlays/popovers/modes
- [ ] Distinct error vs empty states per element body
- [ ] Stream popover resolves entries by id, not index (wrong-row race)
- [ ] "Go Live" button + persistent timestamp readout in historical mode
- [ ] `phx-debounce` on property-panel inputs + coalesced history entries
- [ ] Polish: middle-mouse pan, share-revoke confirm, consistent return-to-select
      after placement, Shift+Arrow = large nudge
- [ ] Multi-editor minimum: presence indicator + stale-write warning (no merging)
- [ ] Fix registration leak: Manager never unregisters elements on LiveView exit
- [ ] Fix Iconify render-time raise when icon assets are missing (500s the editor)
- [ ] Add `id` to the timeline form (LiveView form recovery)

## Phase 5 — Browser E2E suite

- [ ] `phoenix_test_playwright` (test-only) + test app wired to `DataSource.Random`
- [ ] ~12 smoke flows across Chromium, Firefox, WebKit: render, placement, drag,
      resize, marquee, wheel + pinch zoom, pan, timeline scrub + Go Live,
      undo/redo, read-only enforcement, stream entry click, share flow
- [ ] Screenshot visual regression of a seeded reference canvas per engine
- [ ] CI: Chromium on PR; all three engines nightly

## Phase 6 — Release hygiene

- [ ] Tag release; bump `timeless_ui` pin (currently v0.4.10) and pin
      `timeless_stack` to a tag (currently untagged ref)

## Sequencing

0 → 1 → 2 strictly ordered. Phase 3 fully parallel to 1-2. Phase 4 items are
independent and can interleave. Phase 5 after 3 (it verifies the input fixes).

Agreed scope limits: multi-editor = presence + warning only (no CRDT);
accessibility = basics (aria-labels, focusable elements) only.
