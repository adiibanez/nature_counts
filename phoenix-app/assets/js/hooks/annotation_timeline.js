const COLORS = [
  { bg: "rgba(99,102,241,0.35)", border: "rgb(99,102,241)" },
  { bg: "rgba(16,185,129,0.35)", border: "rgb(16,185,129)" },
  { bg: "rgba(245,158,11,0.35)", border: "rgb(245,158,11)" },
  { bg: "rgba(236,72,153,0.35)", border: "rgb(236,72,153)" },
  { bg: "rgba(14,165,233,0.35)", border: "rgb(14,165,233)" },
  { bg: "rgba(168,85,247,0.35)", border: "rgb(168,85,247)" },
];

const AnnotationTimeline = {
  mounted() {
    this._annotations = [];
    this._duration = 0;
    this._raf = null;
    this._lastJson = "";
    this._scrubbing = false;

    this._onScrubMove = this._onScrubMove.bind(this);
    this._onScrubEnd = this._onScrubEnd.bind(this);

    this._buildTimeline();
    this._startSync();
  },

  destroyed() {
    if (this._raf) cancelAnimationFrame(this._raf);
    document.removeEventListener("mousemove", this._onScrubMove);
    document.removeEventListener("mouseup", this._onScrubEnd);
  },

  _getVideo() {
    return document.querySelector("#video-preview-hook video");
  },

  _readAnnotations() {
    const script = document.getElementById("annotation-data");
    if (!script) return;
    const json = script.dataset.json || "[]";
    if (json === this._lastJson) return;
    this._lastJson = json;
    this._annotations = JSON.parse(json);
    this.el.style.display = this._annotations.length || this._duration ? "" : "none";
    this._renderMarkers();
  },

  _buildTimeline() {
    const container = this.el;
    container.innerHTML = "";

    const wrapper = document.createElement("div");
    wrapper.className = "relative select-none";

    const bar = document.createElement("div");
    bar.className =
      "relative bg-base-300 rounded cursor-pointer overflow-hidden";
    bar.style.height = "32px";

    // Click to seek
    bar.addEventListener("mousedown", (e) => {
      if (e.target.closest("[data-ann]")) return;
      if (e.target === this._playhead || e.target.closest(".playhead-grip")) {
        // Start scrubbing from playhead
        this._startScrub(e);
        return;
      }
      // Click-to-seek
      const video = this._getVideo();
      if (!video || !this._duration) return;
      const rect = bar.getBoundingClientRect();
      const pct = Math.max(0, Math.min(1, (e.clientX - rect.left) / rect.width));
      video.currentTime = pct * this._duration;
      video.play().catch(() => {});
      // Also start scrubbing from here
      this._startScrub(e);
    });
    this._bar = bar;

    // Playhead
    const playhead = document.createElement("div");
    playhead.className = "playhead-grip";
    playhead.style.cssText =
      "position:absolute;top:-2px;height:calc(100% + 4px);width:12px;" +
      "z-index:30;cursor:grab;transform:translateX(-50%);" +
      "display:flex;align-items:center;justify-content:center;";
    playhead.style.left = "0%";

    // Visible line
    const line = document.createElement("div");
    line.style.cssText =
      "width:2px;height:100%;background:white;border-radius:1px;" +
      "box-shadow:0 0 4px rgba(0,0,0,0.5);pointer-events:none;";
    playhead.appendChild(line);

    this._playhead = playhead;
    bar.appendChild(playhead);

    const markers = document.createElement("div");
    markers.style.cssText = "position:absolute;inset:0;z-index:10";
    this._markersEl = markers;
    bar.appendChild(markers);

    const labelsRow = document.createElement("div");
    labelsRow.className = "relative";
    labelsRow.style.cssText = "min-height:0";
    this._labelsRow = labelsRow;

    const timeRow = document.createElement("div");
    timeRow.className = "flex justify-between font-mono mt-0.5";
    timeRow.style.cssText = "font-size:10px;opacity:0.4";
    const t0 = document.createElement("span");
    t0.textContent = "0:00";
    const tCur = document.createElement("span");
    tCur.style.fontWeight = "bold";
    tCur.style.opacity = "1";
    tCur.textContent = "0:00";
    this._labelCurrent = tCur;
    const tEnd = document.createElement("span");
    tEnd.textContent = "0:00";
    this._labelEnd = tEnd;
    timeRow.append(t0, tCur, tEnd);

    wrapper.append(bar, labelsRow, timeRow);
    container.appendChild(wrapper);
  },

  // --- Scrubbing (drag playhead to seek) ---

  _startScrub(e) {
    e.preventDefault();
    this._scrubbing = true;
    this._playhead.style.cursor = "grabbing";
    this._seekToX(e.clientX);
    document.addEventListener("mousemove", this._onScrubMove);
    document.addEventListener("mouseup", this._onScrubEnd);
  },

  _onScrubMove(e) {
    if (!this._scrubbing) return;
    this._seekToX(e.clientX);
  },

  _onScrubEnd() {
    this._scrubbing = false;
    this._playhead.style.cursor = "grab";
    document.removeEventListener("mousemove", this._onScrubMove);
    document.removeEventListener("mouseup", this._onScrubEnd);

    const video = this._getVideo();
    if (video && video.paused) video.play().catch(() => {});
  },

  _seekToX(clientX) {
    const video = this._getVideo();
    if (!video || !this._duration) return;
    const rect = this._bar.getBoundingClientRect();
    const pct = Math.max(0, Math.min(1, (clientX - rect.left) / rect.width));
    video.currentTime = pct * this._duration;

    // Immediately update playhead position for responsiveness
    this._playhead.style.left = (pct * 100) + "%";
    if (this._labelCurrent)
      this._labelCurrent.textContent = window._fmtTime(video.currentTime);
  },

  // --- Marker rendering ---

  _renderMarkers() {
    const markersEl = this._markersEl;
    const labelsRow = this._labelsRow;
    if (!markersEl || !labelsRow) return;
    markersEl.innerHTML = "";
    labelsRow.innerHTML = "";

    if (!this._annotations.length) {
      labelsRow.style.minHeight = "0";
      return;
    }

    let dur = this._duration;
    if (!dur || dur <= 0) {
      const maxTime = this._annotations.reduce(
        (m, a) => Math.max(m, a.end || a.start || 0),
        0
      );
      dur = maxTime * 1.1 || 1;
    }

    this._annotations.forEach((ann, i) => {
      const color = COLORS[i % COLORS.length];
      const leftPct = (ann.start / dur) * 100;
      const isRange = ann.end != null;
      const widthPct = isRange ? ((ann.end - ann.start) / dur) * 100 : 0;

      const seekTo = () => {
        const video = this._getVideo();
        if (video) {
          video.currentTime = ann.start;
          video.play().catch(() => {});
        }
      };

      const marker = document.createElement("div");
      marker.setAttribute("data-ann", ann.id);
      marker.style.position = "absolute";
      marker.style.top = "0";
      marker.style.height = "100%";
      marker.style.left = leftPct + "%";
      marker.style.cursor = "pointer";
      marker.style.transition = "filter 0.15s";

      if (isRange) {
        marker.style.width = widthPct + "%";
        marker.style.minWidth = "3px";
        marker.style.background = color.bg;
        marker.style.borderLeft = `2px solid ${color.border}`;
        marker.style.borderRight = `1px solid ${color.border}`;

        const inner = document.createElement("span");
        inner.textContent = ann.text;
        inner.style.cssText = `
          position:absolute;top:50%;left:4px;right:4px;
          transform:translateY(-50%);
          font-size:10px;line-height:1;
          color:white;text-shadow:0 1px 2px rgba(0,0,0,0.7);
          white-space:nowrap;overflow:hidden;text-overflow:ellipsis;
          pointer-events:none;
        `;
        marker.appendChild(inner);
      } else {
        marker.style.width = "3px";
        marker.style.background = color.border;
        marker.style.borderRadius = "1px";
      }

      const timeLabel = isRange
        ? `${window._fmtTime(ann.start)}–${window._fmtTime(ann.end)}`
        : window._fmtTime(ann.start);
      marker.title = `${timeLabel}: ${ann.text}`;

      marker.addEventListener("mouseenter", () => {
        marker.style.filter = "brightness(1.3)";
      });
      marker.addEventListener("mouseleave", () => {
        marker.style.filter = "";
      });
      marker.addEventListener("click", (e) => {
        e.stopPropagation();
        seekTo();
      });

      markersEl.appendChild(marker);

      const label = document.createElement("div");
      label.style.cssText = `
        position:absolute;
        left:${leftPct}%;
        top:0;
        font-size:10px;line-height:1.2;
        white-space:nowrap;
        cursor:pointer;
        padding:1px 3px;
        border-radius:2px;
        max-width:${isRange ? widthPct + "%" : "120px"};
        overflow:hidden;text-overflow:ellipsis;
      `;
      label.style.color = color.border;
      label.title = marker.title;
      label.textContent = ann.text;
      label.addEventListener("click", () => seekTo());
      label.addEventListener("mouseenter", () => {
        marker.style.filter = "brightness(1.3)";
        label.style.textDecoration = "underline";
      });
      label.addEventListener("mouseleave", () => {
        marker.style.filter = "";
        label.style.textDecoration = "";
      });

      labelsRow.appendChild(label);
    });

    this._layoutLabels();
  },

  _layoutLabels() {
    const labels = Array.from(this._labelsRow.children);
    if (!labels.length) return;

    labels.forEach((l) => (l.style.top = "0px"));

    for (let i = 1; i < labels.length; i++) {
      const prev = labels[i - 1];
      const cur = labels[i];
      const prevRect = prev.getBoundingClientRect();
      const curRect = cur.getBoundingClientRect();
      if (curRect.left < prevRect.right + 4) {
        const prevTop = parseFloat(prev.style.top) || 0;
        cur.style.top = prevTop + 14 + "px";
      }
    }

    const maxTop = labels.reduce(
      (m, l) => Math.max(m, parseFloat(l.style.top) || 0),
      0
    );
    this._labelsRow.style.minHeight = maxTop + 16 + "px";
  },

  // --- Animation loop: sync playhead to video ---

  _startSync() {
    const tick = () => {
      this._raf = requestAnimationFrame(tick);

      // Poll for annotation data changes
      this._readAnnotations();

      const video = this._getVideo();
      if (!video) return;

      const dur = video.duration;
      if (!isFinite(dur) || dur === 0) return;

      if (dur !== this._duration) {
        this._duration = dur;
        if (this._labelEnd) this._labelEnd.textContent = window._fmtTime(dur);
        this._renderMarkers();
      }

      // Don't update playhead while scrubbing — user controls it
      if (this._scrubbing) return;

      const pct = (video.currentTime / dur) * 100;
      if (this._playhead) this._playhead.style.left = pct + "%";
      if (this._labelCurrent)
        this._labelCurrent.textContent = window._fmtTime(video.currentTime);
    };
    this._raf = requestAnimationFrame(tick);
  },
};

export default AnnotationTimeline;
