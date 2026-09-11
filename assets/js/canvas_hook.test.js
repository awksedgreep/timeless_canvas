import test from "node:test";
import assert from "node:assert/strict";

import CanvasHook from "./canvas_hook.js";

test("parsePoints rejects malformed and non-finite coordinates", () => {
  const hook = Object.create(CanvasHook);

  assert.deepEqual(hook.parsePoints("1,2 3.5,-4 bad NaN,7 8,Infinity"), [
    { x: 1, y: 2 },
    { x: 3.5, y: -4 },
  ]);
  assert.deepEqual(hook.parsePoints(undefined), []);
});

test("clampZoomWidth enforces both zoom bounds", () => {
  const hook = Object.assign(Object.create(CanvasHook), {
    baseViewBoxWidth: 2160,
    minZoomPercent: 10,
    maxZoomPercent: 350,
  });

  assert.equal(hook.clampZoomWidth(1), 2160 / 3.5);
  assert.equal(hook.clampZoomWidth(999_999), 21_600);
  assert.equal(hook.clampZoomWidth(Number.NaN), 21_600);
});

test("wheel events are combined into one animation-frame update", () => {
  const callbacks = [];
  const previousRaf = globalThis.requestAnimationFrame;
  globalThis.requestAnimationFrame = (callback) => {
    callbacks.push(callback);
    return callbacks.length;
  };

  try {
    const processed = [];
    const hook = Object.assign(Object.create(CanvasHook), {
      _inGesture: false,
      _pendingWheel: null,
      _wheelRaf: null,
      processWheel: (event) => processed.push(event),
    });
    const event = (deltaX, deltaY) => ({
      preventDefault() {},
      deltaX,
      deltaY,
      deltaMode: 0,
      ctrlKey: false,
      shiftKey: false,
      clientX: 20,
      clientY: 30,
    });

    hook.onWheel(event(2, 3));
    hook.onWheel(event(5, 7));

    assert.equal(callbacks.length, 1);
    assert.equal(processed.length, 0);
    callbacks[0]();
    assert.deepEqual(processed[0], {
      dx: 7,
      dy: 10,
      ctrlKey: false,
      shiftKey: false,
      clientX: 20,
      clientY: 30,
    });
  } finally {
    globalThis.requestAnimationFrame = previousRaf;
  }
});

test("refreshElementGroups builds a reusable id index", () => {
  const groups = [
    { dataset: { elementId: "el-1" } },
    { dataset: { elementId: "el-2" } },
  ];
  const hook = Object.assign(Object.create(CanvasHook), {
    svg: { querySelectorAll: () => groups },
  });

  const index = hook.refreshElementGroups();
  assert.equal(index.get("el-1"), groups[0]);
  assert.equal(index.get("el-2"), groups[1]);
  assert.equal(hook._elementGroups, index);
});

test("graph rendering updates dynamic nodes without rebuilding a stable layout", () => {
  const p = {
    id: "el-1",
    kind: "expanded",
    color: "#123456",
    status: "ok",
    status_pos: { x: 1, y: 2 },
    grid: [],
    y_labels: [],
    x_labels: [],
    thresholds: [],
    value_pos: { x: 3, y: 4 },
    value: "42",
    points: "1,2 3,4",
    area: "1,2 3,4 3,5 1,5",
  };
  const line = { setAttribute: (key, value) => { line[key] = value; } };
  const area = { setAttribute: (key, value) => { area[key] = value; } };
  const value = { textContent: "old" };
  const layoutKey = JSON.stringify([
    p.kind,
    p.color,
    p.status,
    p.status_pos,
    p.grid,
    p.y_labels,
    p.x_labels,
    p.thresholds,
    p.value_pos,
    true,
  ]);
  const container = {
    dataset: { layoutKey },
    querySelector(selector) {
      return {
        ".canvas-graph__line": line,
        ".canvas-graph__area": area,
        ".canvas-graph__value": value,
      }[selector];
    },
    replaceChildren() {
      assert.fail("stable graph layout should not be rebuilt");
    },
  };

  CanvasHook.renderGraphInternals(container, p);

  assert.equal(line.points, p.points);
  assert.equal(area.points, p.area);
  assert.equal(value.textContent, "42");
});
