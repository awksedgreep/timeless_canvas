/**
 * Canvas hook: pan, zoom, element drag, click detection, resize,
 * connection clicks, connect mode temp line, keyboard shortcuts.
 *
 * Interaction pattern: optimistic + authoritative.
 * Visual changes applied instantly during drag (0ms latency),
 * final state pushed to server on pointerup. Server re-renders
 * with authoritative positions. Persistence handled server-side via Ecto.
 */
const CanvasHook = {
  mounted() {
    this.baseViewBoxWidth = 1200;
    this.minZoomPercent = 10;
    this.maxZoomPercent = 190;
    this.svg = this.el;
    this.dragging = null; // null | {type: "pan"|"element"|"handle"|"marquee", ...}
    this.startClient = null; // {x, y} in client pixels
    this.lastClient = null;
    this.clickThreshold = 2; // px
    this.tempLine = null; // SVG line for connect mode
    this.marqueeRect = null; // SVG rect for marquee selection
    this._lastClickId = null; // track element clicks for dblclick detection
    this._lastClickTime = 0;

    // JS fallback for browsers without :has() support — CSS also targets
    // body.tc-canvas-open to suppress page scrollbars.
    document.body.classList.add("tc-canvas-open");

    // rAF coalescing + cached layout state (avoid forced layout per event)
    this._moveRaf = null; // pending pointermove animation frame id
    this._lastMoveEvent = null;
    this._hoverRaf = null; // pending graph-hover animation frame id
    this._lastHoverEvent = null;
    this._hoverCtmInv = null; // cached inverse screen CTM for hover
    this._dragCtx = null; // cached rect/scale/CTM for the active drag

    this.svg.addEventListener("pointerdown", (e) => this.onPointerDown(e));
    this.svg.addEventListener("pointermove", (e) => this.onPointerMove(e));
    this.svg.addEventListener("pointerup", (e) => this.onPointerUp(e));
    // With pointer capture active, pointerleave never means "drag escaped".
    // Safari sometimes drops capture on SVG; only end the drag when capture
    // is really gone.
    this.svg.addEventListener("pointerleave", (e) => {
      if (!this.dragging) return;
      const captured =
        this.svg.hasPointerCapture && this.svg.hasPointerCapture(e.pointerId);
      if (!captured) this.onPointerUp(e);
    });
    // Interrupted gestures (system dialogs, touch cancel, element removal):
    // abort without committing a move. lostpointercapture also fires after a
    // normal pointerup, where dragging is already null → no-op.
    this.svg.addEventListener("pointercancel", () => this.abortDrag());
    this.svg.addEventListener("lostpointercapture", (e) => {
      // lostpointercapture bubbles: on touch, the pointerdown target holds
      // implicit capture and loses it when our explicit svg capture takes
      // over — that must not abort the fresh drag. Only react when the svg
      // itself loses capture.
      if (e.target === this.svg) this.abortDrag();
    });
    this.svg.addEventListener("wheel", (e) => this.onWheel(e), {
      passive: false,
    });

    // Safari trackpad pinch: Safari fires proprietary gesture events instead
    // of (or, on newer versions, alongside) ctrl+wheel. _inGesture guards
    // against double-applying zoom from both paths.
    this._inGesture = false;
    if ("GestureEvent" in window) {
      this._lastGestureScale = 1;
      this.svg.addEventListener("gesturestart", (e) => {
        e.preventDefault();
        this._inGesture = true;
        this._lastGestureScale = e.scale || 1;
      });
      this.svg.addEventListener("gesturechange", (e) => {
        e.preventDefault();
        if (!this._inGesture) return;
        const scale = e.scale || 1;
        // scale grows on pinch-out (zoom in) → viewBox width shrinks
        const factor = this._lastGestureScale / scale;
        this._lastGestureScale = scale;
        this.zoomAtClientPoint(factor, e.clientX, e.clientY);
        this.scheduleViewBoxPush();
      });
      this.svg.addEventListener("gestureend", (e) => {
        e.preventDefault();
        this._inGesture = false;
      });
    }

    // Prevent context menu on canvas
    this.svg.addEventListener("contextmenu", (e) => e.preventDefault());

    this._zoomDebounce = null;

    // Space key state for pan override
    this._spaceHeld = false;
    this._onSpaceDown = (e) => {
      if (e.code === "Space" && !e.target.matches("input, textarea, select")) {
        e.preventDefault();
        this._spaceHeld = true;
        this.svg.style.cursor = "grab";
      }
    };
    this._onSpaceUp = (e) => {
      if (e.code === "Space") {
        this._spaceHeld = false;
        this.svg.style.cursor = "";
      }
    };
    document.addEventListener("keydown", this._onSpaceDown);
    document.addEventListener("keyup", this._onSpaceUp);

    // Keyboard shortcuts
    this._onKeyDown = (e) => this.onKeyDown(e);
    document.addEventListener("keydown", this._onKeyDown);

    // Tooltip elements for expanded graphs
    this._tooltip = null;
    this._tooltipLine = null;
    this._tooltipDot = null;
    this._tooltipBg = null;
    this._tooltipText = null;
    this._tooltipText2 = null;

    this.svg.addEventListener("mousemove", (e) => this.onGraphHover(e));
    this.svg.addEventListener("mouseleave", () => {
      // Drop any pending hover frame so it can't re-show the tooltip
      // after the cursor has left the canvas.
      if (this._hoverRaf) {
        cancelAnimationFrame(this._hoverRaf);
        this._hoverRaf = null;
      }
      this._lastHoverEvent = null;
      this.hideTooltip();
    });

    // Handle set-viewbox events from the server
    this.handleEvent("set-viewbox", ({ x, y, width, height }) => {
      this.setViewBox(x, y, width, height);
    });

    // Graph internals are pushed by the server ("graph:data" for compact
    // graphs, "graph:expanded" for the expanded one) and rendered into
    // phx-update="ignore" containers; raw + scaled points are cached
    // per element id for the hover tooltip (no per-mousemove parsing).
    this.graphCache = new Map();
    this.handleEvent("graph:data", (payload) => this.applyGraphData(payload));
    this.handleEvent("graph:expanded", (payload) => this.applyGraphData(payload));
  },

  reconnected() {
    // Ignored graph containers survive the reconnect patch but their
    // contents (and our cache) may be stale; ask for a full snapshot.
    this.pushEvent("graph:resync", {});
  },

  updated() {
    // Drop cached graph data for elements no longer in the DOM.
    if (this.graphCache) {
      for (const id of Array.from(this.graphCache.keys())) {
        if (!this.svg.querySelector(`[data-element-id="${id}"]`)) {
          this.graphCache.delete(id);
        }
      }
    }
    // Layout may have shifted (panel toggles, toolbar wraps): cached
    // client→SVG matrices are no longer trustworthy.
    this._hoverCtmInv = null;
    if (this._dragCtx) this._dragCtx.stale = true;
    // Preserve JS-side viewBox across LiveView DOM patches.
    // LiveView will re-set the viewBox attribute from server state, which is
    // stale during panning/zooming. Re-apply the current JS viewBox immediately.
    if (this._jsViewBox) {
      const { minX, minY, width, height } = this._jsViewBox;
      this.setViewBox(minX, minY, width, height);
    }

    // After drop: server has patched new coordinates, remove drag transforms
    if (this._pendingDrop) {
      for (const id of this._pendingDrop.ids) {
        const group = this.svg.querySelector(`[data-element-id="${id}"]`);
        if (group) group.removeAttribute("transform");
      }
      this._pendingDrop = null;
      return;
    }
    // Mid-drag: re-apply transform after LiveView patches
    if (this.dragging && this.dragging.type === "element") {
      for (const id of this.dragging.groupIds) {
        const group = this.svg.querySelector(`[data-element-id="${id}"]`);
        if (group) {
          group.parentNode.appendChild(group);
          group.setAttribute(
            "transform",
            `translate(${this.dragging.totalDx}, ${this.dragging.totalDy})`,
          );
        }
      }
      // Update primary group reference
      const primaryGroup = this.svg.querySelector(`[data-element-id="${this.dragging.id}"]`);
      if (primaryGroup) this.dragging.group = primaryGroup;
    }
  },

  destroyed() {
    document.removeEventListener("keydown", this._onKeyDown);
    document.removeEventListener("keydown", this._onSpaceDown);
    document.removeEventListener("keyup", this._onSpaceUp);
    document.body.classList.remove("tc-canvas-open");
    if (this._moveRaf) cancelAnimationFrame(this._moveRaf);
    if (this._hoverRaf) cancelAnimationFrame(this._hoverRaf);
    this._moveRaf = null;
    this._hoverRaf = null;
    this._lastMoveEvent = null;
    this._lastHoverEvent = null;
    clearTimeout(this._zoomDebounce);
    this._zoomDebounce = null;
    if (this.graphCache) this.graphCache.clear();
  },

  // --- Helpers ---

  getViewBox() {
    const vb = this.svg.viewBox.baseVal;
    return { minX: vb.x, minY: vb.y, width: vb.width, height: vb.height };
  },

  setViewBox(minX, minY, width, height) {
    const vb = this.svg.viewBox.baseVal;
    vb.x = minX;
    vb.y = minY;
    vb.width = width;
    vb.height = height;
    // Track JS-side viewBox so we can re-apply after LiveView DOM patches
    this._jsViewBox = { minX, minY, width, height };
    // Any viewBox change invalidates cached client→SVG matrices. The pan
    // move path clears the stale flag itself (translation keeps the scale).
    this._hoverCtmInv = null;
    if (this._dragCtx) this._dragCtx.stale = true;
  },

  // Screen-px → viewBox-unit deltas. Pass the cached drag context on hot
  // paths to avoid forcing layout (getBoundingClientRect) per event.
  clientToSvgDelta(dxPx, dyPx, ctx) {
    let scaleX, scaleY;
    if (ctx) {
      scaleX = ctx.scaleX;
      scaleY = ctx.scaleY;
    } else {
      const vb = this.getViewBox();
      const rect = this.svg.getBoundingClientRect();
      scaleX = vb.width / rect.width;
      scaleY = vb.height / rect.height;
    }
    return { dx: dxPx * scaleX, dy: dyPx * scaleY };
  },

  clientToSvg(clientX, clientY, ctmInv) {
    const pt = this.svg.createSVGPoint();
    pt.x = clientX;
    pt.y = clientY;
    const inv = ctmInv || this.svg.getScreenCTM()?.inverse();
    if (!inv) return { x: clientX, y: clientY };
    const svgPt = pt.matrixTransform(inv);
    return { x: svgPt.x, y: svgPt.y };
  },

  // Layout snapshot taken at drag start and reused for every pointermove;
  // refreshed only when the viewBox or DOM changes mid-drag (stale flag).
  _computeDragCtx() {
    const vb = this.getViewBox();
    const rect = this.svg.getBoundingClientRect();
    const ctm = this.svg.getScreenCTM();
    return {
      rect,
      scaleX: vb.width / rect.width,
      scaleY: vb.height / rect.height,
      ctmInv: ctm ? ctm.inverse() : null,
      stale: false,
    };
  },

  _refreshDragCtx() {
    this._dragCtx = this._computeDragCtx();
  },

  getMode() {
    return this.svg.dataset.mode || "select";
  },

  // --- Pointer Events ---

  onPointerDown(e) {
    if (e.button !== 0 && e.button !== 1) return; // left or middle button
    try {
      this.svg.setPointerCapture(e.pointerId);
    } catch (_err) {
      // Firefox can throw NotFoundError for stale pointer ids
    }
    this.startClient = { x: e.clientX, y: e.clientY };
    this.lastClient = { x: e.clientX, y: e.clientY };
    this._dragCtx = this._computeDragCtx();

    // Middle mouse always pans (never selects/clicks)
    if (e.button === 1) {
      e.preventDefault();
      this.svg.style.cursor = "grabbing";
      this.dragging = { type: "pan", noClick: true };
      return;
    }

    // Check if clicking a resize handle
    const handle = e.target.closest("[data-handle]");
    if (handle) {
      const elGroup = handle.closest("[data-element-id]");
      const id = elGroup?.dataset.elementId;
      if (id) {
        const body = elGroup.querySelector(".canvas-element__body");
        let w0 = parseFloat(body.getAttribute("width") || body.getAttribute("rx")) * 2 || 160;
        let h0 = parseFloat(body.getAttribute("height") || body.getAttribute("ry")) * 2 || 80;
        // For database cylinders, use the rect portion
        const bodyRect = elGroup.querySelector(".canvas-element__body-rect");
        if (bodyRect) {
          w0 = parseFloat(bodyRect.getAttribute("width"));
          h0 = parseFloat(bodyRect.getAttribute("height")) + 30;
        } else if (body.tagName === "rect") {
          w0 = parseFloat(body.getAttribute("width"));
          h0 = parseFloat(body.getAttribute("height"));
        }
        this.dragging = {
          type: "handle",
          id,
          startWidth: w0,
          startHeight: h0,
          origWidth: w0,
          origHeight: h0,
        };
        return;
      }
    }

    // Check if clicking a stream entry (log/trace row). Rows carry only
    // a content-derived entry id; the server resolves it against its
    // stream_data (id-based, so live prepends can't shift the target).
    const streamRow = e.target.closest("[data-entry-id]");
    if (streamRow) {
      const entryId = parseInt(streamRow.dataset.entryId, 10);
      const streamGroup = streamRow.closest("[data-element-id]");
      if (streamGroup && !Number.isNaN(entryId)) {
        this.pushEvent("stream:entry_click", {
          element_id: streamGroup.dataset.elementId,
          entry_id: entryId,
        });
      }
      this.dragging = { type: "stream_click" };
      return;
    }

    // Check if clicking a connection
    const connGroup = e.target.closest("[data-connection-id]");
    if (connGroup) {
      const id = connGroup.dataset.connectionId;
      this.dragging = { type: "connection_click", id };
      return;
    }

    // Space or Option/Alt on an element = pan, not drag
    if (this._spaceHeld || e.altKey) {
      this.svg.style.cursor = "grabbing";
      this.dragging = { type: "pan" };
      return;
    }

    // Check if clicking an element
    const elGroup = e.target.closest("[data-element-id]");
    if (elGroup) {
      const id = elGroup.dataset.elementId;
      // Collect all selected element groups for group drag
      const selectedGroups = this.getSelectedElementGroups();
      const isSelected = selectedGroups.some((g) => g.dataset.elementId === id);
      // If element is part of a multi-selection, drag all; otherwise just this one
      const groupIds =
        isSelected && selectedGroups.length > 1
          ? selectedGroups.map((g) => g.dataset.elementId)
          : [id];
      // Move dragged elements to end of SVG so they render on top
      for (const gid of groupIds) {
        const g = this.svg.querySelector(`[data-element-id="${gid}"]`);
        if (g) g.parentNode.appendChild(g);
      }
      const svgStart = this.clientToSvg(e.clientX, e.clientY, this._dragCtx.ctmInv);
      this.dragging = {
        type: "element",
        id,
        group: elGroup,
        groupIds,
        totalDx: 0,
        totalDy: 0,
        svgStart,
        shiftKey: e.shiftKey,
      };
      return;
    }

    // Space or Option/Alt held = pan in any mode
    if (this._spaceHeld || e.altKey) {
      this.svg.style.cursor = "grabbing";
      this.dragging = { type: "pan" };
    } else if (this.getMode() === "select") {
      // In select mode, start marquee selection
      const svgStart = this.clientToSvg(e.clientX, e.clientY, this._dragCtx.ctmInv);
      this.dragging = { type: "marquee", svgStart, shiftKey: e.shiftKey };
    } else {
      this.dragging = { type: "pan" };
    }
  },

  onPointerMove(e) {
    // Coalesce to one processed move per animation frame; all viewBox and
    // transform writes happen inside the rAF callback.
    this._lastMoveEvent = e;
    if (this._moveRaf) return;
    this._moveRaf = requestAnimationFrame(() => {
      this._moveRaf = null;
      const ev = this._lastMoveEvent;
      this._lastMoveEvent = null;
      if (ev) this.processPointerMove(ev);
    });
  },

  processPointerMove(e) {
    if (!this.dragging) {
      // In connect mode, draw temp line from source to cursor
      if (this.getMode() === "connect" && this.svg.dataset.connectFrom) {
        this.updateTempLine(e.clientX, e.clientY);
      }
      return;
    }
    if (!this.lastClient) return;
    // Zoom or a DOM patch invalidated the cached layout: recompute once.
    if (this._dragCtx && this._dragCtx.stale) this._refreshDragCtx();

    const dxPx = e.clientX - this.lastClient.x;
    const dyPx = e.clientY - this.lastClient.y;

    if (this.dragging.type === "pan") {
      const delta = this.clientToSvgDelta(-dxPx, -dyPx, this._dragCtx);
      const vb = this.getViewBox();
      this.setViewBox(
        vb.minX + delta.dx,
        vb.minY + delta.dy,
        vb.width,
        vb.height,
      );
      // Panning only translates the viewBox — the cached scale stays valid,
      // so don't force a layout re-read on the next pan delta.
      if (this._dragCtx) this._dragCtx.stale = false;
    } else if (this.dragging.type === "element") {
      // Don't drag elements in connect mode
      if (this.getMode() !== "connect") {
        // Compute total delta from absolute SVG positions (no accumulation drift)
        const svgNow = this.clientToSvg(
          e.clientX,
          e.clientY,
          this._dragCtx && this._dragCtx.ctmInv,
        );
        this.dragging.totalDx = svgNow.x - this.dragging.svgStart.x;
        this.dragging.totalDy = svgNow.y - this.dragging.svgStart.y;
        // Apply transform to all elements in the drag group
        for (const gid of this.dragging.groupIds) {
          const g = this.svg.querySelector(`[data-element-id="${gid}"]`);
          if (g) {
            g.setAttribute(
              "transform",
              `translate(${this.dragging.totalDx}, ${this.dragging.totalDy})`,
            );
          }
        }
      }
    } else if (this.dragging.type === "marquee") {
      const svgNow = this.clientToSvg(
        e.clientX,
        e.clientY,
        this._dragCtx && this._dragCtx.ctmInv,
      );
      this.updateMarquee(this.dragging.svgStart, svgNow);
    } else if (this.dragging.type === "handle") {
      const delta = this.clientToSvgDelta(dxPx, dyPx, this._dragCtx);
      this.dragging.startWidth += delta.dx;
      this.dragging.startHeight += delta.dy;
      this.resizeElementVisual(
        this.dragging.id,
        Math.max(this.dragging.startWidth, 20),
        Math.max(this.dragging.startHeight, 20),
      );
    }

    this.lastClient = { x: e.clientX, y: e.clientY };
  },

  onPointerUp(e) {
    if (!this.dragging) return;

    // Flush any pending coalesced move so the commit uses final deltas.
    if (this._moveRaf) {
      cancelAnimationFrame(this._moveRaf);
      this._moveRaf = null;
      const ev = this._lastMoveEvent;
      this._lastMoveEvent = null;
      if (ev) this.processPointerMove(ev);
    }

    const totalDxPx = e.clientX - this.startClient.x;
    const totalDyPx = e.clientY - this.startClient.y;
    const dist = Math.sqrt(totalDxPx * totalDxPx + totalDyPx * totalDyPx);
    const isClick = dist < this.clickThreshold;

    if (this.dragging.type === "pan") {
      if (isClick) {
        // Click on empty canvas (middle-mouse pans never count as clicks)
        if (!this.dragging.noClick) {
          const svgPt = this.clientToSvg(e.clientX, e.clientY);
          this.pushEvent("canvas:click", { x: svgPt.x, y: svgPt.y });
          this.removeTempLine();
        }
      } else {
        // Push final pan position
        const vb = this.getViewBox();
        this.pushEvent("canvas:zoom", {
          min_x: vb.minX,
          min_y: vb.minY,
          width: vb.width,
          height: vb.height,
        });
      }
    } else if (this.dragging.type === "marquee") {
      this.removeMarquee();
      if (isClick) {
        // Click on empty canvas - clear selection
        const svgPt = this.clientToSvg(e.clientX, e.clientY);
        this.pushEvent("canvas:click", { x: svgPt.x, y: svgPt.y });
      } else {
        // Compute which elements intersect the marquee
        const svgEnd = this.clientToSvg(e.clientX, e.clientY);
        const ids = this.getElementsInRect(this.dragging.svgStart, svgEnd);
        if (ids.length > 0) {
          this.pushEvent("marquee:select", { ids });
        } else {
          this.pushEvent("canvas:deselect", {});
        }
      }
    } else if (this.dragging.type === "element") {
      if (isClick) {
        // Remove transforms from all group members
        for (const gid of this.dragging.groupIds) {
          const g = this.svg.querySelector(`[data-element-id="${gid}"]`);
          if (g) g.removeAttribute("transform");
        }

        // Detect double-click: same element within 400ms
        const now = Date.now();
        const id = this.dragging.id;
        if (this._lastClickId === id && now - this._lastClickTime < 400) {
          this.pushEvent("element:dblclick", { id });
          this._lastClickId = null;
          this._lastClickTime = 0;
        } else {
          this._lastClickId = id;
          this._lastClickTime = now;
          if (this.dragging.shiftKey) {
            this.pushEvent("element:shift_select", { id });
          } else {
            this.pushEvent("element:select", { id });
          }
        }
      } else if (this.getMode() !== "connect") {
        // Keep transform until server patches with new coordinates
        this._pendingDrop = { ids: this.dragging.groupIds };
        this.pushEvent("element:move", {
          id: this.dragging.id,
          dx: this.dragging.totalDx,
          dy: this.dragging.totalDy,
        });
      } else {
        for (const gid of this.dragging.groupIds) {
          const g = this.svg.querySelector(`[data-element-id="${gid}"]`);
          if (g) g.removeAttribute("transform");
        }
      }
    } else if (this.dragging.type === "handle") {
      this.pushEvent("element:resize", {
        id: this.dragging.id,
        width: Math.max(this.dragging.startWidth, 20),
        height: Math.max(this.dragging.startHeight, 20),
      });
    } else if (this.dragging.type === "connection_click") {
      if (isClick) {
        this.pushEvent("connection:select", { id: this.dragging.id });
      }
    }

    this._resetDragState();
    try {
      this.svg.releasePointerCapture(e.pointerId);
    } catch (_err) {
      // Firefox can throw NotFoundError for stale pointer ids
    }
  },

  // Abort an in-progress drag without committing anything (pointercancel,
  // unexpectedly lost capture). Visual transforms/marquee are undone and
  // no move/resize/click event is pushed.
  abortDrag() {
    if (this._moveRaf) {
      cancelAnimationFrame(this._moveRaf);
      this._moveRaf = null;
    }
    this._lastMoveEvent = null;
    const d = this.dragging;
    if (!d) return;

    if (d.type === "element") {
      for (const gid of d.groupIds) {
        const g = this.svg.querySelector(`[data-element-id="${gid}"]`);
        if (g) g.removeAttribute("transform");
      }
    } else if (d.type === "marquee") {
      this.removeMarquee();
    } else if (d.type === "handle") {
      // Restore original size (must run before dragging is cleared:
      // resizeElementVisual reads this.dragging for the icon transform)
      this.resizeElementVisual(d.id, d.origWidth, d.origHeight);
    }

    this._resetDragState();
  },

  _resetDragState() {
    this.dragging = null;
    this.startClient = null;
    this.lastClient = null;
    this._dragCtx = null;
    this.svg.style.cursor = this._spaceHeld ? "grab" : "";
  },

  // --- Zoom / wheel ---

  // Normalize wheel deltas to pixels. deltaMode 1 = lines, 2 = pages.
  // Per-event magnitude is clamped (~400px) to tame Firefox momentum and
  // free-spinning mouse wheels.
  normalizeWheelDelta(e) {
    let mult = 1;
    if (e.deltaMode === 1) mult = 16;
    else if (e.deltaMode === 2) mult = window.innerHeight;
    const clamp = (v) => Math.max(-400, Math.min(400, v * mult));
    return { dx: clamp(e.deltaX), dy: clamp(e.deltaY) };
  },

  onWheel(e) {
    e.preventDefault();
    // Safari 18+ can emit ctrl+wheel alongside gesture events; the gesture
    // handlers own zooming while a pinch is active.
    if (this._inGesture) return;

    const { dx, dy } = this.normalizeWheelDelta(e);

    if (e.ctrlKey) {
      // Trackpad pinch (Chrome/Firefox/Edge emulate ctrl+wheel) or real
      // ctrl+wheel: exponential zoom anchored at the cursor.
      const factor = Math.exp(dy * 0.01);
      this.zoomAtClientPoint(factor, e.clientX, e.clientY);
    } else {
      // Plain wheel pans: two-finger trackpad scroll pans both axes, a
      // mouse wheel scrolls vertically, shift+wheel scrolls horizontally
      // (some platforms already report shift+wheel as deltaX — keep it).
      let panX = dx;
      let panY = dy;
      if (e.shiftKey && dx === 0) {
        panX = dy;
        panY = 0;
      }
      const vb = this.getViewBox();
      const rect = this.svg.getBoundingClientRect();
      this.setViewBox(
        vb.minX + panX * (vb.width / rect.width),
        vb.minY + panY * (vb.height / rect.height),
        vb.width,
        vb.height,
      );
    }

    this.scheduleViewBoxPush();
  },

  // Zoom by `factor` (multiplies viewBox width) keeping the given client
  // point stationary. Shared by wheel zoom and Safari pinch gestures.
  zoomAtClientPoint(factor, clientX, clientY) {
    const svgPt = this.clientToSvg(clientX, clientY);
    const vb = this.getViewBox();

    const newWidth = this.clampZoomWidth(vb.width * factor);
    const newHeight = vb.height * (newWidth / vb.width);

    const appliedFactor = newWidth / vb.width;
    const newMinX = svgPt.x - (svgPt.x - vb.minX) * appliedFactor;
    const newMinY = svgPt.y - (svgPt.y - vb.minY) * appliedFactor;

    this.setViewBox(newMinX, newMinY, newWidth, newHeight);
  },

  // Debounced viewbox push to the server (payload shape must not change).
  scheduleViewBoxPush() {
    clearTimeout(this._zoomDebounce);
    this._zoomDebounce = setTimeout(() => {
      this._zoomDebounce = null;
      const final = this.getViewBox();
      this.pushEvent("canvas:zoom", {
        min_x: final.minX,
        min_y: final.minY,
        width: final.width,
        height: final.height,
      });
    }, 100);
  },

  // --- Keyboard Shortcuts ---

  onKeyDown(e) {
    // Don't intercept if typing in an input/textarea/select
    if (
      e.target.tagName === "INPUT" ||
      e.target.tagName === "TEXTAREA" ||
      e.target.tagName === "SELECT"
    ) {
      return;
    }

    const ctrl = e.ctrlKey || e.metaKey;

    if (e.key === "Delete" || e.key === "Backspace") {
      e.preventDefault();
      this.pushEvent("delete_selected", {});
    } else if (e.key === "Escape") {
      e.preventDefault();
      this.pushEvent("canvas:deselect", {});
      this.removeTempLine();
    } else if (e.key === "a" && ctrl) {
      e.preventDefault();
      this.pushEvent("select_all", {});
    } else if (e.key === "ArrowUp") {
      e.preventDefault();
      const amount = e.shiftKey ? -1 : -(parseInt(this.svg.dataset.gridSize) || 20);
      this.pushEvent("element:nudge", { dx: 0, dy: amount });
    } else if (e.key === "ArrowDown") {
      e.preventDefault();
      const amount = e.shiftKey ? 1 : parseInt(this.svg.dataset.gridSize) || 20;
      this.pushEvent("element:nudge", { dx: 0, dy: amount });
    } else if (e.key === "ArrowLeft") {
      e.preventDefault();
      const amount = e.shiftKey ? -1 : -(parseInt(this.svg.dataset.gridSize) || 20);
      this.pushEvent("element:nudge", { dx: amount, dy: 0 });
    } else if (e.key === "ArrowRight") {
      e.preventDefault();
      const amount = e.shiftKey ? 1 : parseInt(this.svg.dataset.gridSize) || 20;
      this.pushEvent("element:nudge", { dx: amount, dy: 0 });
    } else if ((e.key === "+" || e.key === "=") && !ctrl) {
      e.preventDefault();
      this.zoomByFactor(0.97);
    } else if (e.key === "-" && !ctrl) {
      e.preventDefault();
      this.zoomByFactor(1.03);
    } else if (e.key === "z" && ctrl && e.shiftKey) {
      e.preventDefault();
      this.pushEvent("canvas:redo", {});
    } else if (e.key === "y" && ctrl) {
      e.preventDefault();
      this.pushEvent("canvas:redo", {});
    } else if (e.key === "z" && ctrl) {
      e.preventDefault();
      this.pushEvent("canvas:undo", {});
    } else if (e.key === "c" && ctrl) {
      e.preventDefault();
      this.pushEvent("canvas:copy", {});
    } else if (e.key === "x" && ctrl) {
      e.preventDefault();
      this.pushEvent("canvas:cut", {});
    } else if (e.key === "v" && ctrl) {
      e.preventDefault();
      this.pushEvent("canvas:paste", {});
    } else if (e.key === "s" && ctrl) {
      e.preventDefault();
      this.pushEvent("canvas:save", {});
    }
  },

  zoomByFactor(factor) {
    const rect = this.svg.getBoundingClientRect();
    const centerX = rect.left + rect.width / 2;
    const centerY = rect.top + rect.height / 2;
    this.zoomAtClientPoint(factor, centerX, centerY);

    const vb = this.getViewBox();
    this.pushEvent("canvas:zoom", {
      min_x: vb.minX,
      min_y: vb.minY,
      width: vb.width,
      height: vb.height,
    });
  },

  clampZoomWidth(width) {
    const minWidth = (this.baseViewBoxWidth * 100) / this.maxZoomPercent;
    const maxWidth = (this.baseViewBoxWidth * 100) / this.minZoomPercent;
    return Math.min(Math.max(width, minWidth), maxWidth);
  },

  // --- Connect Mode Temp Line ---

  updateTempLine(clientX, clientY) {
    const sourceId = this.svg.dataset.connectFrom;
    if (!sourceId) return;

    const sourceGroup = this.svg.querySelector(
      `[data-element-id="${sourceId}"]`,
    );
    if (!sourceGroup) return;

    const body = sourceGroup.querySelector(".canvas-element__body");
    if (!body) return;

    let sx, sy;
    if (body.tagName === "ellipse") {
      sx = parseFloat(body.getAttribute("cx"));
      sy = parseFloat(body.getAttribute("cy"));
    } else {
      sx =
        parseFloat(body.getAttribute("x")) +
        parseFloat(body.getAttribute("width")) / 2;
      sy =
        parseFloat(body.getAttribute("y")) +
        parseFloat(body.getAttribute("height")) / 2;
    }

    const cursor = this.clientToSvg(clientX, clientY);

    if (!this.tempLine) {
      this.tempLine = document.createElementNS(
        "http://www.w3.org/2000/svg",
        "line",
      );
      this.tempLine.setAttribute("class", "canvas-temp-connection");
      this.tempLine.setAttribute("stroke", "#8888aa");
      this.tempLine.setAttribute("stroke-width", "2");
      this.tempLine.setAttribute("stroke-dasharray", "6 4");
      this.tempLine.setAttribute("pointer-events", "none");
      this.svg.appendChild(this.tempLine);
    }

    this.tempLine.setAttribute("x1", sx);
    this.tempLine.setAttribute("y1", sy);
    this.tempLine.setAttribute("x2", cursor.x);
    this.tempLine.setAttribute("y2", cursor.y);
  },

  removeTempLine() {
    if (this.tempLine) {
      this.tempLine.remove();
      this.tempLine = null;
    }
  },

  // --- Visual Updates (optimistic, no server) ---

  moveElementVisual(group, dx, dy) {
    // Skip elements inside transform-based icon groups (they use local coords)
    const insideTransform = (el) => el.closest(".canvas-element__icon");

    group.querySelectorAll("[x]").forEach((el) => {
      if (!insideTransform(el))
        el.setAttribute("x", parseFloat(el.getAttribute("x")) + dx);
    });
    group.querySelectorAll("[y]").forEach((el) => {
      if (!insideTransform(el))
        el.setAttribute("y", parseFloat(el.getAttribute("y")) + dy);
    });
    group.querySelectorAll("[cx]").forEach((el) => {
      if (!insideTransform(el))
        el.setAttribute("cx", parseFloat(el.getAttribute("cx")) + dx);
    });
    group.querySelectorAll("[cy]").forEach((el) => {
      if (!insideTransform(el))
        el.setAttribute("cy", parseFloat(el.getAttribute("cy")) + dy);
    });
    // Move polyline/polygon points (graph lines only, skip icon internals)
    group.querySelectorAll("polyline[points], polygon[points]").forEach((el) => {
      if (insideTransform(el)) return;
      const pts = el.getAttribute("points").trim();
      if (!pts) return;
      const shifted = pts.split(/\s+/).map((pair) => {
        const [px, py] = pair.split(",");
        return `${parseFloat(px) + dx},${parseFloat(py) + dy}`;
      }).join(" ");
      el.setAttribute("points", shifted);
    });
    // Move transform-based icons as a whole
    group.querySelectorAll("[transform]").forEach((el) => {
      const t = el.getAttribute("transform");
      const match = t.match(/translate\(([^,]+),\s*([^)]+)\)/);
      if (match) {
        const nx = parseFloat(match[1]) + dx;
        const ny = parseFloat(match[2]) + dy;
        el.setAttribute("transform", `translate(${nx}, ${ny})`);
      }
    });
  },

  // --- Marquee Selection ---

  updateMarquee(start, current) {
    const x = Math.min(start.x, current.x);
    const y = Math.min(start.y, current.y);
    const w = Math.abs(current.x - start.x);
    const h = Math.abs(current.y - start.y);

    if (!this.marqueeRect) {
      this.marqueeRect = document.createElementNS(
        "http://www.w3.org/2000/svg",
        "rect",
      );
      this.marqueeRect.setAttribute("class", "canvas-marquee");
      this.marqueeRect.setAttribute("fill", "rgba(99, 102, 241, 0.1)");
      this.marqueeRect.setAttribute("stroke", "#6366f1");
      this.marqueeRect.setAttribute("stroke-width", "1");
      this.marqueeRect.setAttribute("stroke-dasharray", "4 2");
      this.marqueeRect.setAttribute("pointer-events", "none");
      this.svg.appendChild(this.marqueeRect);
    }

    this.marqueeRect.setAttribute("x", x);
    this.marqueeRect.setAttribute("y", y);
    this.marqueeRect.setAttribute("width", w);
    this.marqueeRect.setAttribute("height", h);
  },

  removeMarquee() {
    if (this.marqueeRect) {
      this.marqueeRect.remove();
      this.marqueeRect = null;
    }
  },

  getSelectedElementGroups() {
    return Array.from(
      this.svg.querySelectorAll(".canvas-element--selected[data-element-id]"),
    );
  },

  getElementsInRect(start, end) {
    const minX = Math.min(start.x, end.x);
    const minY = Math.min(start.y, end.y);
    const maxX = Math.max(start.x, end.x);
    const maxY = Math.max(start.y, end.y);

    const ids = [];
    this.svg.querySelectorAll("[data-element-id]").forEach((group) => {
      const bounds = this.getElementBounds(group);
      if (!bounds) return;

      // Check intersection (any overlap)
      if (
        bounds.x + bounds.w > minX &&
        bounds.x < maxX &&
        bounds.y + bounds.h > minY &&
        bounds.y < maxY
      ) {
        ids.push(group.dataset.elementId);
      }
    });
    return ids;
  },

  getElementBounds(group) {
    // For database (cylinder): use body-rect which spans the full width, plus ellipse caps
    const bodyRect = group.querySelector(".canvas-element__body-rect");
    if (bodyRect) {
      const x = parseFloat(bodyRect.getAttribute("x"));
      const y = parseFloat(bodyRect.getAttribute("y")) - 15;
      const w = parseFloat(bodyRect.getAttribute("width"));
      const h = parseFloat(bodyRect.getAttribute("height")) + 30;
      return { x, y, w, h };
    }

    const body = group.querySelector(".canvas-element__body");
    if (!body) return null;

    if (body.tagName === "rect") {
      return {
        x: parseFloat(body.getAttribute("x")),
        y: parseFloat(body.getAttribute("y")),
        w: parseFloat(body.getAttribute("width")),
        h: parseFloat(body.getAttribute("height")),
      };
    }

    // Fallback for ellipse-only elements
    const cx = parseFloat(body.getAttribute("cx"));
    const cy = parseFloat(body.getAttribute("cy"));
    const rx = parseFloat(body.getAttribute("rx"));
    const ry = parseFloat(body.getAttribute("ry"));
    return { x: cx - rx, y: cy - ry, w: rx * 2, h: ry * 2 };
  },

  // --- Graph data pushes (phx-update="ignore" regions) ---

  applyGraphData(payload) {
    if (!payload || !payload.id) return;
    const containerId =
      payload.kind === "expanded"
        ? `graph-dyn-${payload.id}-expanded`
        : `graph-dyn-${payload.id}`;
    const container = document.getElementById(containerId);
    // Tolerate pushes for elements that were removed (or whose expansion
    // state flipped) between the server push and this callback.
    if (!container) return;

    this.renderGraphInternals(container, payload);

    this.graphCache.set(payload.id, {
      kind: payload.kind,
      raw: payload.raw || [],
      poly: this.parsePoints(payload.points),
    });
  },

  parsePoints(str) {
    if (!str) return [];
    return str
      .trim()
      .split(/\s+/)
      .filter((pair) => pair.includes(","))
      .map((pair) => {
        const [x, y] = pair.split(",");
        return { x: parseFloat(x), y: parseFloat(y) };
      });
  },

  svgNode(tag, attrs, text) {
    const node = document.createElementNS("http://www.w3.org/2000/svg", tag);
    for (const [key, value] of Object.entries(attrs)) {
      node.setAttribute(key, value);
    }
    if (text != null) node.textContent = text;
    return node;
  },

  // Rebuild the dynamic internals of one graph (gridlines, axis labels,
  // area, line, current value). Wholesale rebuild is fine: payloads
  // arrive at poll cadence, not per frame.
  renderGraphInternals(container, p) {
    const expanded = p.kind === "expanded";
    const fontSize = expanded ? "8" : "6";
    const dash = expanded ? "4 3" : "3 3";
    const clip = expanded
      ? `url(#graph-clip-${p.id})`
      : `url(#graph-plot-clip-${p.id})`;

    while (container.firstChild) container.removeChild(container.firstChild);

    for (const g of p.grid || []) {
      container.appendChild(
        this.svgNode("line", {
          x1: g.x1,
          y1: g.y1,
          x2: g.x2,
          y2: g.y2,
          stroke: "#1e293b",
          "stroke-width": "0.5",
          "stroke-dasharray": dash,
        }),
      );
    }
    for (const l of p.y_labels || []) {
      container.appendChild(
        this.svgNode(
          "text",
          {
            x: l.x,
            y: l.y,
            "text-anchor": "end",
            fill: "#64748b",
            "font-size": fontSize,
            "font-family": "monospace",
          },
          l.text,
        ),
      );
    }
    for (const l of p.x_labels || []) {
      container.appendChild(
        this.svgNode(
          "text",
          {
            x: l.x,
            y: l.y,
            "text-anchor": "middle",
            fill: "#64748b",
            "font-size": fontSize,
            "font-family": "monospace",
          },
          l.text,
        ),
      );
    }
    if (expanded && p.area) {
      container.appendChild(
        this.svgNode("polygon", {
          points: p.area,
          fill: p.color,
          opacity: "0.12",
          "clip-path": clip,
        }),
      );
    }
    if (p.points) {
      container.appendChild(
        this.svgNode("polyline", {
          points: p.points,
          fill: "none",
          stroke: p.color,
          "stroke-width": "1.5",
          "stroke-linejoin": "round",
          "stroke-linecap": "round",
          class: "canvas-graph__line",
          "clip-path": clip,
        }),
      );
    }
    if (expanded) {
      // Legend current-value text (the legend chrome is server-rendered)
      container.appendChild(
        this.svgNode(
          "text",
          {
            x: p.value_pos.x,
            y: p.value_pos.y,
            fill: "#e2e8f0",
            "font-size": "7",
            "font-family": "monospace",
          },
          p.value || "---",
        ),
      );
    } else if (p.value != null) {
      container.appendChild(
        this.svgNode(
          "text",
          {
            x: p.value_pos.x,
            y: p.value_pos.y,
            "text-anchor": "end",
            class: "canvas-graph__title",
            fill: p.color,
            "font-size": "8",
          },
          p.value,
        ),
      );
    }
  },

  // --- Expanded Graph Tooltip ---

  onGraphHover(e) {
    // Coalesce to one processed hover per animation frame.
    this._lastHoverEvent = e;
    if (this._hoverRaf) return;
    this._hoverRaf = requestAnimationFrame(() => {
      this._hoverRaf = null;
      const ev = this._lastHoverEvent;
      this._lastHoverEvent = null;
      if (ev) this.processGraphHover(ev);
    });
  },

  processGraphHover(e) {
    const expandedGroup = e.target.closest("[data-expanded]");
    if (!expandedGroup) {
      this.hideTooltip();
      return;
    }

    // Points are cached when the "graph:expanded" push arrives — no
    // JSON/attribute parsing on mousemove.
    const elGroup = expandedGroup.closest("[data-element-id]");
    const cached = elGroup && this.graphCache.get(elGroup.dataset.elementId);
    if (!cached || cached.kind !== "expanded") return;

    const { raw, poly } = cached;
    if (raw.length === 0 || poly.length < 2) return;

    // Screen CTM is cached across hover frames; invalidated whenever the
    // viewBox changes (setViewBox) or the DOM is patched (updated()).
    if (!this._hoverCtmInv) {
      const ctm = this.svg.getScreenCTM();
      if (!ctm) return;
      this._hoverCtmInv = ctm.inverse();
    }
    const svgPt = this.clientToSvg(e.clientX, e.clientY, this._hoverCtmInv);

    const plotMinX = poly[0].x;
    const plotMaxX = poly[poly.length - 1].x;
    const plotW = plotMaxX - plotMinX;
    if (plotW <= 0) return;

    // Check if cursor is within plot X range
    if (svgPt.x < plotMinX || svgPt.x > plotMaxX) {
      this.hideTooltip();
      return;
    }

    // Find nearest point index by X fraction
    const frac = (svgPt.x - plotMinX) / plotW;
    const idx = Math.round(frac * (poly.length - 1));
    const clampIdx = Math.max(0, Math.min(idx, poly.length - 1));
    const nearPt = poly[clampIdx];
    const rawPoint = raw[clampIdx];
    if (!nearPt || !rawPoint) return;

    this.showTooltip(
      nearPt.x,
      nearPt.y,
      { t: rawPoint[0], v: rawPoint[1] },
      expandedGroup,
    );
  },

  showTooltip(x, y, dataPoint, parentGroup) {
    const ns = "http://www.w3.org/2000/svg";

    if (!this._tooltip) {
      this._tooltipLine = document.createElementNS(ns, "line");
      this._tooltipLine.setAttribute("stroke", "#475569");
      this._tooltipLine.setAttribute("stroke-width", "0.5");
      this._tooltipLine.setAttribute("stroke-dasharray", "3 2");
      this._tooltipLine.setAttribute("pointer-events", "none");

      this._tooltipDot = document.createElementNS(ns, "circle");
      this._tooltipDot.setAttribute("r", "3");
      this._tooltipDot.setAttribute("fill", "#e2e8f0");
      this._tooltipDot.setAttribute("stroke", "#0c1222");
      this._tooltipDot.setAttribute("stroke-width", "1");
      this._tooltipDot.setAttribute("pointer-events", "none");

      this._tooltip = document.createElementNS(ns, "g");
      this._tooltip.setAttribute("pointer-events", "none");

      this._tooltipBg = document.createElementNS(ns, "rect");
      this._tooltipBg.setAttribute("rx", "3");
      this._tooltipBg.setAttribute("fill", "#1e293b");
      this._tooltipBg.setAttribute("stroke", "#334155");
      this._tooltipBg.setAttribute("stroke-width", "0.5");
      this._tooltipBg.setAttribute("opacity", "0.95");

      this._tooltipText = document.createElementNS(ns, "text");
      this._tooltipText.setAttribute("fill", "#e2e8f0");
      this._tooltipText.setAttribute("font-size", "8");
      this._tooltipText.setAttribute("font-family", "monospace");

      this._tooltipText2 = document.createElementNS(ns, "text");
      this._tooltipText2.setAttribute("fill", "#94a3b8");
      this._tooltipText2.setAttribute("font-size", "7");
      this._tooltipText2.setAttribute("font-family", "monospace");

      this._tooltip.appendChild(this._tooltipBg);
      this._tooltip.appendChild(this._tooltipText);
      this._tooltip.appendChild(this._tooltipText2);
    }

    // Get plot area bounds from the body rect
    const bodyRect = parentGroup.querySelector(".canvas-element__body");
    const bodyY = parseFloat(bodyRect.getAttribute("y"));
    const bodyH = parseFloat(bodyRect.getAttribute("height"));

    // Crosshair line spanning the plot height
    this._tooltipLine.setAttribute("x1", x);
    this._tooltipLine.setAttribute("y1", bodyY + 30);
    this._tooltipLine.setAttribute("x2", x);
    this._tooltipLine.setAttribute("y2", bodyY + bodyH - 20);

    // Dot on the data point
    this._tooltipDot.setAttribute("cx", x);
    this._tooltipDot.setAttribute("cy", y);

    // Format value
    const val = dataPoint.v;
    let valStr;
    const abs = Math.abs(val);
    if (abs >= 1e9) valStr = (val / 1e9).toFixed(1) + "G";
    else if (abs >= 1e6) valStr = (val / 1e6).toFixed(1) + "M";
    else if (abs >= 1e4) valStr = (val / 1e3).toFixed(1) + "K";
    else if (abs >= 100) valStr = Math.round(val).toString();
    else if (abs >= 1) valStr = val.toFixed(2);
    else if (abs === 0) valStr = "0";
    else valStr = val.toFixed(3);

    // Format time
    const d = new Date(dataPoint.t);
    const hh = String(d.getHours()).padStart(2, "0");
    const mm = String(d.getMinutes()).padStart(2, "0");
    const ss = String(d.getSeconds()).padStart(2, "0");
    const timeStr = `${hh}:${mm}:${ss}`;

    this._tooltipText.textContent = valStr;
    this._tooltipText2.textContent = timeStr;

    // Position tooltip box offset from the dot
    const tipX = x + 6;
    const tipY = y - 20;
    this._tooltipBg.setAttribute("x", tipX - 2);
    this._tooltipBg.setAttribute("y", tipY - 8);
    this._tooltipBg.setAttribute("width", "58");
    this._tooltipBg.setAttribute("height", "22");
    this._tooltipText.setAttribute("x", tipX);
    this._tooltipText.setAttribute("y", tipY);
    this._tooltipText2.setAttribute("x", tipX);
    this._tooltipText2.setAttribute("y", tipY + 10);

    // Append to SVG (not to the group, so tooltip doesn't get clipped)
    if (!this._tooltipLine.parentNode) {
      this.svg.appendChild(this._tooltipLine);
      this.svg.appendChild(this._tooltipDot);
      this.svg.appendChild(this._tooltip);
    }
  },

  hideTooltip() {
    if (this._tooltipLine && this._tooltipLine.parentNode) {
      this._tooltipLine.remove();
      this._tooltipDot.remove();
      this._tooltip.remove();
    }
  },

  resizeElementVisual(id, width, height) {
    const group = this.svg.querySelector(`[data-element-id="${id}"]`);
    if (!group) return;

    const body = group.querySelector(".canvas-element__body");
    if (!body) return;

    // Get element origin (top-left corner)
    let x, y;
    if (body.tagName === "ellipse") {
      // Database: origin from the body-rect or computed from ellipse
      const bodyRect = group.querySelector(".canvas-element__body-rect");
      if (bodyRect) {
        x = parseFloat(bodyRect.getAttribute("x"));
        y = parseFloat(body.getAttribute("cy")) - 15; // top ellipse cy - ry
      } else {
        x = parseFloat(body.getAttribute("cx")) - parseFloat(body.getAttribute("rx"));
        y = parseFloat(body.getAttribute("cy")) - parseFloat(body.getAttribute("ry"));
      }
    } else {
      x = parseFloat(body.getAttribute("x"));
      y = parseFloat(body.getAttribute("y"));
    }

    // --- Resize the body shape ---
    if (body.tagName === "rect") {
      body.setAttribute("width", width);
      body.setAttribute("height", height);

      // Update clip paths (graph, log_stream, trace_stream)
      group.querySelectorAll("clipPath rect").forEach((r) => {
        r.setAttribute("width", width);
        r.setAttribute("height", height);
      });
    } else if (body.tagName === "ellipse") {
      // Database cylinder
      body.setAttribute("cx", x + width / 2);
      body.setAttribute("rx", width / 2);

      const bodyRect = group.querySelector(".canvas-element__body-rect");
      if (bodyRect) {
        bodyRect.setAttribute("width", width);
        bodyRect.setAttribute("height", height - 30);
      }

      const bodyBottom = group.querySelector(".canvas-element__body-bottom");
      if (bodyBottom) {
        bodyBottom.setAttribute("cx", x + width / 2);
        bodyBottom.setAttribute("cy", y + height - 15);
        bodyBottom.setAttribute("rx", width / 2);
      }

      // Bottom outline ellipse (the brightness filter one)
      group.querySelectorAll("ellipse").forEach((el) => {
        if (el === body || el === bodyBottom || el.classList.contains("canvas-element__status")) return;
        if (el.getAttribute("fill") === "none") {
          el.setAttribute("cx", x + width / 2);
          el.setAttribute("cy", y + height - 15);
          el.setAttribute("rx", width / 2);
        }
      });

      // Hit rect
      const hitRect = group.querySelector(".canvas-element__hit");
      if (hitRect) {
        hitRect.setAttribute("width", width);
        hitRect.setAttribute("height", height);
      }
    }

    // --- Reposition shared elements ---

    // Label
    const label = group.querySelector(".canvas-element__label");
    if (label) {
      label.setAttribute("x", x + width / 2);
      label.setAttribute("y", y + height - 16);
    }

    // Resize handle
    const handle = group.querySelector(".canvas-element__handle");
    if (handle) {
      handle.setAttribute("x", x + width - 10);
      handle.setAttribute("y", y + height - 10);
    }

    // Status circle (top-right corner)
    const status = group.querySelector(".canvas-element__status");
    if (status) {
      status.setAttribute("cx", x + width - 8);
    }

    // Icon (transform-based, positioned relative to element center)
    const icon = group.querySelector(".canvas-element__icon");
    if (icon) {
      // Save original icon transform in this.dragging (survives DOM patches)
      if (!this.dragging._iconOrig) {
        const t = icon.getAttribute("transform");
        if (t) {
          const m = t.match(/translate\(\s*([^,)]+)[,\s]+([^)]+)\)(.*)/);
          if (m) {
            this.dragging._iconOrig = {
              tx: parseFloat(m[1]),
              ty: parseFloat(m[2]),
              rest: m[3] || "",
            };
          }
        }
      }
      if (this.dragging._iconOrig) {
        const orig = this.dragging._iconOrig;
        // Shift icon center by half the size delta
        const dCx = (width - this.dragging.origWidth) / 2;
        const dCy = (height - this.dragging.origHeight) / 2;
        icon.setAttribute(
          "transform",
          `translate(${orig.tx + dCx}, ${orig.ty + dCy})${orig.rest}`,
        );
      }
    }
  },
};

export default CanvasHook;
