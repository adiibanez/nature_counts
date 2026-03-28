/**
 * Dual-handle range slider with histogram background.
 *
 * Data attributes on the hook element:
 *   data-field, data-min, data-max, data-step,
 *   data-cur-min, data-cur-max, data-histogram (JSON array of bin counts)
 */
const TRACK_HEIGHT = 40;
const HANDLE_W = 14;
const PAD = HANDLE_W / 2; // half-handle so edges align with track ends

const RangeSlider = {
  mounted() {
    this._parseData();
    this._buildDOM();
    this._attachEvents();
    this._render();
  },

  destroyed() {
    if (this._onMove) document.removeEventListener("pointermove", this._onMove);
    if (this._onUp) document.removeEventListener("pointerup", this._onUp);
  },

  /* ── data ── */

  _parseData() {
    const d = this.el.dataset;
    this._field = d.field;
    this._dataMin = parseFloat(d.min) || 0;
    this._dataMax = parseFloat(d.max) || 1;
    this._step = parseFloat(d.step) || 1;
    this._histogram = JSON.parse(d.histogram || "[]");

    const span = this._dataMax - this._dataMin;
    if (span <= 0) this._dataMax = this._dataMin + this._step;

    // Only set cur values if not currently dragging
    if (!this._dragging) {
      this._curMin = parseFloat(d.curMin);
      this._curMax = parseFloat(d.curMax);
      if (isNaN(this._curMin)) this._curMin = this._dataMin;
      if (isNaN(this._curMax)) this._curMax = this._dataMax;
    }
  },

  /* ── DOM (built once) ── */

  _buildDOM() {
    const el = this.el;
    el.style.cssText = `position:relative;height:${TRACK_HEIGHT}px;user-select:none;touch-action:none;`;

    // Track background
    this._track = mk("div");
    this._track.style.cssText = `position:absolute;inset:0;border-radius:6px;overflow:hidden;`;
    this._track.className = "bg-base-300";
    el.appendChild(this._track);

    // Histogram bars inside track
    this._barWrap = mk("div");
    this._barWrap.style.cssText = `position:absolute;inset:0;display:flex;align-items:flex-end;padding:2px ${PAD}px;gap:1px;`;
    this._track.appendChild(this._barWrap);
    this._buildBars();

    // Selection highlight
    this._highlight = mk("div");
    this._highlight.style.cssText = "position:absolute;top:0;bottom:0;pointer-events:none;";
    this._highlight.className = "bg-primary/20";
    this._track.appendChild(this._highlight);

    // Handles
    this._minH = this._mkHandle();
    this._maxH = this._mkHandle();
    el.appendChild(this._minH);
    el.appendChild(this._maxH);

    // Single label centered between handles
    this._label = mk("span");
    this._label.style.cssText = `position:absolute;top:50%;transform:translate(-50%,-50%);font-size:11px;pointer-events:none;z-index:3;white-space:nowrap;`;
    this._label.className = "font-mono text-primary font-semibold drop-shadow-sm";
    el.appendChild(this._label);
  },

  _mkHandle() {
    const h = mk("div");
    h.style.cssText = `position:absolute;top:0;width:${HANDLE_W}px;height:100%;cursor:ew-resize;z-index:4;display:flex;align-items:center;justify-content:center;`;
    // Grip lines
    const grip = mk("div");
    grip.style.cssText = "width:4px;height:60%;border-radius:2px;border-left:1px solid;border-right:1px solid;opacity:0.7;";
    grip.className = "border-primary";
    h.appendChild(grip);
    return h;
  },

  _buildBars() {
    this._barWrap.innerHTML = "";
    const maxCount = Math.max(...this._histogram, 1);
    this._bars = this._histogram.map((count) => {
      const bar = mk("div");
      const h = Math.max((count / maxCount) * 100, 3);
      bar.style.cssText = `flex:1;height:${h}%;border-radius:2px 2px 0 0;min-width:2px;`;
      bar.className = "bg-base-content/15";
      this._barWrap.appendChild(bar);
      return bar;
    });
  },

  /* ── render (called on every change, no DOM rebuild) ── */

  _render() {
    const tw = this.el.offsetWidth - PAD * 2;
    if (tw <= 0) return; // not yet laid out
    const span = this._dataMax - this._dataMin;

    const toX = (v) => PAD + ((v - this._dataMin) / span) * tw;

    const x1 = toX(this._curMin);
    const x2 = toX(this._curMax);

    this._minH.style.left = (x1 - HANDLE_W / 2) + "px";
    this._maxH.style.left = (x2 - HANDLE_W / 2) + "px";
    this._highlight.style.left = x1 + "px";
    this._highlight.style.width = Math.max(x2 - x1, 0) + "px";

    // Color bars
    const n = this._bars.length;
    for (let i = 0; i < n; i++) {
      const bL = this._dataMin + (i / n) * span;
      const bR = this._dataMin + ((i + 1) / n) * span;
      this._bars[i].className = (bR >= this._curMin && bL <= this._curMax)
        ? "bg-primary/40" : "bg-base-content/15";
    }

    // Label
    const isDefault = this._curMin <= this._dataMin && this._curMax >= this._dataMax;
    if (isDefault) {
      this._label.textContent = "";
    } else {
      const f = this._fmt;
      this._label.textContent = `${f(this._curMin)} – ${f(this._curMax)}`;
      this._label.style.left = ((x1 + x2) / 2) + "px";
    }
  },

  get _fmt() {
    const step = this._step;
    return (v) => step >= 1 ? Math.round(v).toString() : v.toFixed(1);
  },

  /* ── interaction ── */

  _xToVal(clientX) {
    const rect = this.el.getBoundingClientRect();
    const x = clientX - rect.left;
    const tw = this.el.offsetWidth - PAD * 2;
    const span = this._dataMax - this._dataMin;
    const raw = this._dataMin + ((x - PAD) / tw) * span;
    const stepped = Math.round(raw / this._step) * this._step;
    return Math.max(this._dataMin, Math.min(this._dataMax, parseFloat(stepped.toFixed(6))));
  },

  _attachEvents() {
    this._dragging = null;

    this._onMove = (e) => {
      if (!this._dragging) return;
      const val = this._xToVal(e.clientX);
      if (this._dragging === "min") {
        this._curMin = Math.min(val, this._curMax);
      } else {
        this._curMax = Math.max(val, this._curMin);
      }
      this._render();
    };

    this._onUp = () => {
      if (!this._dragging) return;
      this._dragging = null;
      this._pushFilter();
    };

    this.el.addEventListener("pointerdown", (e) => {
      e.preventDefault();
      const val = this._xToVal(e.clientX);
      // Pick nearest handle
      const dMin = Math.abs(val - this._curMin);
      const dMax = Math.abs(val - this._curMax);
      this._dragging = dMin <= dMax ? "min" : "max";

      // Move handle to click position immediately
      if (this._dragging === "min") {
        this._curMin = Math.min(val, this._curMax);
      } else {
        this._curMax = Math.max(val, this._curMin);
      }
      this._render();
      this.el.setPointerCapture(e.pointerId);
    });

    this.el.addEventListener("pointermove", this._onMove);
    this.el.addEventListener("pointerup", this._onUp);
    this.el.addEventListener("lostpointercapture", this._onUp);
  },

  _pushFilter() {
    const isDefault = this._curMin <= this._dataMin && this._curMax >= this._dataMax;
    this.pushEvent("set_metric_filter", {
      field: this._field,
      min: isDefault ? "" : this._fmt(this._curMin),
      max: isDefault ? "" : this._fmt(this._curMax),
    });
  },
};

function mk(tag) { return document.createElement(tag); }

export default RangeSlider;
