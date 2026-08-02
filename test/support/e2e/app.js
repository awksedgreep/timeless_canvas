// E2E browser bundle entry: registers the library's three hooks on a
// LiveSocket exactly as documented in README "JavaScript setup".
// "phoenix" / "phoenix_live_view" resolve from deps/ via NODE_PATH
// (see the :esbuild `e2e` profile in config/config.exs).
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import { CanvasHook, TimelineSlider, CanvasDebugCopy } from "../../../assets/js/index.js";

const csrfToken = document
  .querySelector("meta[name='csrf-token']")
  ?.getAttribute("content");

const liveSocket = new LiveSocket("/live", Socket, {
  params: { _csrf_token: csrfToken },
  hooks: { Canvas: CanvasHook, TimelineSlider, CanvasDebugCopy },
});

liveSocket.connect();
window.liveSocket = liveSocket;
