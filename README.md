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

Dashboard canvas builder for Elixir.

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `timeless_canvas` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:timeless_canvas, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/timeless_canvas>.

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

