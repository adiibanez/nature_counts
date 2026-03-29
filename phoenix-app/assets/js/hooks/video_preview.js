const VideoPreview = {
  mounted() {
    this._video = null;
    this._wrapper = null;
    this._label = null;
    this._currentUrl = null;
    this._pendingSeek = null;

    this.handleEvent("preview", ({ url, filename }) => {
      if (!url) {
        this._clear();
        return;
      }

      if (!this._video) this._buildPlayer();

      // Load new source if different, or reload on error
      if (this._currentUrl !== url || this._video.error) {
        this._pendingSeek = null;
        this._currentUrl = url;
        this._video.src = url;
        this._video.load();
      }

      this._label.title = filename;
      this._label.textContent = filename;
    });

    this.handleEvent("seek", ({ time }) => {
      if (!this._video) return;
      this._pendingSeek = time;
      this._trySeek();
    });
  },

  _buildPlayer() {
    this.el.replaceChildren();

    this._wrapper = document.createElement("div");
    this._wrapper.className = "bg-black rounded-lg overflow-hidden";

    this._video = document.createElement("video");
    this._video.controls = true;
    this._video.autoplay = true;
    this._video.muted = true;
    this._video.preload = "auto";
    this._video.className = "w-full h-auto max-h-[50vh]";
    this._wrapper.appendChild(this._video);

    this._label = document.createElement("p");
    this._label.className = "text-xs opacity-60 font-mono mt-1 truncate";

    this.el.appendChild(this._wrapper);
    this.el.appendChild(this._label);

    // Retry pending seek whenever video state advances
    this._video.addEventListener("loadedmetadata", () => this._trySeek());
    this._video.addEventListener("canplay", () => this._trySeek());
  },

  _trySeek() {
    const video = this._video;
    const time = this._pendingSeek;
    if (!video || time == null || video.readyState < 1) return;

    const t = isFinite(video.duration)
      ? Math.min(time, video.duration - 0.1)
      : time;

    this._pendingSeek = null;
    video.currentTime = t;
    video.play().catch(() => {});
  },

  _clear() {
    this._currentUrl = null;
    this._pendingSeek = null;
    if (this._video) {
      this._video.pause();
      this._video.removeAttribute("src");
      this._video.load();
    }
    this._video = null;
    this._wrapper = null;
    this._label = null;

    this.el.replaceChildren();
    const placeholder = document.createElement("div");
    placeholder.className =
      "flex items-center justify-center aspect-video bg-base-300 rounded-lg";
    const p = document.createElement("p");
    p.className = "text-base-content/40 text-sm";
    p.textContent = "Select a video to preview";
    placeholder.appendChild(p);
    this.el.appendChild(placeholder);
  },
};

export default VideoPreview;
