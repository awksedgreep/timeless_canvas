/**
 * Browser E2E flows. Each flow runs against state seeded by the ExUnit
 * side (test/e2e/canvas_e2e_test.exs) and throws on failure.
 *
 * Conventions:
 *  - seeded elements get sequential ids: el-1, el-2, ...
 *  - `h` is the helpers object from helpers.js (bound to the page)
 *  - waits are selector/condition based; short timeouts only where a
 *    debounce window must elapse (documented inline).
 */
const fs = require("fs");
const path = require("path");

const flows = {
  /**
   * Flow 1: session mount renders seeded elements; the poller's
   * graph:data pushes materialize a polyline inside the ignored region.
   */
  async render(page, h) {
    await h.login();
    await h.waitLoaded();

    const count = await page.locator("[data-element-id]").count();
    h.assert(count === 3, `expected 3 seeded elements, saw ${count}`);

    // graph:data push (initial backfill or a fast poll tick) renders a
    // polyline with real points into #graph-dyn-el-3.
    await page.waitForFunction(
      () => {
        const poly = document.querySelector("#graph-dyn-el-3 polyline");
        return poly && poly.getAttribute("points").length > 20;
      },
      { timeout: 10000 },
    );
  },

  /** Flow 2: place a rect via toolbar, then a host via the typeahead. */
  async place_rect_and_host(page, h) {
    await h.login();
    await h.waitLoaded();

    // Rect
    await page.click('button[phx-value-mode="place"]');
    await page.click('button[phx-value-kind="rect"]');
    await h.clickAt(await h.emptyCanvasPoint(0.4, 0.5));
    await page.waitForSelector('[data-element-id="el-1"]', { timeout: 5000 });

    // Host via typeahead (placement returns to select mode, so re-enter)
    await page.click('button[phx-value-mode="place"]');
    await page.click('input[name="ta_search"]');
    await page.waitForSelector('button[phx-value-value="alpha-host"]', {
      timeout: 5000,
    });
    await page.click('button[phx-value-value="alpha-host"]');
    // The pick closes the dropdown and shows as the input placeholder.
    await page.waitForFunction(
      () =>
        document.querySelector('input[name="ta_search"]').placeholder ===
        "alpha-host",
      { timeout: 5000 },
    );
    await h.clickAt(await h.emptyCanvasPoint(0.6, 0.5));
    await page.waitForSelector('[data-element-id="el-2"]', { timeout: 5000 });

    const label = await page
      .locator('[data-element-id="el-2"] .canvas-element__label')
      .textContent();
    h.assert(
      label.trim() === "alpha-host",
      `host element label should be alpha-host, got ${label.trim()}`,
    );
  },

  /** Flow 3: drag an element; the new position survives a reload. */
  async drag_persist(page, h) {
    await h.login();
    await h.waitLoaded();

    const before = await h.bodyAttrs("el-1");
    const from = await h.elementCenter("el-1");
    await h.drag(from, { x: from.x + 150, y: from.y + 90 });

    // Server patches authoritative coordinates (element:move).
    await page.waitForFunction(
      (bx) => {
        const body = document.querySelector(
          '[data-element-id="el-1"] .canvas-element__body',
        );
        return (
          body &&
          !document
            .querySelector('[data-element-id="el-1"]')
            .hasAttribute("transform") &&
          parseFloat(body.getAttribute("x")) > bx + 10
        );
      },
      before.x,
      { timeout: 5000 },
    );
    const moved = await h.bodyAttrs("el-1");
    h.assert(moved.x > before.x && moved.y > before.y, "element moved");

    await h.waitSaved();
    await page.reload({ waitUntil: "load" });
    await page.waitForSelector("[data-phx-main].phx-connected", { timeout: 15000 });
    await page.waitForSelector('[data-element-id="el-1"]', { timeout: 5000 });

    const after = await h.bodyAttrs("el-1");
    h.approx(after.x, moved.x, 0.5, "x persisted across reload");
    h.approx(after.y, moved.y, 0.5, "y persisted across reload");
  },

  /** Flow 4: resize via the SE handle. */
  async resize_se(page, h) {
    await h.login();
    await h.waitLoaded();

    const before = await h.bodyAttrs("el-1");
    await h.clickAt(await h.elementCenter("el-1"));
    await page.waitForSelector('[data-element-id="el-1"] [data-handle="se"]', {
      timeout: 5000,
    });

    const handle = await page
      .locator('[data-element-id="el-1"] [data-handle="se"]')
      .boundingBox();
    const start = { x: handle.x + handle.width / 2, y: handle.y + handle.height / 2 };
    await h.drag(start, { x: start.x + 80, y: start.y + 50 });

    await page.waitForFunction(
      (w0) => {
        const body = document.querySelector(
          '[data-element-id="el-1"] .canvas-element__body',
        );
        return body && parseFloat(body.getAttribute("width")) > w0 + 10;
      },
      before.width,
      { timeout: 5000 },
    );
    const after = await h.bodyAttrs("el-1");
    h.assert(after.height > before.height, "height grew");
  },

  /** Flow 5: marquee-select two elements, delete both, undo restores. */
  async marquee_delete_undo(page, h) {
    await h.login();
    await h.waitLoaded();

    // Marquee across both seeded elements (they sit in the upper-left
    // quadrant of the default viewbox).
    const b1 = await page.locator('[data-element-id="el-1"]').boundingBox();
    const b2 = await page.locator('[data-element-id="el-2"]').boundingBox();
    const from = { x: Math.min(b1.x, b2.x) - 40, y: Math.min(b1.y, b2.y) - 40 };
    const to = {
      x: Math.max(b1.x + b1.width, b2.x + b2.width) + 40,
      y: Math.max(b1.y + b1.height, b2.y + b2.height) + 40,
    };
    await h.drag(from, to);

    await page.waitForFunction(
      () => document.querySelectorAll(".canvas-element--selected").length === 2,
      { timeout: 5000 },
    );

    // Backspace deletes both (the marquee pointerdown focused the SVG).
    await page.keyboard.press("Backspace");
    await page.waitForFunction(
      () => document.querySelectorAll("[data-element-id]").length === 0,
      { timeout: 5000 },
    );

    // Ctrl+Z restores both.
    await page.keyboard.press("Control+z");
    await page.waitForFunction(
      () => document.querySelectorAll("[data-element-id]").length === 2,
      { timeout: 5000 },
    );
  },

  /**
   * Flow 6: plain wheel pans, ctrl+wheel zooms at the cursor, the zoom
   * indicator tracks it, and keyboard +/- zooms too.
   */
  async wheel_zoom_pan(page, h) {
    await h.login();
    await h.waitLoaded();

    const center = await h.emptyCanvasPoint(0.5, 0.5);
    await page.mouse.move(center.x, center.y);

    // Plain wheel = vertical pan (viewBox y grows, width unchanged).
    const vb0 = await h.viewBox();
    await page.mouse.wheel(0, 240);
    await page.waitForFunction(
      (y0) => document.getElementById("canvas-svg").viewBox.baseVal.y > y0 + 1,
      vb0.y,
      { timeout: 3000 },
    );
    const vb1 = await h.viewBox();
    h.approx(vb1.width, vb0.width, 0.01, "plain wheel must not zoom");

    // Ctrl+wheel = zoom in at cursor (width shrinks). Keep the delta
    // gentle: the exponential factor reaches the 350% zoom clamp fast,
    // and at the clamp further zoom asserts would be no-ops.
    await page.keyboard.down("Control");
    await page.mouse.wheel(0, -60);
    await page.keyboard.up("Control");
    await page.waitForFunction(
      (w0) => document.getElementById("canvas-svg").viewBox.baseVal.width < w0 - 1,
      vb1.width,
      { timeout: 3000 },
    );

    // Debounced canvas:zoom push → server-rendered indicator changes.
    await page.waitForFunction(
      () => {
        const span = document.querySelector(".canvas-zoom-indicator > span");
        return span && parseInt(span.textContent, 10) > 100;
      },
      { timeout: 3000 },
    );

    // Keyboard zoom: "-" zooms out (width grows).
    const vb2 = await h.viewBox();
    await h.focusSvg();
    for (let i = 0; i < 5; i++) await page.keyboard.press("-");
    await page.waitForFunction(
      (w0) => document.getElementById("canvas-svg").viewBox.baseVal.width > w0 + 1,
      vb2.width,
      { timeout: 3000 },
    );
    const vb3 = await h.viewBox();
    await h.focusSvg();
    for (let i = 0; i < 5; i++) await page.keyboard.press("+");
    await page.waitForFunction(
      (w0) => document.getElementById("canvas-svg").viewBox.baseVal.width < w0 - 1,
      vb3.width,
      { timeout: 3000 },
    );
  },

  /**
   * Flow 7: Space+drag and middle-mouse pan move the viewBox while the
   * shortcut-legend overlay stays pinned to the container.
   */
  async pan_legend_fixed(page, h) {
    await h.login();
    await h.waitLoaded();

    const legendBefore = await page
      .locator(".canvas-shortcut-legend")
      .boundingBox();
    const vb0 = await h.viewBox();
    const from = await h.emptyCanvasPoint(0.5, 0.5);
    const to = { x: from.x + 220, y: from.y + 130 };

    // Space+drag pan
    await page.keyboard.down(" ");
    await h.drag(from, to);
    await page.keyboard.up(" ");
    const vb1 = await h.viewBox();
    h.assert(vb1.x < vb0.x - 10, "space+drag panned the viewBox");

    // Middle-mouse pan
    await h.drag(to, from, { button: "middle" });
    const vb2 = await h.viewBox();
    h.assert(vb2.x > vb1.x + 10, "middle-mouse panned the viewBox");

    const legendAfter = await page
      .locator(".canvas-shortcut-legend")
      .boundingBox();
    h.approx(legendAfter.x, legendBefore.x, 1, "legend x fixed during pan");
    h.approx(legendAfter.y, legendBefore.y, 1, "legend y fixed during pan");
  },

  /**
   * Flow 8: scrubbing the timeline enters historical mode (Go Live
   * button + timestamp readout); Go Live returns to the live dot.
   */
  async timeline_scrub_golive(page, h) {
    await h.login();
    await h.waitLoaded();

    await page.waitForSelector(".timeline-bar__live-dot--active", {
      timeout: 5000,
    });

    const track = await page.locator("#timeline-slider").boundingBox();
    const y = track.y + track.height / 2;
    // Drag from 70% to 35% of the track (final position well clear of the
    // snap-to-live right edge).
    await h.drag(
      { x: track.x + track.width * 0.7, y },
      { x: track.x + track.width * 0.35, y },
    );

    await page.waitForSelector(".timeline-bar__go-live", { timeout: 5000 });
    const readout = await page.locator(".timeline-bar__readout").textContent();
    h.assert(/\w{3} \d+ \d{2}:\d{2}:\d{2}/.test(readout.trim()),
      `readout should be a timestamp, got "${readout.trim()}"`);
    await page.waitForFunction(
      () => !document.querySelector(".timeline-bar__live-dot--active"),
      { timeout: 5000 },
    );

    await page.click(".timeline-bar__go-live");
    await page.waitForSelector(".timeline-bar__live-dot--active", {
      timeout: 5000,
    });
    await page.waitForFunction(
      () => !document.querySelector(".timeline-bar__go-live"),
      { timeout: 5000 },
    );
  },

  /** Flow 9: undo/redo via toolbar buttons and keyboard. */
  async undo_redo(page, h) {
    await h.login();
    await h.waitLoaded();

    // Create something to undo.
    await page.click('button[phx-value-mode="place"]');
    await page.click('button[phx-value-kind="rect"]');
    await h.clickAt(await h.emptyCanvasPoint(0.4, 0.5));
    await page.waitForSelector('[data-element-id="el-1"]', { timeout: 5000 });

    // Buttons
    await page.click('button[phx-click="canvas:undo"]');
    await page.waitForFunction(
      () => document.querySelectorAll("[data-element-id]").length === 0,
      { timeout: 5000 },
    );
    await page.click('button[phx-click="canvas:redo"]');
    await page.waitForSelector('[data-element-id="el-1"]', { timeout: 5000 });

    // Keyboard
    await h.focusSvg();
    await page.keyboard.press("Control+z");
    await page.waitForFunction(
      () => document.querySelectorAll("[data-element-id]").length === 0,
      { timeout: 5000 },
    );
    await page.keyboard.press("Control+Shift+z");
    await page.waitForSelector('[data-element-id="el-1"]', { timeout: 5000 });
  },

  /**
   * Flow 10: read-only viewer — a drag attempt leaves the element where
   * it was (no lingering transform ghost), and a tampered element:move
   * push is denied server-side with the view-only toast.
   */
  async read_only(page, h) {
    await h.login();
    await h.waitLoaded();

    await page.waitForSelector(".canvas-toolbar__badge--readonly", {
      timeout: 5000,
    });

    const before = await h.bodyAttrs("el-1");
    const from = await h.elementCenter("el-1");
    await h.drag(from, { x: from.x + 140, y: from.y + 90 });
    // Give any (erroneous) server patch a moment to land.
    await page.waitForTimeout(400);

    const group = page.locator('[data-element-id="el-1"]');
    h.assert(
      !(await group.evaluate((g) => g.hasAttribute("transform"))),
      "no drag ghost transform on the element",
    );
    const after = await h.bodyAttrs("el-1");
    h.approx(after.x, before.x, 0.01, "viewer drag must not move the element");

    // Belt-and-braces: a pushed element:move (tampered/stale client) is
    // denied and answered with the view-only toast + reset.
    await h.pushLiveEvent("element:move", { id: "el-1", dx: 80, dy: 0 });
    await page.waitForSelector(".canvas-view-only-toast", { timeout: 5000 });
    const denied = await h.bodyAttrs("el-1");
    h.approx(denied.x, before.x, 0.01, "denied move leaves position unchanged");
  },

  /** Flow 11: clicking a stream row opens the popover for that entry. */
  async stream_entry_click(page, h) {
    await h.login();
    await h.waitLoaded();

    await page.waitForFunction(
      () => document.querySelectorAll(".canvas-stream-row").length >= 2,
      { timeout: 10000 },
    );

    // Newest-first: row 0 is "checkout failed for order 421".
    const row = page.locator(".canvas-stream-row").first();
    const rowText = (await row.textContent()).trim();
    await row.click();

    await page.waitForSelector(".stream-popover", { timeout: 5000 });
    const popover = await page.locator(".stream-popover").textContent();
    h.assert(
      popover.includes("checkout failed for order 421"),
      `popover should show the clicked entry, got: ${popover.slice(0, 200)} (row was: ${rowText})`,
    );
    h.assert(popover.includes("ERROR"), "popover shows the level badge");
  },

  /**
   * Flow 12: Escape cascade — share overlay, then typeahead dropdown,
   * then place mode, then selection.
   */
  async escape_cascade(page, h) {
    await h.login();
    await h.waitLoaded();

    // 1. Share overlay closes first.
    await page.click('button[phx-click="toggle_share"]');
    await page.waitForSelector(".canvas-share-overlay", { timeout: 5000 });
    await h.focusSvg();
    await page.keyboard.press("Escape");
    await page.waitForFunction(
      () => !document.querySelector(".canvas-share-overlay"),
      { timeout: 5000 },
    );

    // 2. Open the place typeahead; Esc closes the dropdown but stays in
    // place mode (focus moves to the SVG programmatically — clicking
    // anywhere would close the dropdown via click-away instead).
    await page.click('button[phx-value-mode="place"]');
    await page.click('input[name="ta_search"]');
    await page.waitForSelector(".host-combobox__dropdown", { timeout: 5000 });
    await h.focusSvg();
    await page.keyboard.press("Escape");
    await page.waitForFunction(
      () => !document.querySelector(".host-combobox__dropdown"),
      { timeout: 5000 },
    );
    let mode = await page.getAttribute("#canvas-svg", "data-mode");
    h.assert(mode === "place", `still in place mode after dropdown close, got ${mode}`);

    // 3. Next Esc exits place mode.
    await page.keyboard.press("Escape");
    await page.waitForFunction(
      () => document.getElementById("canvas-svg").dataset.mode === "select",
      { timeout: 5000 },
    );

    // 4. Select an element; Esc deselects.
    await h.clickAt(await h.elementCenter("el-1"));
    await page.waitForSelector(".canvas-element--selected", { timeout: 5000 });
    await page.keyboard.press("Escape");
    await page.waitForFunction(
      () => !document.querySelector(".canvas-element--selected"),
      { timeout: 5000 },
    );
  },

  /**
   * Flow 13 (regression): Backspace with focus on the timeline track must
   * NOT delete the canvas selection; refocusing the canvas re-enables it.
   */
  async focus_scoping_backspace(page, h) {
    await h.login();
    await h.waitLoaded();

    await h.clickAt(await h.elementCenter("el-1"));
    await page.waitForSelector(".canvas-element--selected", { timeout: 5000 });

    // Click the timeline track: it takes focus (tabindex=0).
    const track = await page.locator("#timeline-slider").boundingBox();
    await h.clickAt({ x: track.x + track.width * 0.3, y: track.y + track.height / 2 });
    await page.waitForFunction(
      () => document.activeElement && document.activeElement.id === "timeline-slider",
      { timeout: 5000 },
    );

    await page.keyboard.press("Backspace");
    await page.waitForTimeout(400); // would-be deletion round trip
    h.assert(
      (await page.locator('[data-element-id="el-1"]').count()) === 1,
      "element survives Backspace while the timeline owns focus",
    );
    h.assert(
      (await page.locator(".canvas-element--selected").count()) === 1,
      "selection intact",
    );

    // Positive control: re-focus the canvas by clicking the element, then
    // Backspace deletes it.
    await h.clickAt(await h.elementCenter("el-1"));
    await page.keyboard.press("Backspace");
    await page.waitForFunction(
      () => document.querySelectorAll("[data-element-id]").length === 0,
      { timeout: 5000 },
    );
  },

  /**
   * Visual regression: screenshot a fixed reference canvas. Chromium
   * compares against the committed golden (bootstrap-writes it when
   * absent); other engines only save theirs as artifacts.
   */
  async visual_reference(page, h) {
    await h.login();
    await h.waitLoaded();
    await page.waitForSelector('[data-element-id="el-4"]', { timeout: 5000 });
    // Let fonts/last patches settle.
    await page.waitForTimeout(500);

    const box = await page.locator("#canvas-svg").boundingBox();
    const shot = await page.screenshot({
      clip: box,
      // Mask time-dependent chrome inside the clip (timeline timestamps,
      // zoom indicator selects) plus the font-heavy shortcut legend
      // (cross-machine font rasterization varies most on dense text).
      mask: [
        page.locator(".timeline-bar"),
        page.locator(".canvas-zoom-indicator"),
        page.locator(".canvas-shortcut-legend"),
      ],
    });

    const goldenDir = path.join(__dirname, "screenshots", h.engine);
    const goldenPath = path.join(goldenDir, "reference.png");
    fs.mkdirSync(goldenDir, { recursive: true });

    if (h.engine !== "chromium") {
      // Font rendering varies too much across engines: save, don't compare.
      fs.writeFileSync(goldenPath, shot);
      console.log(`visual: saved ${h.engine} reference as artifact (not compared)`);
      return;
    }

    if (!fs.existsSync(goldenPath)) {
      fs.writeFileSync(goldenPath, shot);
      console.log("visual: BOOTSTRAP — golden written, comparison skipped");
      return;
    }

    const { PNG } = require("pngjs");
    const pixelmatch = require("pixelmatch");
    const golden = PNG.sync.read(fs.readFileSync(goldenPath));
    const current = PNG.sync.read(shot);
    h.assert(
      golden.width === current.width && golden.height === current.height,
      `screenshot size ${current.width}x${current.height} matches golden ${golden.width}x${golden.height}`,
    );

    const diff = new PNG({ width: golden.width, height: golden.height });
    const mismatched = pixelmatch(
      golden.data,
      current.data,
      diff.data,
      golden.width,
      golden.height,
      { threshold: 0.2 },
    );
    const ratio = mismatched / (golden.width * golden.height);
    const tolerance = parseFloat(process.env.E2E_VISUAL_TOLERANCE || "0.02");

    if (ratio > tolerance) {
      const artifactDir = process.env.ARTIFACT_DIR || path.join(__dirname, "artifacts");
      fs.mkdirSync(artifactDir, { recursive: true });
      fs.writeFileSync(path.join(artifactDir, "visual-current.png"), shot);
      fs.writeFileSync(
        path.join(artifactDir, "visual-diff.png"),
        PNG.sync.write(diff),
      );
      throw new Error(
        `visual regression: ${(ratio * 100).toFixed(2)}% pixels differ ` +
          `(tolerance ${(tolerance * 100).toFixed(2)}%); see artifacts/visual-*.png`,
      );
    }
    console.log(`visual: OK (${(ratio * 100).toFixed(3)}% differing pixels)`);
  },
};

module.exports = flows;
