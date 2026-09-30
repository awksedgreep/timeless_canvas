# Changelog

## Unreleased

### Added
- A `top_n` element ranks the groups of a metric: a table of rows with a bar
  per row, grouped by one or more label keys, live and through the timeline
  scrubber. Clicking a row points any canvas variable bound to one of its
  group-by labels at that row, so the graphs and streams following those
  variables follow the click.
- A graph can combine every series its labels match (`sum`, `avg`, `max`,
  `min`) instead of drawing the first. The properties panel says so when more
  than one series matches and none is combined.
- A `label_filter` on a graph or a `top_n` element says what equality on one
  value cannot: `kind!=slice|manager`, `comm=postgres|pgbouncer`. Backends
  read it, with the element's labels, from `Element.query_matchers/1`.
- A `window` on either says how far back a sample still counts as the
  present. There is no default: a backend uses its own unless the element
  sets one, since only it knows how often its series are sampled.
- These are backed by optional `DataSource` callbacks, `top_series/5` and
  `metric_range/6`. The element type and the aggregate option are only offered
  when the backend exports them, so an existing backend sees no change.
- `Element.query_labels/1` is the one place an element's meta becomes a label
  filter. Backends should call it rather than keep their own list of meta keys
  that are not labels; a key missing from such a list silently narrows the
  query to nothing.

### Changed
- The series filter in the properties panel finds a series by the value of
  any of its labels as well as by the name of its metric, and every word of
  it has to be found: `proc_cpu postgres`. One series among the hundreds of a
  metric could not be found before. `DataSource.filter_series/2` does the
  matching for a backend that has the series in memory, and the behaviour says
  what `list_series_for_host/3` is to match (#20).

- A value is written in the unit its metric is named for, where the backend
  has no metadata for it: `_bytes`, `_pct`, `_per_sec`, `_bytes_per_sec`,
  `_seconds`, `_ms`, `_celsius`, `_rpm`, `_watts`, `_mhz`. A series written
  through a Prometheus import route has no metadata, and was written as a
  bare number: 752,000,000 bytes as `752.0M`. Metadata, where there is some,
  comes first. The tooltip of an expanded graph is in the unit of its axis
  (#21).

### Fixed
- A value that changed while an event was in flight changed back, and stayed
  so until it changed again: the value of a text series, the rows of a stream,
  the colour of a status. LiveView locks what an event is sent from until it
  is acknowledged, and cannot hold an update back from a locked `<svg>`, so
  the update went to the page and the acknowledgement put the page back. The
  Canvas hook now sends its events from an element outside the SVG. It took an
  event in flight when an update arrived, which is seldom on a loopback and
  often over a network (#25).
- Every time is on one clock, the browser's. The server wrote times in UTC
  and the hooks in the browser's zone, so the timeline's ticks disagreed with
  its ends, and a graph's tooltip with the axis under it. Where the host
  application has a time zone database, a time on the other side of a change
  to or from summer time is right as well (#18).
- An alert is not offered on a graph that combines or filters series. A rule
  is a metric, labels that must be equal, and an aggregate over time: of such
  a graph it would watch each series on its own, and not the line drawn. The
  rules an element already has are still listed, so that they can be removed
  (#19).
- The popover of a log or a trace row read its timestamp as milliseconds,
  whatever it was in. It reads it as the row does.
- A text series had no field for its metric name in the properties panel.

## v0.5.5 (2026-09-11)

### Changed
- Refreshed the Elixir and browser-test dependency sets, including Phoenix
  1.8.13, LiveView 1.2.11, and Playwright 1.63.0.

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
