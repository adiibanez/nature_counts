const FloatingPreview = {
  mounted() {
    this._floating = false;
    this._dragging = false;
    this._resizing = false;
    this._resizeDir = null;
    this._startX = 0;
    this._startY = 0;
    this._startW = 0;
    this._startH = 0;
    this._startLeft = 0;
    this._startTop = 0;

    // Current floating geometry (updated on drag/resize, persisted to localStorage)
    this._geo = null; // { left, top, width, height } or null = use defaults

    this._onMouseMove = this._onMouseMove.bind(this);
    this._onMouseUp = this._onMouseUp.bind(this);

    // Load saved geometry from localStorage
    this._geo = this._loadGeo();

    this.handleEvent("set_preview_floating", ({ floating }) => {
      this._floating = floating;
      if (floating) this._applyFloating();
      else this._clearFloating();
    });
  },

  // Re-apply floating styles after every LiveView DOM patch
  updated() {
    if (this._floating) this._applyFloating();
  },

  destroyed() {
    document.removeEventListener("mousemove", this._onMouseMove);
    document.removeEventListener("mouseup", this._onMouseUp);
  },

  // Apply (or re-apply) all floating styles + handles to the element.
  // Safe to call repeatedly — idempotent.
  _applyFloating() {
    const el = this.el;
    const g = this._geo || { width: 480, right: 24, bottom: 24 };

    el.style.position = "fixed";
    el.style.zIndex = "1000";
    el.style.maxHeight = "80vh";
    el.style.overflow = "auto";
    el.style.boxShadow = "0 8px 32px rgba(0,0,0,0.4)";
    el.style.borderRadius = "0.75rem";
    el.style.transition = "none";

    if (g.left != null) {
      // Positioned via left/top (after drag or from saved state)
      el.style.left = g.left + "px";
      el.style.top = g.top + "px";
      el.style.right = "auto";
      el.style.bottom = "auto";
    } else {
      // Default: bottom-right corner
      el.style.right = (g.right || 24) + "px";
      el.style.bottom = (g.bottom || 24) + "px";
      el.style.left = "auto";
      el.style.top = "auto";
    }

    el.style.width = (g.width || 480) + "px";
    if (g.height) el.style.height = g.height + "px";

    // Add handles + drag bar (idempotent — they check before adding)
    this._ensureHandles();
    this._ensureDragBar();
  },

  _clearFloating() {
    const el = this.el;
    const props = [
      "position", "zIndex", "width", "height", "right", "bottom",
      "left", "top", "maxHeight", "overflow", "boxShadow",
      "borderRadius", "transition",
    ];
    for (const p of props) el.style[p] = "";

    this._removeHandles();
    this._removeDragBar();
  },

  _ensureDragBar() {
    if (this.el.querySelector(".float-drag-bar")) return;

    const bar = document.createElement("div");
    bar.className = "float-drag-bar";
    bar.style.cssText =
      "position:absolute;top:0;left:0;right:0;height:20px;cursor:grab;z-index:10;" +
      "display:flex;align-items:center;justify-content:center;";

    const grip = document.createElement("div");
    grip.style.cssText =
      "width:40px;height:4px;border-radius:2px;background:rgba(255,255,255,0.3);";
    bar.appendChild(grip);

    bar.addEventListener("mousedown", (e) => {
      e.preventDefault();
      this._dragging = true;
      this._startX = e.clientX;
      this._startY = e.clientY;

      const rect = this.el.getBoundingClientRect();
      this._startLeft = rect.left;
      this._startTop = rect.top;

      document.addEventListener("mousemove", this._onMouseMove);
      document.addEventListener("mouseup", this._onMouseUp);
    });

    this.el.insertBefore(bar, this.el.firstChild);
  },

  _removeDragBar() {
    const bar = this.el.querySelector(".float-drag-bar");
    if (bar) bar.remove();
  },

  _ensureHandles() {
    if (this.el.querySelector(".float-resize-handle")) return;

    const dirs = [
      { name: "se", cursor: "nwse-resize", pos: "bottom:0;right:0;" },
      { name: "sw", cursor: "nesw-resize", pos: "bottom:0;left:0;" },
      { name: "ne", cursor: "nesw-resize", pos: "top:0;right:0;" },
      { name: "nw", cursor: "nwse-resize", pos: "top:0;left:0;" },
      { name: "e", cursor: "ew-resize", pos: "top:0;right:0;bottom:0;width:6px;height:auto;" },
      { name: "w", cursor: "ew-resize", pos: "top:0;left:0;bottom:0;width:6px;height:auto;" },
      { name: "s", cursor: "ns-resize", pos: "bottom:0;left:0;right:0;height:6px;width:auto;" },
      { name: "n", cursor: "ns-resize", pos: "top:0;left:0;right:0;height:6px;width:auto;" },
    ];

    for (const d of dirs) {
      const handle = document.createElement("div");
      handle.className = "float-resize-handle";
      handle.dataset.dir = d.name;
      const isCorner = d.name.length === 2;
      handle.style.cssText =
        `position:absolute;${d.pos}z-index:11;cursor:${d.cursor};` +
        (isCorner ? "width:12px;height:12px;" : "");

      handle.addEventListener("mousedown", (e) => {
        e.preventDefault();
        e.stopPropagation();
        this._resizing = true;
        this._resizeDir = d.name;
        this._startX = e.clientX;
        this._startY = e.clientY;

        const rect = this.el.getBoundingClientRect();
        this._startW = rect.width;
        this._startH = rect.height;
        this._startLeft = rect.left;
        this._startTop = rect.top;

        document.addEventListener("mousemove", this._onMouseMove);
        document.addEventListener("mouseup", this._onMouseUp);
      });

      this.el.appendChild(handle);
    }
  },

  _removeHandles() {
    this.el.querySelectorAll(".float-resize-handle").forEach((h) => h.remove());
  },

  _onMouseMove(e) {
    const dx = e.clientX - this._startX;
    const dy = e.clientY - this._startY;

    if (this._dragging) {
      const newLeft = Math.max(0, Math.min(this._startLeft + dx, window.innerWidth - 100));
      const newTop = Math.max(0, Math.min(this._startTop + dy, window.innerHeight - 50));
      this.el.style.left = newLeft + "px";
      this.el.style.top = newTop + "px";
      this.el.style.right = "auto";
      this.el.style.bottom = "auto";
    }

    if (this._resizing) {
      const dir = this._resizeDir;
      const minW = 280;
      const minH = 200;

      let newW = this._startW;
      let newH = this._startH;
      let newLeft = this._startLeft;
      let newTop = this._startTop;

      if (dir.includes("e")) newW = Math.max(minW, this._startW + dx);
      if (dir.includes("w")) {
        newW = Math.max(minW, this._startW - dx);
        newLeft = this._startLeft + (this._startW - newW);
      }
      if (dir.includes("s")) newH = Math.max(minH, this._startH + dy);
      if (dir.includes("n")) {
        newH = Math.max(minH, this._startH - dy);
        newTop = this._startTop + (this._startH - newH);
      }

      this.el.style.width = newW + "px";
      this.el.style.height = newH + "px";
      this.el.style.left = newLeft + "px";
      this.el.style.top = newTop + "px";
    }
  },

  _onMouseUp() {
    this._dragging = false;
    this._resizing = false;
    this._resizeDir = null;
    document.removeEventListener("mousemove", this._onMouseMove);
    document.removeEventListener("mouseup", this._onMouseUp);

    // Capture current geometry into _geo and persist
    if (this._floating) {
      const rect = this.el.getBoundingClientRect();
      this._geo = {
        left: rect.left,
        top: rect.top,
        width: rect.width,
        height: rect.height,
      };
      this._saveGeo();
    }
  },

  _saveGeo() {
    try {
      localStorage.setItem("floating_preview", JSON.stringify(this._geo));
    } catch (_) {}
  },

  _loadGeo() {
    try {
      const raw = localStorage.getItem("floating_preview");
      if (raw) return JSON.parse(raw);
    } catch (_) {}
    return null;
  },
};

export default FloatingPreview;
