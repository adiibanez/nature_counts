const VideoPreview = {
  mounted() {
    this._video = null;
    this._wrapper = null;
    this._label = null;

    this.handleEvent("preview", ({ url, filename }) => {
      if (!url) {
        this._clear();
        return;
      }

      if (this._video) {
        // Video element already exists — just swap the source
        if (this._video.src.endsWith(url)) return;
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
  },

  _clear() {
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
