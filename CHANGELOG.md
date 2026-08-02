# Changelog

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
