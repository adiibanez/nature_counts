const TimelinePlayhead = {
  mounted() {
    this._raf = null;
    this._scrubbing = false;
    this._duration = parseFloat(this.el.dataset.duration) || 0;
    this._line = null;
    this._handle = null;
    this._tip = null;

    this._onMove = this._onMove.bind(this);
    this._onUp = this._onUp.bind(this);

    if (this.el.dataset.active === "true") this._activate();
  },

  updated() {
    this._duration = parseFloat(this.el.dataset.duration) || 0;
    const active = this.el.dataset.active === "true";

    if (active) {
      this._activate();
    } else {
      this._deactivate();
    }
  },

  destroyed() {
    this._stopRaf();
    document.removeEventListener("mousemove", this._onMove);
    document.removeEventListener("mouseup", this._onUp);
  },

  _activate() {
    if (!this._line) this._buildPlayhead();
    this._line.style.display = "";
    this._handle.style.display = "";
    this._startRaf();
  },

  _deactivate() {
    if (this._line) this._line.style.display = "none";
    if (this._handle) this._handle.style.display = "none";
    this._stopRaf();
  },

  _getVideo() {
    return document.querySelector("#video-preview-hook video");
  },

  _getSvgRect() {
    const svg = this.el.querySelector("svg");
    return svg ? svg.getBoundingClientRect() : null;
  },

  _buildPlayhead() {
    this.el.style.position = "relative";

    const line = document.createElement("div");
    line.className = "tl-playhead";
    line.style.cssText =
      "position:absolute;top:0;bottom:0;width:2px;background:white;" +
      "z-index:20;pointer-events:none;box-shadow:0 0 4px rgba(0,0,0,0.6);" +
      "left:0px;transition:none;";
    this._line = line;

    const handle = document.createElement("div");
    handle.className = "tl-playhead-handle";
    handle.style.cssText =
      "position:absolute;top:0;bottom:0;width:14px;z-index:21;" +
      "cursor:grab;left:0px;margin-left:-7px;";
    handle.addEventListener("mousedown", (e) => {
      e.preventDefault();
      e.stopPropagation();
      this._scrubbing = true;
      handle.style.cursor = "grabbing";
      this._tip.style.opacity = "1";
      document.addEventListener("mousemove", this._onMove);
      document.addEventListener("mouseup", this._onUp);
    });
    this._handle = handle;

    const tip = document.createElement("div");
    tip.style.cssText =
      "position:absolute;top:-18px;left:50%;transform:translateX(-50%);" +
      "font-size:10px;font-family:monospace;color:white;white-space:nowrap;" +
      "background:rgba(0,0,0,0.75);padding:1px 4px;border-radius:2px;" +
      "pointer-events:none;opacity:0;transition:opacity 0.15s;";
    handle.appendChild(tip);
    this._tip = tip;

    handle.addEventListener("mouseenter", () => { tip.style.opacity = "1"; });
    handle.addEventListener("mouseleave", () => {
      if (!this._scrubbing) tip.style.opacity = "0";
    });

    this.el.appendChild(line);
    this.el.appendChild(handle);
  },

  // Convert a fraction (0-1) to pixel offset within the container,
  // aligned to the SVG element's actual screen position.
  _fracToPx(frac) {
    const svgRect = this._getSvgRect();
    if (!svgRect) return frac * this.el.offsetWidth;
    const elRect = this.el.getBoundingClientRect();
    return (svgRect.left - elRect.left) + frac * svgRect.width;
  },

  // Convert a clientX to a fraction (0-1) within the SVG.
  _clientXToFrac(clientX) {
    const svgRect = this._getSvgRect();
    const rect = svgRect || this.el.getBoundingClientRect();
    return Math.max(0, Math.min(1, (clientX - rect.left) / rect.width));
  },

  _onMove(e) {
    if (!this._scrubbing) return;
    const video = this._getVideo();
    if (!video || !this._duration) return;

    const frac = this._clientXToFrac(e.clientX);
    video.currentTime = frac * this._duration;
    this._setPos(frac, video.currentTime);
  },

  _onUp() {
    this._scrubbing = false;
    if (this._handle) this._handle.style.cursor = "grab";
    if (this._tip) this._tip.style.opacity = "0";
    document.removeEventListener("mousemove", this._onMove);
    document.removeEventListener("mouseup", this._onUp);

    const video = this._getVideo();
    if (video && video.paused) video.play().catch(() => {});
  },

  _setPos(frac, time) {
    const px = this._fracToPx(frac);
    if (this._line) this._line.style.left = px + "px";
    if (this._handle) this._handle.style.left = px + "px";
    if (this._tip) this._tip.textContent = window._fmtTime(time);
  },

  _startRaf() {
    if (this._raf) return;
    const tick = () => {
      this._raf = requestAnimationFrame(tick);
      if (this._scrubbing) return;

      const video = this._getVideo();
      if (!video) return;

      const dur = video.duration;
      if (isFinite(dur) && dur > 0) this._duration = dur;
      if (!this._duration) return;

      const frac = Math.max(0, Math.min(1, video.currentTime / this._duration));
      this._setPos(frac, video.currentTime);
    };
    this._raf = requestAnimationFrame(tick);
  },

  _stopRaf() {
    if (this._raf) {
      cancelAnimationFrame(this._raf);
      this._raf = null;
    }
  },
};

export default TimelinePlayhead;
