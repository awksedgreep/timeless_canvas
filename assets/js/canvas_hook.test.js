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

test("topRowClick resolves a ranked row to its element and index", () => {
  const hook = Object.create(CanvasHook);
  const group = { dataset: { elementId: "el-7" } };
  const row = (topIndex, parent = group) => ({
    dataset: { topIndex },
    closest: (selector) => (selector === "[data-element-id]" ? parent : null),
  });
  const target = (found) => ({
    closest: (selector) => (selector === "[data-top-index]" ? found : null),
  });

  assert.deepEqual(hook.topRowClick(target(row("2"))), {
    element_id: "el-7",
    index: 2,
  });
  assert.equal(hook.topRowClick(target(null)), null);
  assert.equal(hook.topRowClick(target(row("nope"))), null);
  assert.equal(hook.topRowClick(target(row("-1"))), null);
  assert.equal(hook.topRowClick(target(row("0", null))), null);
});

test("clientTimezone reports minutes east of UTC, and a zone where there is one", () => {
  const hook = Object.create(CanvasHook);
  const at = (minutesWest) => ({ getTimezoneOffset: () => minutesWest });

  assert.equal(hook.clientTimezone(at(240)).offset_minutes, -240);
  assert.equal(hook.clientTimezone(at(-330)).offset_minutes, 330);
  assert.equal(hook.clientTimezone(at(0)).offset_minutes, 0);
  assert.equal(hook.clientTimezone(at(Number.NaN)).offset_minutes, 0);

  const zone = hook.clientTimezone(at(0)).zone;
  assert.ok(zone === null || (typeof zone === "string" && zone.length > 0));
});

test("clientTimezone survives a browser with no zone to give", () => {
  const hook = Object.create(CanvasHook);
  const previous = Intl.DateTimeFormat;
  Intl.DateTimeFormat = () => {
    throw new Error("no Intl");
  };

  try {
    assert.deepEqual(hook.clientTimezone({ getTimezoneOffset: () => 60 }), {
      zone: null,
      offset_minutes: -60,
    });
  } finally {
    Intl.DateTimeFormat = previous;
  }
});

test("the clock is reported when the hook reconnects, before the graphs are asked for", () => {
  const events = [];
  const hook = Object.assign(Object.create(CanvasHook), {
    pushEvent: (name) => events.push(name),
  });

  hook.reconnected();

  assert.deepEqual(events, ["client:timezone", "graph:resync"]);
});

test("events are sent from the element outside the SVG, so the SVG is not locked", () => {
  const pushed = [];
  const fallback = [];
  const source = { id: "canvas-event-source" };
  const previous = globalThis.document;
  globalThis.document = {
    getElementById: (id) => (id === "canvas-event-source" ? source : null),
  };

  try {
    const hook = Object.assign(Object.create(CanvasHook), {
      el: { dataset: { eventSource: "canvas-event-source" }, contains: () => false },
      js: () => ({ push: (el, event, opts) => pushed.push([el, event, opts]) }),
      pushEvent: (event, payload) => fallback.push([event, payload]),
    });

    hook.send("element:move", { id: "el-1", dx: 4.5, dy: -2 });

    assert.deepEqual(pushed, [
      [source, "element:move", { value: { id: "el-1", dx: 4.5, dy: -2 } }],
    ]);
    assert.deepEqual(fallback, []);
  } finally {
    globalThis.document = previous;
  }
});

test("events fall back to the hook's own push where there is nowhere else to send from", () => {
  const previous = globalThis.document;
  const cases = [
    // No element named.
    { dataset: {}, found: null, inside: false, js: true },
    // Named, and not on the page.
    { dataset: { eventSource: "gone" }, found: null, inside: false, js: true },
    // Inside the SVG: sending from it would lock the SVG again.
    { dataset: { eventSource: "inner" }, found: { id: "inner" }, inside: true, js: true },
    // A LiveView with no js() for hooks.
    { dataset: { eventSource: "outer" }, found: { id: "outer" }, inside: false, js: false },
  ];

  try {
    for (const c of cases) {
      const pushed = [];
      const fallback = [];
      globalThis.document = { getElementById: () => c.found };
      const hook = Object.assign(Object.create(CanvasHook), {
        el: { dataset: c.dataset, contains: () => c.inside },
        pushEvent: (event, payload) => fallback.push([event, payload]),
      });
      if (c.js) hook.js = () => ({ push: (...args) => pushed.push(args) });

      hook.send("canvas:escape", {});

      assert.deepEqual(pushed, [], JSON.stringify(c));
      assert.deepEqual(fallback, [["canvas:escape", {}]], JSON.stringify(c));
    }
  } finally {
    globalThis.document = previous;
  }
});

test("nothing in the hook sends an event from the SVG itself", async () => {
  const { readFile } = await import("node:fs/promises");
  const source = await readFile(new URL("./canvas_hook.js", import.meta.url), "utf8");
  const direct = source.match(/this\.pushEvent\(/g) || [];

  // The one call left is the fallback inside send().
  assert.equal(direct.length, 1);
});

test("formatValue writes a value in its unit", () => {
  const hook = Object.create(CanvasHook);
  const cases = [
    // No unit: as the tooltip always wrote a number.
    [0, null, "0"],
    [0.1234, undefined, "0.123"],
    [2.5, null, "2.50"],
    [150.4, null, "150"],
    [15000, null, "15.0K"],
    [2500000, null, "2.5M"],
    [3e9, null, "3.0G"],
    [-2500000, null, "-2.5M"],
    [42, "furlongs", "42.00"],
    // Bytes, and what is a multiple of them.
    [512, "bytes", "512 B"],
    [1536, "bytes", "1.5 KB"],
    [752000000, "bytes", "717.2 MB"],
    [3 * 1073741824, "byte", "3.0 GB"],
    [2, "kilobytes", "2.0 KB"],
    [1536, "bytes_per_second", "1.5 KB/s"],
    // Shares.
    [12.34, "percent", "12.3%"],
    [0.5, "ratio", "50.0%"],
    // Lengths of time.
    [7200, "seconds", "2.0h"],
    [90, "seconds", "1.5m"],
    [2.5, "seconds", "2.5s"],
    [0.25, "seconds", "250.0ms"],
    [1500, "milliseconds", "1.5s"],
    [12.5, "milliseconds", "12.5ms"],
    [2500, "microseconds", "2.5ms"],
    // The rest.
    [12.5, "per_second", "12.50/s"],
    [61.26, "celsius", "61.3\u00b0C"],
    [1200, "rpm", "1200 rpm"],
    [45.5, "watts", "45.50 W"],
    [3400, "megahertz", "3400 MHz"],
  ];

  for (const [value, unit, written] of cases) {
    assert.equal(hook.formatValue(value, unit), written, `${value} ${unit}`);
  }
});

test("formatValue writes what is not a number as a gap", () => {
  const hook = Object.create(CanvasHook);

  for (const value of [null, undefined, "12", Number.NaN, Infinity, {}]) {
    assert.equal(hook.formatValue(value, "bytes"), "---");
  }
});

