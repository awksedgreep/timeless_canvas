const TimelineSlider = {
  mounted() {
    this.track = this.el;
    this.windowEl = this.el.querySelector(".timeline-bar__window");
    this.thumbEl = this.el.querySelector(".timeline-bar__thumb");
    this.thumbHitEl = this.el.querySelector(".timeline-bar__thumb-hit");
    this.liveDot = this.el.querySelector(".timeline-bar__live-dot");
    this.densityEl = this.el.querySelector(".timeline-bar__density");
    this.ticksEl = this.el.querySelector(".timeline-bar__ticks");

    this.dragging = false;
    this.pendingSliderData = null;
    this.dragOffsetPx = 0;
    this.bubbleEl = document.createElement("div");
    this.bubbleEl.className = "timeline-bar__bubble";
    this.bubbleEl.hidden = true;
    Object.assign(this.bubbleEl.style, {
      position: "fixed",
      top: "0px",
      left: "0px",
      transform: "translate(-50%, -100%)",
      padding: "4px 8px",
      borderRadius: "6px",
      background: "rgba(15, 23, 42, 0.96)",
      border: "1px solid rgba(96, 165, 250, 0.45)",
      boxShadow: "0 10px 24px rgba(2, 6, 23, 0.32)",
      color: "#e2e8f0",
      fontFamily: '"SF Mono", "Fira Code", "Cascadia Code", monospace',
      fontSize: "11px",
      lineHeight: "1",
      whiteSpace: "nowrap",
      pointerEvents: "none",
      zIndex: "9999"
    });
    document.body.appendChild(this.bubbleEl);

    this.readAttrs();
    this.render();
    this.bindEvents();

    this.handleEvent("update-slider", (data) => {
      if (this.dragging) {
        this.pendingSliderData = data;
        return;
      }

      this.min = data.min;
      this.max = data.max;
      this.value = data.value;
      this.windowRatio = data.windowRatio;
      this.isLive = data.live;
      this.render();
    });

    this.handleEvent("update-density", (data) => {
      this.renderDensity(data.buckets);
    });
  },

  updated() {
    if (this.dragging) return;
    this.readAttrs();
    this.render();
  },

  destroyed() {
    if (this.bubbleEl && this.bubbleEl.parentNode) {
      this.bubbleEl.parentNode.removeChild(this.bubbleEl);
    }
  },

  readAttrs() {
    this.min = parseFloat(this.el.dataset.min);
    this.max = parseFloat(this.el.dataset.max);
    this.value = parseFloat(this.el.dataset.value);
    this.windowRatio = parseFloat(this.el.dataset.windowRatio);
    this.isLive = this.el.dataset.live === "true";
  },

  render() {
    const min = this.dragging ? this.dragMin : this.min;
    const max = this.dragging ? this.dragMax : this.max;
    const windowRatio = this.dragging ? this.dragWindowRatio : this.windowRatio;
    const range = max - min;
    if (range <= 0) return;

    const winPct = Math.min(windowRatio * 100, 100);
    const halfWin = winPct / 2;
    const minCenterPct = halfWin;
    const maxCenterPct = 100 - halfWin;
    const rawPct = ((this.value - min) / range) * 100;
    const pct = Math.max(minCenterPct, Math.min(maxCenterPct, rawPct));

    const winLeft = Math.max(0, pct - halfWin);
    const winRight = Math.min(100, pct + halfWin);
    this.windowEl.style.left = winLeft + "%";
    this.windowEl.style.width = (winRight - winLeft) + "%";

    this.thumbEl.style.left = pct + "%";
    if (this.thumbHitEl) this.thumbHitEl.style.left = pct + "%";
    this.renderBubble(pct);

    if (this.liveDot) {
      this.liveDot.classList.toggle("timeline-bar__live-dot--active", this.isLive);
    }

    this.track.classList.toggle("timeline-bar__track--dragging", this.dragging);

    this.renderTicks();
  },

  renderBubble(pct) {
    if (!this.bubbleEl) return;

    if (!this.dragging) {
      this.bubbleEl.hidden = true;
      this.bubbleEl.textContent = "";
      return;
    }

    const rect = this.track.getBoundingClientRect();
    const bubbleX = rect.left + (pct / 100) * rect.width;
    const bubbleY = rect.top - 14;

    this.bubbleEl.hidden = false;
    this.bubbleEl.style.left = `${bubbleX}px`;
    this.bubbleEl.style.top = `${bubbleY}px`;
    this.bubbleEl.textContent = this.formatBubbleTime(this.value);
  },

  renderTicks() {
    if (!this.ticksEl) return;
    const min = this.dragging ? this.dragMin : this.min;
    const max = this.dragging ? this.dragMax : this.max;
    const range = max - min;
    if (range <= 0) return;

    // ~10 ticks across the slider
    const tickCount = 10;
    const tickInterval = range / tickCount;

    // Align ticks to round time boundaries
    const alignedInterval = this.roundInterval(tickInterval);
    const firstTick = Math.ceil(min / alignedInterval) * alignedInterval;

    let html = "";
    for (let t = firstTick; t <= max; t += alignedInterval) {
      const pct = ((t - min) / range) * 100;
      if (pct < 0 || pct > 100) continue;
      const date = new Date(t);
      const h = date.getHours().toString().padStart(2, "0");
      const m = date.getMinutes().toString().padStart(2, "0");
      const s = date.getSeconds().toString().padStart(2, "0");
      // Show seconds only for sub-minute intervals
      const label = alignedInterval < 60000 ? `${h}:${m}:${s}` : `${h}:${m}`;
      html += `<div class="timeline-bar__tick" style="left:${pct}%"><span>${label}</span></div>`;
    }
    this.ticksEl.innerHTML = html;
  },

  roundInterval(ms) {
    // Snap to nice human-readable intervals
    const candidates = [
      5000, 10000, 15000, 30000,       // seconds
      60000, 120000, 300000, 600000,    // minutes
      1800000, 3600000,                 // 30m, 1h
      7200000, 14400000, 21600000       // 2h, 4h, 6h
    ];
    for (const c of candidates) {
      if (ms <= c) return c;
    }
    return 21600000;
  },

  renderDensity(buckets) {
    if (!buckets || buckets.length === 0) {
      this.densityEl.style.background = "none";
      return;
    }
    const maxVal = Math.max(...buckets, 1);
    const stops = buckets.map((v, i) => {
      const pct = (i / buckets.length) * 100;
      const nextPct = ((i + 1) / buckets.length) * 100;
      const alpha = (v / maxVal) * 0.35;
      return `rgba(74, 158, 255, ${alpha}) ${pct}%, rgba(74, 158, 255, ${alpha}) ${nextPct}%`;
    });
    this.densityEl.style.background = `linear-gradient(to right, ${stops.join(", ")})`;
  },

  bindEvents() {
    this._lastPush = 0;

    this.track.addEventListener("mousedown", (e) => this.onPointerDown(e));
    this.track.addEventListener("touchstart", (e) => this.onTouchStart(e), { passive: false });

    this._onMouseMove = (e) => this.onPointerMove(e.clientX);
    this._onMouseUp = (e) => this.onPointerUp(e.clientX);
    this._onTouchMove = (e) => {
      e.preventDefault();
      this.onPointerMove(e.touches[0].clientX);
    };
    this._onTouchEnd = (e) => {
      const touch = e.changedTouches[0];
      this.onPointerUp(touch.clientX);
    };

    this.track.addEventListener("keydown", (e) => this.onKeyDown(e));
  },

  onPointerDown(e) {
    e.preventDefault();
    this.track.focus();
    this.dragMin = this.min;
    this.dragMax = this.max;
    this.dragWindowRatio = this.windowRatio;
    this.dragOffsetPx = this.computeDragOffset(e.clientX);
    this.dragging = true;
    this.updateFromClientX(e.clientX);
    document.addEventListener("mousemove", this._onMouseMove);
    document.addEventListener("mouseup", this._onMouseUp);
  },

  onTouchStart(e) {
    e.preventDefault();
    this.track.focus();
    this.dragMin = this.min;
    this.dragMax = this.max;
    this.dragWindowRatio = this.windowRatio;
    this.dragOffsetPx = this.computeDragOffset(e.touches[0].clientX);
    this.dragging = true;
    this.updateFromClientX(e.touches[0].clientX);
    document.addEventListener("touchmove", this._onTouchMove, { passive: false });
    document.addEventListener("touchend", this._onTouchEnd);
  },

  onPointerMove(clientX) {
    if (!this.dragging) return;
    this.updateFromClientX(clientX);
  },

  onPointerUp(clientX) {
    if (!this.dragging) return;
    this.dragging = false;
    document.removeEventListener("mousemove", this._onMouseMove);
    document.removeEventListener("mouseup", this._onMouseUp);
    document.removeEventListener("touchmove", this._onTouchMove);
    document.removeEventListener("touchend", this._onTouchEnd);

    const centerMs = this.clientXToValue(clientX);
    this.applyPendingSliderData();
    this.render();
    // Snap to live if within 2% of right edge
    const range = this.max - this.min;
    if ((centerMs - this.max) / range > -0.02) {
      this.pushEvent("timeline:go_live", {});
    } else {
      this.pushEvent("timeline:change", { time: centerMs });
    }
  },

  updateFromClientX(clientX) {
    const centerMs = this.clientXToValue(clientX);
    this.value = centerMs;
    this.render();

    const now = Date.now();
    if (now - this._lastPush >= 60) {
      this._lastPush = now;
      this.pushEvent("timeline:change", { time: centerMs });
    }
  },

  clientXToValue(clientX) {
    const rect = this.track.getBoundingClientRect();
    const adjustedX = clientX - this.dragOffsetPx;
    const pct = Math.max(0, Math.min(1, (adjustedX - rect.left) / rect.width));
    const min = this.dragging ? this.dragMin : this.min;
    const max = this.dragging ? this.dragMax : this.max;
    const windowRatio = this.dragging ? this.dragWindowRatio : this.windowRatio;
    const range = max - min;
    const halfWindow = (windowRatio * range) / 2;
    const minCenter = min + halfWindow;
    const maxCenter = max - halfWindow;
    const unclamped = min + pct * range;
    return Math.max(minCenter, Math.min(maxCenter, unclamped));
  },

  computeDragOffset(clientX) {
    const rect = this.track.getBoundingClientRect();
    const range = this.max - this.min;
    if (range <= 0) return 0;

    const pct = ((this.value - this.min) / range) * 100;
    const thumbCenterX = rect.left + (pct / 100) * rect.width;
    const windowWidth = this.windowRatio * rect.width;
    const windowLeft = thumbCenterX - windowWidth / 2;
    const windowRight = thumbCenterX + windowWidth / 2;
    const thumbHitHalf = 12;

    if (
      (clientX >= thumbCenterX - thumbHitHalf && clientX <= thumbCenterX + thumbHitHalf) ||
      (clientX >= windowLeft && clientX <= windowRight)
    ) {
      return clientX - thumbCenterX;
    }

    return 0;
  },

  applyPendingSliderData() {
    if (!this.pendingSliderData) return;

    this.min = this.pendingSliderData.min;
    this.max = this.pendingSliderData.max;
    this.value = this.pendingSliderData.value;
    this.windowRatio = this.pendingSliderData.windowRatio;
    this.isLive = this.pendingSliderData.live;
    this.pendingSliderData = null;
  },

  formatBubbleTime(value) {
    return new Intl.DateTimeFormat(undefined, {
      month: "short",
      day: "numeric",
      hour: "numeric",
      minute: "2-digit",
      second: "2-digit"
    }).format(new Date(value));
  },

  onKeyDown(e) {
    const range = this.max - this.min;
    let delta = 0;

    switch (e.key) {
      case "ArrowLeft":
        delta = -(e.shiftKey ? 0.10 : 0.01) * range;
        break;
      case "ArrowRight":
        delta = (e.shiftKey ? 0.10 : 0.01) * range;
        break;
      case "PageUp":
        delta = -this.windowRatio * range;
        break;
      case "PageDown":
        delta = this.windowRatio * range;
        break;
      case "Home":
        e.preventDefault();
        this.value = this.min;
        this.render();
        this.pushEvent("timeline:change", { time: this.value });
        return;
      case "End":
      case " ":
        e.preventDefault();
        this.pushEvent("timeline:go_live", {});
        return;
      default:
        return;
    }

    e.preventDefault();
    this.value = Math.max(this.min, Math.min(this.max, this.value + delta));
    this.render();

    // Snap to live if at right edge
    if ((this.value - this.max) / range > -0.02) {
      this.pushEvent("timeline:go_live", {});
    } else {
      this.pushEvent("timeline:change", { time: this.value });
    }
  }
};

export default TimelineSlider;
