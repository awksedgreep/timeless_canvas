<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/logo-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="docs/logo-light.svg">
    <img src="docs/logo-light.svg" width="300" alt="Timeless">
  </picture>
</p>

<h3 align="center">Dashboard Canvas Builder for Elixir</h3>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/github/license/awksedgreep/timeless_canvas.svg" alt="License"></a>
</p>

---

> "I found it ironic that the first thing you do to time series data is squash the timestamp. That's how the name Timeless was born." --Mark Cotner

Dashboard canvas builder for Elixir: a LiveView SVG canvas with pan/zoom,
drag, marquee selection, per-user cut/paste that survives navigating between
canvases, live-updating graph elements, a timeline scrubber, and an alerts
section for metric-selecting elements when an alert-capable backend is
configured. Data access goes through a `TimelessCanvas.DataSource` behaviour
with a bounded discovery contract (`:filter`/`:limit`), so the host
application decides where metrics come from.

Alert creation, rule status, history, and acknowledgement are exposed through
the optional callbacks in `TimelessCanvas.AlertSource`. The alert backend owns
rule storage and the evaluation schedule; the canvas deliberately does not
start a second evaluator that could duplicate notifications. Backends that
implement the central callbacks get an Alerts console in the toolbar, including
visibility for rules whose originating element was deleted.

## Installation

The package is not on Hex; add it from GitHub. While development is fast the
Timeless repos track `main` rather than pinning dot-release tags:

```elixir
def deps do
  [
    {:timeless_canvas, github: "awksedgreep/timeless_canvas", branch: "main"}
  ]
end
```

Mount the canvas in your router:

```elixir
# lib/my_app_web/router.ex
import TimelessCanvas.Router

scope "/" do
  pipe_through [:browser, :require_authenticated_user]
  live_canvas("/canvas", on_mount: [{MyAppWeb.UserAuth, :require_authenticated}])
end
```

See `CHANGELOG.md` for what each release line carries.

## JavaScript setup

TimelessCanvas ships three LiveView hooks that must be registered on your
`LiveSocket`. In your host app's `assets/js/app.js`:

```js
import { CanvasHook, TimelineSlider, CanvasDebugCopy } from "../deps/timeless_canvas/assets/js";

const liveSocket = new LiveSocket("/live", Socket, {
  params: { _csrf_token: csrfToken },
  hooks: { Canvas: CanvasHook, TimelineSlider, CanvasDebugCopy },
});
```

The hook names must match the `phx-hook` attributes in the templates exactly:

| Registered name | Export | Used by |
| --- | --- | --- |
| `Canvas` | `CanvasHook` | the canvas SVG (pan/zoom/drag/selection/graphs) |
| `TimelineSlider` | `TimelineSlider` | the timeline scrubber |
| `CanvasDebugCopy` | `CanvasDebugCopy` | the "Copy SVG" toolbar button |

Note that `CanvasHook` is registered under the name `Canvas`.

Also import the stylesheet in your `assets/css/app.css`:

```css
@import "../../deps/timeless_canvas/assets/css/timeless_canvas.css";
```

This `assets/css` file is the only copy of the stylesheet — there is no
prebuilt copy under `priv/` and no CSS route; your bundler owns it.

`assets/package.json` declares `main`/`exports`, so bundlers that resolve
packages (esbuild with `NODE_PATH=deps`, Vite, webpack) can also use
`import { CanvasHook } from "timeless_canvas"`.
