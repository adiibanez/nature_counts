const VideoPreview = {
  mounted() {
    console.log("[VideoPreview] hook MOUNTED", this.el.id);
    this._video = null;
    this._wrapper = null;
    this._label = null;
    this._pendingSeek = null;

    this.handleEvent("preview", (data) => {
      console.log("[VideoPreview] preview event", data);
      const { url, filename } = data;
      if (!url) {
        this._clear();
        return;
      }

      if (this._video) {
        // Video element already exists — just swap the source
        if (this._video.src.endsWith(url)) {
          // Same video, no reload needed
          this._label.title = filename;
          this._label.textContent = filename;
          return;
        }
        this._video.src = url;
        this._video.load();
      } else {
        // First video — build the DOM once
        this.el.replaceChildren();

        this._wrapper = document.createElement("div");
        this._wrapper.className = "bg-black rounded-lg overflow-hidden";

        this._video = document.createElement("video");
        this._video.controls = true;
        this._video.autoplay = true;
        this._video.muted = true;
        this._video.preload = "auto";
        this._video.className = "w-full h-auto max-h-[50vh]";
        this._video.src = url;
        this._wrapper.appendChild(this._video);

        this._label = document.createElement("p");
        this._label.className = "text-xs opacity-60 font-mono mt-1 truncate";

        this.el.appendChild(this._wrapper);
        this.el.appendChild(this._label);
      }

      this._label.title = filename;
      this._label.textContent = filename;
    });

    this.handleEvent("seek", ({ time }) => {
      console.log("[seek] event received", { time, hasVideo: !!this._video });
      if (!this._video) return;

      this._pendingSeek = time;
      this._doSeek();
    });
  },

  _doSeek() {
    const video = this._video;
    const time = this._pendingSeek;
    if (!video || time == null) return;

    // readyState >= 1 means metadata is loaded (duration, dimensions known)
    if (video.readyState >= 1 && isFinite(video.duration)) {
      const clampedTime = Math.min(time, video.duration - 0.1);
      console.log("[seek] seeking to", clampedTime, "duration:", video.duration);
      video.currentTime = clampedTime;
      video.play().catch(() => {});
      this._pendingSeek = null;
    } else {
      console.log("[seek] waiting for video metadata, readyState:", video.readyState);
      // Wait for enough data to seek
      const onReady = () => {
        video.removeEventListener("canplay", onReady);
        video.removeEventListener("loadedmetadata", onReady);
        // Small delay to let the browser finish processing metadata
        setTimeout(() => this._doSeek(), 50);
      };
      video.addEventListener("loadedmetadata", onReady, { once: false });
      video.addEventListener("canplay", onReady, { once: false });

      // Timeout fallback: if metadata never loads, try seeking anyway after 3s
      setTimeout(() => {
        video.removeEventListener("canplay", onReady);
        video.removeEventListener("loadedmetadata", onReady);
        if (this._pendingSeek != null && video.readyState >= 1) {
          console.log("[seek] timeout fallback, attempting seek");
          const t = this._pendingSeek;
          this._pendingSeek = null;
          video.currentTime = isFinite(video.duration) ? Math.min(t, video.duration - 0.1) : t;
          video.play().catch(() => {});
        }
      }, 3000);
    }
  },

  _clear() {
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
    placeholder.className = "flex items-center justify-center aspect-video bg-base-300 rounded-lg";
    const p = document.createElement("p");
    p.className = "text-base-content/40 text-sm";
    p.textContent = "Select a video to preview";
    placeholder.appendChild(p);
    this.el.appendChild(placeholder);
  }
};

export default VideoPreview;
