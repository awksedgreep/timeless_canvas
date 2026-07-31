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

- [x] Bounded query contract on the `DataSource` behaviour:
      `list_hosts(state, opts)`, `list_label_values(state, label, opts)`,
      `list_series_for_host(state, host, opts)` with `:filter`/`:limit` opts,
      plus optional batch `statuses/2` + `statuses_at/3`; Manager shims
      old-arity backends (filter/limit applied in Elixir)
- [x] Implement the bounded contract in
      `timeless_stack/lib/timeless_stack/ui_data_source.ex` with ETS cache + TTL
      background refresh (was: N+1 full-store scans per call — `ui_data_source.ex:145-193`).
      Done via supervised `TimelessStack.UIDataSource.Cache` (public ETS table):
      hosts + requested label keys refreshed on a TTL tick (default 60s);
      per-host series fetched on demand in the cache process and refreshed on
      access with their own TTL (TimelessMetrics has no cross-metric
      label-filtered series query, so a global index is avoided instead of
      queried); callbacks are pure ETS reads + `apply_query_opts`, cold cache
      returns `[]`
- [x] Execute queries in the caller process (source module/state + element map
      published to a public ETS table); `DataSource.Manager` keeps only
      registration state + the poll loop (was: every query from every client
      serialized through one GenServer — `manager.ex:186-206`)
- [x] Batch host status checks into one grouped logs query per tick
      (was: up to 2 log queries per host element per tick — `ui_data_source.ex:309-336`).
      `statuses/2` + `statuses_at/3` use `TimelessLogs.field_values("host", ...)`
      — exactly 2 grouped queries per batch (one per level) regardless of
      element/host count; per-element `status/2`/`status_at/3` semantics unchanged
- [x] Cap `available_series` at the assign boundary (limit 200 + server-side
      filter via new `series:filter` event) + group by metric name; grouped
      shape renders one Add-Elements button per metric with a
      "showing first N — refine filter" hint when truncated
- [x] Remove `all_hosts` / per-variable option universes from socket assigns;
      `ta:open` / `ta:filter` now run bounded server-side queries (≤50
      suggestions in a `ta_suggestions` assign); dead `pin_hosts` /
      `pin_ifnames` / `place_pins` assigns dropped
- [x] Async mount: dead render performs zero data-source queries; connected
      mount gathers all initial data (range, seed decision, host probe, units,
      per-element backfill via `Task.async_stream`) in one `start_async` task,
      merged in `handle_async` without stomping concurrent timeline changes;
      "Loading data…" toolbar badge while pending, non-fatal failure badge on
      crash (per-element skeletons remain a Phase 4 item)

## Phase 2 — Render path and polling

- [x] Per-canvas shared poller process: batch element queries per tick, broadcast
      on per-canvas PubSub topics; LiveViews merge only changed entries
      (was: N clients × G graphs × sequential queries every 2s — `canvas_live.ex:2545,2743`).
      Done via `TimelessCanvas.CanvasPoller` (one per open canvas, Registry +
      DynamicSupervisor, `restart: :temporary`) polling graph + text_series data
      through the new shared `TimelessCanvas.DataQueries` (pure query layer
      extracted from CanvasLive) and broadcasting only per-element diffs as
      `{:canvas_data, canvas_id, %{graph_data: ..., text_data: ...}}` on
      `data_topic(canvas_id)`; the per-LiveView `:graph_refresh` timer is gone.
      Status fan-out is per-canvas too: `Manager.register_elements/2` now takes a
      `canvas_id` and `{:element_status, ...}` broadcasts go to
      `Manager.status_topic(canvas_id)` instead of one global topic. The
      Manager's text-metric poll path (`poll_text_metric` +
      `{:element_text_metric, ...}` on the global metric topic) was removed —
      the poller's text_data diffs replace it end to end.
- [x] Client-side graph updates: `push_event` point deltas into a
      `phx-update="ignore"` region; remove per-render `Jason.encode!` data
      attributes (`canvas_components.ex:539-689,203,289`).
      Graph bodies now render only a static frame plus an empty ignored
      `<g id="graph-dyn-{id}[-expanded]">`; all dynamic internals
      (polyline, area, gridlines, axis labels, current value) are pushed
      as `graph:data` / `graph:expanded` events built by
      `compact_graph_payload/3` / `expanded_graph_payload/3` and rendered
      by the Canvas hook, which also caches raw+scaled points per element
      (tooltip no longer JSON-parses on mousemove). A diffing
      `push_graph_data/1` helper is called from every writer of graph
      data/geometry/expansion state; `handle_event("graph:resync")` (sent
      from the hook's `reconnected()`) re-pushes the full snapshot.
      Stream rows carry only a content-derived `data-entry-id` (stamped
      in `DataQueries.put_entry_id/1` for both historical fills and
      StreamManager live prepends) instead of a per-render JSON attribute.
- [x] Viewbox changes assign only `view_box`; register elements/streams only when
      membership changes; idempotent `StreamManager` registration (was: every
      pan/zoom tore down and recreated all stream subscriptions — `canvas_live.ex:1156-1184`).
      Pan/zoom/center/fit go through a new `update_viewbox/2` fast path
      (assigns `canvas`/`history.present` only — no VariableResolver, no
      registration, no graph re-push; history-bypass semantics preserved).
      All other mutations keep `resolve_and_assign` but `register_elements/1`
      now diffs a registration fingerprint (`%{element_id => {type, resolved
      meta}}`) and skips Manager/StreamManager/poller re-registration when it
      is unchanged (moves, resizes, label edits, z-order, statuses).
      `StreamManager.register_log_stream/register_trace_stream` are idempotent:
      identical opts + live subscription task = no-op; only changed opts (or a
      dead task) kill+respawn the backend subscription.
- [x] Batch stream broadcasts (~250ms windows) instead of per-log-line on a
      global topic (`stream_manager.ex:167-185`). StreamManager registrations
      now carry a `canvas_id` and broadcast on per-canvas
      `stream_topic(canvas_id)`; entries accumulate per element for
      `:stream_batch_ms` (app env, default 250ms) and flush as one
      `{:stream_entries, id, [entries]}` / `{:stream_spans, id, [spans]}`
      message (newest first), with an immediate flush at 50 pending entries.
      CanvasLive subscribes per-canvas and merges entry lists (still dropped
      outside `:live` timeline mode). Test support adds a subscribe-counting
      `FakeStreamBackend` that can emit live entries/spans.

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
- [x] Stream popover resolves entries by id, not index (wrong-row race) —
      done as part of Phase 2b's stream-row rework (`stream:entry_click`
      resolves the content-derived entry id from `stream_data`)
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
