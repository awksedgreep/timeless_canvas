# Changelog

## Unreleased

### Fixed
- Hardened canvas decoding, client event parsing, authorization, Ecto
  persistence, stream registration, and data-source polling against malformed
  input and backend failures.
- Moved polling, initial data loads, variable refreshes, status fan-out, stream
  rendering, and autosave work off the LiveView event loop where applicable.
- Bounded icon caching and client/server collections, pruned stale registrations
  and assigns, and reduced graph-render and query hot paths.
- Added real SQLite persistence coverage and browser-hook unit tests alongside
  regression coverage for the reported crash and authorization paths.

### Added
- Alert-derived element status, visible graph threshold lines, and an optional
  central rules/history/acknowledgement console through `AlertSource` callbacks.

## v0.5.4 (2026-08-22)

### Added
- Alert thresholds are set where the metric was selected: the properties
  panel carries an Alerts section for elements that select a metric —
  existing rules with an enable toggle and a summary of what they watch,
  plus a form for condition, threshold, duration, aggregate, and delivery.
  Alert callbacks take the Element (mirroring `DataSource.metric_range/5`),
  so the backend derives the labels a graph actually queries and a rule
  cannot silently watch a different series than the graph draws. A blank
  threshold is refused rather than coerced to zero, a backend error is
  reported instead of rendering an empty list, and with no alert-capable
  backend configured the section does not render at all.

## v0.5.3 (2026-08-21)

### Fixed
- A series list that is still loading says so instead of showing an empty
  list. The backend answers from a cache and returns empty on a cold miss
  while fetching in the background, so the panel said "none" when it meant
  "not yet". Backends that can tell a pending fetch from a settled empty
  answer now report loading, and the panel refreshes when the fetch lands.

## v0.5.2 (2026-08-20)

### Fixed
- A typeahead-backed field can be cleared. Nothing in the host dropdown could
  emit an empty value — the hidden input resubmitted whatever was already set
  and every option was a real host — so a value could be set and changed but
  never removed. The dropdown now carries a "— none —" entry.

### Changed
- The series filter sits next to the series list it narrows, rather than above
  the whole Metadata section with the list near the bottom of it.

## v0.5.1 (2026-08-20)

Release hardening on top of v0.5.0.

### Fixed
- Cross-canvas cut/paste: the clipboard is per-user and now survives navigation
  between canvases, instead of being lost on the way.
- Firefox-only nightly E2E failures: the selection marquee is clamped inside the
  canvas bounds.

### Changed
- Release hardening batch (Phase 7) and a load benchmark with a recorded baseline
  (Phase 8), so performance regressions have something to compare against.
- CI no longer runs on automatic triggers.

## v0.5.0 (2026-08-02)

Major performance, usability, and testing overhaul. Highlights:

### Performance
- Data-source queries execute in the caller process (no longer serialized
  through the `DataSource.Manager` GenServer); registry published via ETS.
- Bounded discovery contract: `list_hosts/2`, `list_label_values/3`, and
  `list_series_for_host/3` take `:filter`/`:limit` opts. Old-arity backends
  keep working via a compatibility shim (bounding applied in Elixir).
- New optional batch callbacks `statuses/2` and `statuses_at/3`.
- No unbounded collections in socket assigns; typeaheads and series pickers
  are server-filtered and capped.
- Async mount: first paint without waiting on the backend.
- One shared `CanvasPoller` per open canvas; per-canvas PubSub topics;
  only changed entries broadcast.
- Graph internals draw client-side from `graph:data` pushes into
  `phx-update="ignore"` regions; data ticks produce zero template diff.
- Pan/zoom no longer re-resolve variables or re-register subscriptions;
  stream broadcasts are batched per canvas.

### Browser/input
- Wheel/pinch rewrite (deltaMode normalization, ctrl+wheel zoom at cursor,
  plain wheel pan, Safari gesture events), touch correctness
  (`touch-action`, `pointercancel`), rAF-coalesced pointer/hover paths,
  middle-mouse pan.
- Default zoom rebased: 2160x1440 viewBox = 100% (max zoom 350%).
- Ships `CanvasDebugCopy`; `assets/package.json` with exports; documented
  hook registration.

### Usability
- Save-state indicator with autosave retry; undo/redo persist and
  re-register; corrupt stored data is protected behind an explicit
  confirmed discard (`Serializer.decode` treats `%{}`/nil as a fresh canvas).
- Read-only sessions cannot ghost-drag; keyboard shortcuts are scoped
  (timeline focus, text selection); Escape cascades through overlays.
- Distinct error vs empty element states that self-heal; Go Live button and
  historical timestamp readout; presence chips; stale-write warning.
- Placement binds the literal chosen host; `$host` variable binding is an
  explicit opt-in. Host/ifname edits update pins.
- Icon failures render without an icon instead of crashing; full icon
  catalog resolvable; Timeless brand icon (embedded data URI);
  whole-word icon alias matching.

### Testing
- 237 unit/LiveView tests; 14-flow Playwright E2E suite (`mix test.e2e`,
  chromium/firefox local, webkit in nightly CI) with visual regression.

### Breaking
- `DataSource.Manager.register_elements/2` takes a canvas id; per-canvas
  status topics replace the global `status_topic/0`/`metric_topic/0`.
  (Internal to the canvas LiveView; consumers using `TimelessCanvas.Router`
  and `TimelessCanvas.Supervisor` are unaffected.)
- Optional `DataSource` discovery callbacks changed arity (see shim above).

## v0.4.x

Pre-overhaul releases; see git history.
