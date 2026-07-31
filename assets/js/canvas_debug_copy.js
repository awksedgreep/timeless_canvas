/**
 * CanvasDebugCopy hook: copies the rendered canvas SVG markup to the
 * clipboard for debugging/bug reports. Attach to a button with a
 * `data-target` CSS selector pointing at the SVG (defaults to #canvas-svg).
 */
const CanvasDebugCopy = {
  mounted() {
    this._flashTimer = null;
    this._onClick = () => {
      const selector = this.el.dataset.target || "#canvas-svg";
      const svg = document.querySelector(selector);
      if (!svg) return;

      this.copyText(svg.outerHTML)
        .then(() => this.flash(true))
        .catch(() => this.flash(false));
    };
    this.el.addEventListener("click", this._onClick);
  },

  destroyed() {
    this.el.removeEventListener("click", this._onClick);
    if (this._flashTimer) {
      clearTimeout(this._flashTimer);
      this._flashTimer = null;
    }
  },

  copyText(text) {
    // navigator.clipboard requires a secure context (https/localhost)
    if (navigator.clipboard && window.isSecureContext) {
      return navigator.clipboard.writeText(text);
    }
    // Hidden-textarea fallback for insecure contexts / older browsers
    return new Promise((resolve, reject) => {
      const ta = document.createElement("textarea");
      ta.value = text;
      ta.setAttribute("readonly", "");
      ta.style.position = "fixed";
      ta.style.left = "-9999px";
      document.body.appendChild(ta);
      ta.select();
      try {
        if (document.execCommand("copy")) {
          resolve();
        } else {
          reject(new Error("execCommand copy failed"));
        }
      } catch (err) {
        reject(err);
      } finally {
        ta.remove();
      }
    });
  },

  // Brief visual feedback: swap the button text and set data-copied so
  // consumers can style success/failure states.
  flash(ok) {
    if (this._flashTimer) clearTimeout(this._flashTimer);
    if (this.el.dataset.copyLabel == null) {
      this.el.dataset.copyLabel = (this.el.textContent || "").trim();
    }
    this.el.dataset.copied = ok ? "true" : "false";
    this.el.textContent = ok ? "Copied!" : "Copy failed";
    this._flashTimer = setTimeout(() => {
      this._flashTimer = null;
      this.el.textContent = this.el.dataset.copyLabel;
      delete this.el.dataset.copied;
    }, 1200);
  },
};

export default CanvasDebugCopy;
