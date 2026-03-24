/**
 * FishList — Phoenix LiveView Hook
 *
 * Subscribes to the detection channel for a camera and renders
 * fish cards into the panel. Works independently of the video player
 * (WebRTC VideoOverlay or Membrane).
 */

import { Socket } from "phoenix";

const FishList = {
  mounted() {
    const camId = this.el.dataset.camId;

    this.fishGrid = document.getElementById(`fish-grid-cam${camId}`);
    this.fishCount = document.getElementById(`fish-count-cam${camId}`);
    this.fishEmpty = document.getElementById(`fish-empty-cam${camId}`);
    this.camId = camId;

    // --- Phoenix Channel for detection events ---
    const socket = new Socket("/user", {});
    socket.connect();

    const topic = `detections:${camId}`;
    const channel = socket.channel(topic, {});
    channel.join()
      .receive("ok", () => console.log(`[FishList cam${camId}] Joined ${topic}`))
      .receive("error", (resp) => console.error(`[FishList cam${camId}] Join error:`, resp));

    channel.on("detection_update", (msg) => {
      this._renderFishList(msg);

      // Staleness watchdog: clear display if no detection arrives within 2s
      clearTimeout(this._staleTimer);
      this._staleTimer = setTimeout(() => {
        this._renderFishList({ objects: [] });
      }, 2000);
    });

    this.channel = channel;
    this.socket = socket;
    this._staleTimer = null;

    this._syncFishCols();
  },

  updated() {
    this._syncFishCols();
  },

  _syncFishCols() {
    const cols = parseInt(this.el.dataset.fishCols, 10) || 1;
    if (this.fishGrid) {
      this.fishGrid.style.gridTemplateColumns = `repeat(${cols}, minmax(0, 1fr))`;
    }
  },

  _renderFishList(detection) {
    if (!this.fishGrid) return;

    const objects = detection.objects || [];
    objects.sort((a, b) => a.track_id - b.track_id);

    if (this.fishCount) {
      this.fishCount.textContent = objects.length;
    }
    if (this.fishEmpty) {
      this.fishEmpty.style.display = objects.length === 0 ? "" : "none";
    }

    const cols = parseInt(this.el.dataset.fishCols, 10) || 1;

    const html = objects.map((obj) => {
      const left = Math.round(obj.bbox.left);
      const top = Math.round(obj.bbox.top);
      const width = Math.round(obj.bbox.width);
      const height = Math.round(obj.bbox.height);
      const bboxStr = `${left},${top} ${width}\u00d7${height}`;

      if (cols === 1) {
        const thumb = obj.thumbnail
          ? `<img src="data:image/jpeg;base64,${obj.thumbnail}"
                 alt="Fish ${obj.track_id}"
                 class="w-14 h-14 rounded object-cover bg-black shrink-0" />`
          : `<div class="w-14 h-14 rounded bg-base-300 shrink-0"></div>`;

        return `<div class="flex items-center gap-2 p-2 rounded-lg bg-base-200 shadow-sm">
          ${thumb}
          <div class="min-w-0 flex-1">
            <div class="flex items-center justify-between">
              <span class="font-mono text-sm font-bold">#${obj.track_id}</span>
              <span class="badge badge-xs badge-accent">${obj.label}</span>
            </div>
            <div class="text-xs text-base-content/50 font-mono mt-0.5">${bboxStr}</div>
          </div>
        </div>`;
      } else {
        const thumb = obj.thumbnail
          ? `<figure class="bg-black">
               <img src="data:image/jpeg;base64,${obj.thumbnail}"
                    alt="Fish ${obj.track_id}"
                    class="w-full h-20 object-contain" />
             </figure>`
          : "";

        return `<div class="card card-compact bg-base-200 shadow-sm">
          ${thumb}
          <div class="card-body p-2">
            <div class="flex items-center justify-between">
              <span class="font-mono text-xs font-bold">#${obj.track_id}</span>
              <span class="badge badge-xs badge-accent">${obj.label}</span>
            </div>
            <div class="text-xs text-base-content/50 font-mono">${bboxStr}</div>
          </div>
        </div>`;
      }
    }).join("");

    this.fishGrid.innerHTML = html;
  },

  destroyed() {
    if (this.channel) this.channel.leave();
    if (this.socket) this.socket.disconnect();
    if (this._staleTimer) clearTimeout(this._staleTimer);
  },
};

export default FishList;
