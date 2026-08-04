/**
 * Shared page helpers for the E2E flows. `require("./helpers")(page)`
 * returns an object bound to the current page.
 */
module.exports = (page) => {
  const h = {
    /** Log in via the session route and wait for the canvas to be live. */
    async login() {
      await page.goto(process.env.LOGIN_URL, { waitUntil: "load" });
      await page.waitForSelector("#canvas-svg", { timeout: 15000 });
      await page.waitForSelector("[data-phx-main].phx-connected", { timeout: 15000 });
    },

    /** Wait for the initial async data load to finish. */
    async waitLoaded() {
      await page.waitForSelector(".canvas-toolbar__badge--loading", {
        state: "detached",
        timeout: 15000,
      });
    },

    /** Current SVG viewBox (JS-side, i.e. what the user sees). */
    viewBox() {
      return page.evaluate(() => {
        const vb = document.getElementById("canvas-svg").viewBox.baseVal;
        return { x: vb.x, y: vb.y, width: vb.width, height: vb.height };
      });
    },

    /** Server-rendered SVG position/size of an element's body. */
    bodyAttrs(id) {
      return page.evaluate((elId) => {
        const body = document.querySelector(
          `[data-element-id="${elId}"] .canvas-element__body`,
        );
        if (!body) return null;
        const num = (n) => parseFloat(body.getAttribute(n));
        return { x: num("x"), y: num("y"), width: num("width"), height: num("height") };
      }, id);
    },

    /** Client-pixel center of an element's body rect. */
    async elementCenter(id) {
      const box = await page
        .locator(`[data-element-id="${id}"] .canvas-element__body`)
        .boundingBox();
      if (!box) throw new Error(`element ${id} has no body box`);
      return { x: box.x + box.width / 2, y: box.y + box.height / 2 };
    },

    /** Mouse drag with interpolated moves (lets rAF-coalescing run). */
    async drag(from, to, opts = {}) {
      const steps = opts.steps || 10;
      const button = opts.button || "left";
      await page.mouse.move(from.x, from.y);
      await page.mouse.down({ button });
      for (let i = 1; i <= steps; i++) {
        await page.mouse.move(
          from.x + ((to.x - from.x) * i) / steps,
          from.y + ((to.y - from.y) * i) / steps,
        );
        await page.waitForTimeout(16); // one frame per move batch
      }
      await page.waitForTimeout(40); // flush pending rAF before commit
      await page.mouse.up({ button });
    },

    /** Single click (down/up, no movement → registers as canvas click). */
    async clickAt(pt) {
      await page.mouse.move(pt.x, pt.y);
      await page.mouse.down();
      await page.mouse.up();
    },

    /**
     * Marquee-drag a rectangle around the given elements: their union
     * box plus a margin, clamped inside the SVG and below the floating
     * toolbar. Unclamped margins made the drag start on the toolbar on
     * runners whose fonts render it a few pixels taller (firefox CI).
     */
    async marqueeAround(ids, margin = 40) {
      const svg = await page.locator("#canvas-svg").boundingBox();
      const bar = await page.locator(".canvas-toolbar").boundingBox();
      const topLimit = Math.max(svg.y, bar ? bar.y + bar.height : 0) + 2;
      const boxes = [];
      for (const id of ids) {
        boxes.push(await page.locator(`[data-element-id="${id}"]`).boundingBox());
      }
      const from = {
        x: Math.max(svg.x + 2, Math.min(...boxes.map((b) => b.x)) - margin),
        y: Math.max(topLimit, Math.min(...boxes.map((b) => b.y)) - margin),
      };
      const to = {
        x: Math.min(
          svg.x + svg.width - 2,
          Math.max(...boxes.map((b) => b.x + b.width)) + margin,
        ),
        y: Math.min(
          svg.y + svg.height - 2,
          Math.max(...boxes.map((b) => b.y + b.height)) + margin,
        ),
      };
      await h.drag(from, to);
    },

    /** A point inside the SVG that is empty canvas (away from elements). */
    async emptyCanvasPoint(dx = 0.75, dy = 0.75) {
      const box = await page.locator("#canvas-svg").boundingBox();
      return { x: box.x + box.width * dx, y: box.y + box.height * dy };
    },

    /** Move keyboard focus onto the canvas SVG without clicking. */
    focusSvg() {
      return page.evaluate(() =>
        document.getElementById("canvas-svg").focus({ preventScroll: true }),
      );
    },

    /** Wait for the autosave cycle to write the latest edit. */
    async waitSaved() {
      await page.waitForSelector(".canvas-toolbar__save-state--saved", {
        timeout: 10000,
      });
    },

    /** Zoom percentage from the indicator (server-rendered). */
    async zoomPercent() {
      const text = await page
        .locator(".canvas-zoom-indicator > span")
        .first()
        .textContent();
      return parseInt(text, 10);
    },

    /** Push a LiveView event from the page, bypassing hook gating. */
    pushLiveEvent(event, value) {
      return page.evaluate(
        ([ev, val]) => {
          const el = document.querySelector("[data-phx-main]");
          window.liveSocket.execJS(
            el,
            JSON.stringify([["push", { event: ev, value: val }]]),
          );
        },
        [event, value],
      );
    },

    assert(cond, msg) {
      if (!cond) throw new Error(`assertion failed: ${msg}`);
    },

    approx(a, b, tol, msg) {
      if (Math.abs(a - b) > tol) {
        throw new Error(`assertion failed: ${msg} (${a} vs ${b}, tol ${tol})`);
      }
    },
  };
  return h;
};
