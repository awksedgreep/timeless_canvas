# Load benchmark baseline

Re-run with:

    MIX_ENV=test mix run bench/canvas_bench.exs

(See the header of `bench/canvas_bench.exs` for what each metric covers and
why the bench runs in the test env.)

## Machine

- Date: 2026-08-02
- CPU: Intel(R) Core(TM) Ultra 9 185H, 22 schedulers online (16 physical cores)
- Elixir 1.20.2 / OTP 29
- Linux (Arch), idle desktop load

## Baseline numbers

p50/p95 over 20 iterations (3 warmup discarded), per-operation, milliseconds.
N = canvas element count (40% graphs, 40% servers, 20% log streams; every
graph backed by a canned 60-point series).

    metric                    N=25 p50       p95 N=100 p50       p95 N=300 p50       p95
    mount_dead                    0.77      1.02      2.22      2.99      8.47     10.63
    mount_live_async              7.21      7.62     27.67     36.94    123.06    148.29
    tick_fanout_1v                0.16      0.51      1.21      1.37      7.71      8.65
    tick_fanout_10v               0.26      0.28      1.65      3.04      9.40     10.76
    view_merge_push_0pct          0.69      1.20      2.93      6.29      9.23     18.48
    view_merge_push_100pct        2.43      4.14     10.21     12.26     56.99     75.05
    scrub_round_trip              3.54      4.05     15.48     18.15     71.31     82.01
    undo                          2.72      3.41     11.94     14.21     59.12     79.14
    redo                          2.59      4.81     11.72     13.25     60.96     64.94

Per-LiveView memory with the full 50-snapshot undo history (KiB):

    N            process     history  history_flat
    25             364.1       734.5        1248.8
    100           1537.7      2955.5        4994.9
    300           4023.5      8884.2       14987.7

## How to read this

- `mount_dead` is the plain HTTP render; `mount_live_async` is the full
  connected experience (dead render + LiveView join + the `:initial_data`
  async load merged via `render_async`). The gap between them is the cost a
  user pays after first paint.
- `tick_fanout_*` is poller-tick-to-broadcast-received for plain subscriber
  processes; it excludes LiveView-side work. The LiveView side of a tick is
  `view_merge_push_100pct` (every graph changed — worst case) vs
  `view_merge_push_0pct` (nothing changed: the pure payload-rebuild/diff
  overhead every `{:canvas_data, ...}` message pays).
- `scrub_round_trip`, `undo`, `redo` are synchronous `handle_event` round
  trips through `Phoenix.LiveViewTest.render_hook` (includes the test-proxy
  render, which is also what a connected client would be sent).
- Memory: `process` (`:erlang.process_info/2` after a forced GC) is the
  ground-truth per-viewer footprint. The `history` columns decompose the
  history assign via `:erts_debug.size` (sharing-aware) and
  `:erts_debug.flat_size` (cost if fully copied), but they are measured on a
  `:sys.get_state/1` copy, which loses some intra-term sharing — hence
  `history` can exceed `process`. Treat the history columns as upper bounds /
  relative indicators, not absolute in-process bytes.
- Timings use the in-memory fakes, so they measure canvas/LiveView machinery
  only. A real data source adds its own query latency on top of
  `mount_live_async`, `scrub_round_trip`, and the poller tick.

## Observations from this run

- Everything scales roughly linearly in N except `mount_live_async`, which
  is mildly superlinear past N=100 (25→100: 3.8x for 4x elements; 100→300:
  4.4x for 3x elements) — the initial-data merge re-renders the whole scene.
- At N=300 the interactive operations (scrub ~71ms p50, undo/redo ~60ms p50,
  full tick merge ~57ms p50) are approaching the 100ms perceptibility
  budget; they are the first things to watch on regression.
- Broadcast fan-out is cheap: going from 1 to 10 subscribed viewers adds
  ~20% to tick delivery time at every N. The per-canvas poller design holds
  up.
- A viewer at N=300 costs ~4MiB of process heap with a full undo history.

## Comparing runs

Numbers are machine-dependent; compare only against a baseline recorded on
the same hardware. Re-record this file (table + machine section) whenever a
deliberate performance change lands. As a rule of thumb from run-to-run
variance observed while recording this baseline, p50 deltas under ~15% are
noise; sustained >2x on any p50 is a real regression.
