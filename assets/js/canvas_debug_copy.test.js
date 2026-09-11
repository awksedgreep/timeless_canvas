import test from "node:test";
import assert from "node:assert/strict";

import CanvasDebugCopy from "./canvas_debug_copy.js";

test("flash restores the button's original nested markup", () => {
  const previousSetTimeout = globalThis.setTimeout;
  let finishFlash;
  let html = '<svg aria-hidden="true"></svg><span>Copy SVG</span>';
  const el = {
    dataset: {},
    get innerHTML() { return html; },
    set innerHTML(value) { html = value; },
    set textContent(value) { html = value; },
  };
  globalThis.setTimeout = (callback) => {
    finishFlash = callback;
    return 1;
  };

  try {
    const hook = Object.assign(Object.create(CanvasDebugCopy), {
      el,
      _flashTimer: null,
    });

    hook.flash(true);
    assert.equal(el.innerHTML, "Copied!");
    assert.equal(el.dataset.copied, "true");

    finishFlash();
    assert.equal(
      el.innerHTML,
      '<svg aria-hidden="true"></svg><span>Copy SVG</span>',
    );
    assert.equal(el.dataset.copied, undefined);
  } finally {
    globalThis.setTimeout = previousSetTimeout;
  }
});
