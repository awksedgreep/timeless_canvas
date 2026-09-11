import test from "node:test";
import assert from "node:assert/strict";

import TimelineSlider from "./timeline_hook.js";

test("readAttrs replaces invalid numbers with finite defaults", () => {
  const slider = Object.assign(Object.create(TimelineSlider), {
    el: {
      dataset: {
        min: "not-a-number",
        max: "also-bad",
        value: "NaN",
        windowRatio: "Infinity",
        live: "true",
      },
    },
  });

  slider.readAttrs();

  assert.deepEqual(
    {
      min: slider.min,
      max: slider.max,
      value: slider.value,
      windowRatio: slider.windowRatio,
      isLive: slider.isLive,
    },
    { min: 0, max: 1, value: 0, windowRatio: 0, isLive: true },
  );
});

test("clientXToValue is stable when the track has zero width", () => {
  const slider = Object.assign(Object.create(TimelineSlider), {
    dragging: false,
    value: 42,
    track: { getBoundingClientRect: () => ({ left: 10, width: 0 }) },
  });

  assert.equal(slider.clientXToValue(100), 42);
});

test("renderTicks builds safe nodes once for an unchanged range", () => {
  const previousDocument = globalThis.document;
  let created = 0;

  globalThis.document = {
    createDocumentFragment() {
      return { children: [], appendChild(child) { this.children.push(child); } };
    },
    createElement(tag) {
      created += 1;
      return {
        tag,
        className: "",
        style: {},
        textContent: "",
        children: [],
        appendChild(child) { this.children.push(child); },
      };
    },
  };

  try {
    const ticksEl = {
      replacements: 0,
      replaceChildren(fragment) {
        this.replacements += 1;
        this.children = fragment.children;
      },
    };
    const slider = Object.assign(Object.create(TimelineSlider), {
      dragging: false,
      min: 0,
      max: 60_000,
      ticksEl,
      _ticksKey: null,
    });

    slider.renderTicks();
    const createdAfterFirstRender = created;
    slider.renderTicks();

    assert.equal(ticksEl.replacements, 1);
    assert.equal(created, createdAfterFirstRender);
    assert.ok(ticksEl.children.length > 0);
    assert.ok(ticksEl.children.every((tick) => tick.children.length === 1));
  } finally {
    globalThis.document = previousDocument;
  }
});
