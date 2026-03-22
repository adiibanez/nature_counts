/**
 * VideoOverlay — Phoenix LiveView Hook
 *
 * Plays DeepStream video via MediaMTX WebRTC and renders a frame-accurate
 * fish list below the video.
 *
 * Detection events arrive via Phoenix Channel ~200ms BEFORE the video frame
 * is displayed (WebRTC jitter buffer). We buffer detections and apply them
 * when the video catches up, using requestVideoFrameCallback for sync.
 *
 * PTS flow: DeepStream GStreamer PTS (ns) → RTP timestamp (90kHz) → WebRTC
 *           → browser mediaTime (seconds). We auto-calibrate the PTS offset
 *           using the median of the first CALIBRATION_SAMPLES pairs, then
 *           refine it with an exponential moving average on every match.
 */

import { Socket } from "phoenix";

/** Convert GStreamer PTS (nanoseconds) to seconds. */
const ptsToSeconds = (pts) => pts / 1_000_000_000;

// --- Sync tuning constants ---
/** Number of detection/frame pairs used for initial calibration. */
const CALIBRATION_SAMPLES = 10;
/** Max age (seconds) for buffered detections — older entries are pruned. */
const MAX_BUFFER_AGE = 2.0;
/** Max staleness (seconds) — a matched detection older than this is discarded. */
const MAX_STALE = 0.5;
/** EMA smoothing factor for running offset refinement (0 = no update, 1 = instant). */
const EMA_ALPHA = 0.05;
/** Interval (ms) for periodic debug logging. */
const DEBUG_LOG_INTERVAL = 5000;

const VideoOverlay = {
  mounted() {
    const video = this.el.querySelector("video");
    const camId = this.el.dataset.camId;
    const webrtcUrl = this.el.dataset.webrtcUrl;

    // DOM references for the fish list (outside the hook's element)
    this.fishGrid = document.getElementById(`fish-grid-cam${camId}`);
    this.fishCount = document.getElementById(`fish-count-cam${camId}`);
    this.fishEmpty = document.getElementById(`fish-empty-cam${camId}`);

    // Initialize sync state
    this._resetCalibration();
    this._staleTimer = null;

    // --- Loading spinner (managed in JS to survive LiveView patches) ---
    this._showSpinner(video);

    // --- WebRTC via MediaMTX's WHEP endpoint ---
    this._startWebRTC(video, webrtcUrl, camId);

    // --- Phoenix Channel for detection events ---
    const socket = new Socket("/user", {});
    socket.connect();

    const topic = `detections:${camId}`;
    const channel = socket.channel(topic, {});
    channel.join()
      .receive("ok", () => console.log(`[cam${camId}] Joined ${topic}`))
      .receive("error", (resp) => console.error(`[cam${camId}] Join error:`, resp));

    channel.on("detection_update", (msg) => {
      if (this._paused) return; // Tab is hidden — drop incoming detections

      // If resuming after staleness timeout, re-calibrate PTS sync
      if (this._staleTimer === null && this._currentDetection === null) {
        this._resetCalibration();
      }

      this._currentDetection = msg;
      this._renderFishList(msg);

      // Staleness watchdog: clear display if no detection arrives within 2s
      clearTimeout(this._staleTimer);
      this._staleTimer = setTimeout(() => {
        this._currentDetection = null;
        this._renderFishList({ objects: [] });
        this._staleTimer = null;
      }, 2000);
    });

    this.channel = channel;
    this.socket = socket;
    this.video = video;
    this.camId = camId;
    this._currentWebrtcUrl = webrtcUrl;

    // Apply initial column count from data attribute
    this._syncFishCols();

    // --- requestVideoFrameCallback for frame-accurate sync ---
    this._startFrameSync(video);

    // --- Tab visibility handling (#5) ---
    this._onVisibilityChange = () => {
      if (document.hidden) {
        this._paused = true;
      } else {
        // Flush stale state and re-calibrate on return
        this._resetCalibration();
        this._paused = false;
      }
    };
    document.addEventListener("visibilitychange", this._onVisibilityChange);

    // --- Debug logging (#7) ---
    this._debugStats = { detectionsReceived: 0, lastLogTime: performance.now() };
    this._debugInterval = setInterval(() => this._logDebugStats(), DEBUG_LOG_INTERVAL);
  },

  /**
   * Called by LiveView when the hook element's attributes change.
   * Handles data-fish-cols changes and data-webrtc-url changes (inference toggle).
   */
  updated() {
    this._syncFishCols();

    const newUrl = this.el.dataset.webrtcUrl;
    if (newUrl && newUrl !== this._currentWebrtcUrl) {
      console.log(`[cam${this.camId}] WebRTC URL changed, reconnecting...`);
      this._currentWebrtcUrl = newUrl;
      if (this.pc) {
        this.pc.close();
        this.pc = null;
      }
      this._resetCalibration();
      this._startWebRTC(this.video, newUrl, this.camId);
    }
  },

  /**
   * Read data-fish-cols from the hook element and apply to the fish grid.
   */
  _syncFishCols() {
    const cols = parseInt(this.el.dataset.fishCols, 10) || 1;
    if (this.fishGrid) {
      this.fishGrid.style.gridTemplateColumns = `repeat(${cols}, minmax(0, 1fr))`;
    }
  },

  /**
   * Reset all PTS calibration and buffer state.
   * Called on mount, WebRTC reconnect, and tab re-focus.
   */
  _resetCalibration() {
    this._detectionBuffer = [];
    this._currentDetection = null;
    this._ptsOffset = null;
    this._calibrated = false;
    this._calibrationSamples = [];
    this._paused = false;
    this._lastMatchDelta = null;
  },

  /**
   * Buffer a detection event and collect calibration samples.
   */
  _bufferDetection(msg) {
    const detPts = ptsToSeconds(msg.pts);

    this._detectionBuffer.push({ mediaTimePts: detPts, msg });

    // Track reception rate for debug logging
    if (this._debugStats) this._debugStats.detectionsReceived++;

    // Cap buffer size (drop old entries)
    if (this._detectionBuffer.length > 300) {
      this._detectionBuffer.splice(0, this._detectionBuffer.length - 300);
    }
  },

  /**
   * Collect a calibration sample (detection PTS paired with video mediaTime).
   * After CALIBRATION_SAMPLES pairs, compute offset from the median.
   */
  _addCalibrationSample(detPts, mediaTime) {
    if (this._calibrated) return;

    const sampleOffset = mediaTime - detPts;
    this._calibrationSamples.push(sampleOffset);

    if (this._calibrationSamples.length >= CALIBRATION_SAMPLES) {
      // Use median for robustness against outliers
      const sorted = [...this._calibrationSamples].sort((a, b) => a - b);
      const mid = Math.floor(sorted.length / 2);
      this._ptsOffset = sorted.length % 2 === 0
        ? (sorted[mid - 1] + sorted[mid]) / 2
        : sorted[mid];
      this._calibrated = true;
      console.log(
        `[cam${this.camId}] PTS sync calibrated (median of ${sorted.length}): offset=${this._ptsOffset.toFixed(3)}s`
      );
    }
  },

  /**
   * Refine the offset with an exponential moving average (#1).
   */
  _refineOffset(detPts, mediaTime) {
    if (!this._calibrated) return;
    const instantOffset = mediaTime - detPts;
    this._ptsOffset = this._ptsOffset * (1 - EMA_ALPHA) + instantOffset * EMA_ALPHA;
  },

  /**
   * Use requestVideoFrameCallback to apply buffered detections in sync
   * with video frame presentation.
   */
  _startFrameSync(video) {
    if (!("requestVideoFrameCallback" in HTMLVideoElement.prototype)) {
      // Fallback: apply detections immediately (no sync)
      console.warn("requestVideoFrameCallback not supported, using fallback");
      return;
    }

    const onFrame = (_now, metadata) => {
      const mediaTime = metadata.mediaTime;

      // --- Age-based buffer eviction (#4) ---
      if (this._calibrated && this._detectionBuffer.length > 0) {
        const cutoff = mediaTime - MAX_BUFFER_AGE;
        // Find how many entries are too old
        let pruneCount = 0;
        for (let i = 0; i < this._detectionBuffer.length; i++) {
          const detMediaTime = this._detectionBuffer[i].mediaTimePts + this._ptsOffset;
          if (detMediaTime < cutoff) {
            pruneCount = i + 1;
          } else {
            break;
          }
        }
        if (pruneCount > 0) {
          this._detectionBuffer.splice(0, pruneCount);
        }
      }

      // --- Calibration: collect samples from matched pairs (#2) ---
      if (!this._calibrated && mediaTime > 0 && this._detectionBuffer.length > 0) {
        // Pair the oldest buffered detection with the current frame as a calibration sample
        const oldest = this._detectionBuffer[0];
        this._addCalibrationSample(oldest.mediaTimePts, mediaTime);
      }

      // --- Frame-accurate detection matching ---
      if (this._calibrated && this._detectionBuffer.length > 0) {
        const targetMediaTime = mediaTime;
        let bestIdx = -1;

        for (let i = 0; i < this._detectionBuffer.length; i++) {
          const detMediaTime = this._detectionBuffer[i].mediaTimePts + this._ptsOffset;
          if (detMediaTime <= targetMediaTime) {
            bestIdx = i;
          } else {
            break; // buffer is sorted by PTS
          }
        }

        if (bestIdx >= 0) {
          const matched = this._detectionBuffer[bestIdx];
          const detMediaTime = matched.mediaTimePts + this._ptsOffset;
          const delta = targetMediaTime - detMediaTime;

          // --- Staleness threshold (#6) ---
          if (delta <= MAX_STALE) {
            this._detectionBuffer.splice(0, bestIdx + 1);
            this._currentDetection = matched.msg;
            this._renderFishList(matched.msg);
            this._lastMatchDelta = delta;

            // --- Running offset EMA refinement (#1) ---
            this._refineOffset(matched.mediaTimePts, targetMediaTime);
          } else {
            // Detection is too stale — discard it and clear the display
            this._detectionBuffer.splice(0, bestIdx + 1);
            this._currentDetection = null;
            this._renderFishList({ objects: [] });
            this._lastMatchDelta = null;
          }
        }
      }

      // Schedule next frame callback
      video.requestVideoFrameCallback(onFrame);
    };

    video.requestVideoFrameCallback(onFrame);
  },

  /**
   * Periodic debug logging (#7).
   */
  _logDebugStats() {
    const now = performance.now();
    const elapsed = (now - this._debugStats.lastLogTime) / 1000;
    const rate = elapsed > 0 ? (this._debugStats.detectionsReceived / elapsed).toFixed(1) : 0;

    console.log(
      `[cam${this.camId}] sync: buf=${this._detectionBuffer.length}` +
      ` offset=${this._ptsOffset !== null ? this._ptsOffset.toFixed(3) : "n/a"}` +
      ` lastDelta=${this._lastMatchDelta !== null ? (this._lastMatchDelta * 1000).toFixed(1) + "ms" : "n/a"}` +
      ` det/s=${rate}` +
      ` calibrated=${this._calibrated}` +
      ` paused=${this._paused}`
    );

    this._debugStats.detectionsReceived = 0;
    this._debugStats.lastLogTime = now;
  },

  /**
   * Render fish cards into the DOM.
   */
  _renderFishList(detection) {
    if (!this.fishGrid) return;

    const objects = detection.objects || [];
    // Sort by track_id
    objects.sort((a, b) => a.track_id - b.track_id);

    // Update count
    if (this.fishCount) {
      this.fishCount.textContent = objects.length;
    }
    // Toggle empty message
    if (this.fishEmpty) {
      this.fishEmpty.style.display = objects.length === 0 ? "" : "none";
    }

    const cols = parseInt(this.el.dataset.fishCols, 10) || 1;

    // Build card HTML — horizontal row for 1 col, vertical card for multi-col
    const html = objects.map((obj) => {
      const left = Math.round(obj.bbox.left);
      const top = Math.round(obj.bbox.top);
      const width = Math.round(obj.bbox.width);
      const height = Math.round(obj.bbox.height);
      const bboxStr = `${left},${top} ${width}\u00d7${height}`;

      if (cols === 1) {
        // Horizontal compact row
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
        // Vertical card for grid
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

  _showSpinner(video) {
    if (this._spinner) return;
    const spinner = document.createElement("div");
    spinner.className = "absolute inset-0 flex items-center justify-center bg-black text-white/60";
    spinner.innerHTML = '<span class="loading loading-spinner loading-lg"></span>';
    this._spinner = spinner;
    video.parentElement.appendChild(spinner);
  },

  _hideSpinner() {
    if (this._spinner) {
      this._spinner.remove();
      this._spinner = null;
    }
  },

  async _startWebRTC(video, webrtcUrl, camId) {
    try {
      const pc = new RTCPeerConnection({
        iceServers: [{ urls: "stun:stun.l.google.com:19302" }],
      });

      pc.addTransceiver("video", { direction: "recvonly" });

      pc.ontrack = (event) => {
        console.log(`[cam${camId}] WebRTC track received`);
        video.srcObject = event.streams[0];
        video.play().catch(() => {});

        video.addEventListener("playing", () => this._hideSpinner(), { once: true });
      };

      pc.oniceconnectionstatechange = () => {
        console.log(`[cam${camId}] ICE state: ${pc.iceConnectionState}`);
        if (pc.iceConnectionState === "failed" || pc.iceConnectionState === "disconnected") {
          console.warn(`[cam${camId}] WebRTC disconnected, retrying in 3s...`);
          this._resetCalibration();
          this._showSpinner(video);
          setTimeout(() => this._startWebRTC(video, webrtcUrl, camId), 3000);
        }
      };

      const offer = await pc.createOffer();
      await pc.setLocalDescription(offer);

      // Wait for ICE gathering to complete
      await new Promise((resolve) => {
        if (pc.iceGatheringState === "complete") {
          resolve();
        } else {
          pc.onicegatheringstatechange = () => {
            if (pc.iceGatheringState === "complete") resolve();
          };
          setTimeout(resolve, 3000);
        }
      });

      const response = await fetch(webrtcUrl, {
        method: "POST",
        headers: { "Content-Type": "application/sdp" },
        body: pc.localDescription.sdp,
      });

      if (!response.ok) {
        throw new Error(`WHEP response ${response.status}: ${await response.text()}`);
      }

      const answerSdp = await response.text();
      await pc.setRemoteDescription({ type: "answer", sdp: answerSdp });

      this.pc = pc;
      console.log(`[cam${camId}] WebRTC connected`);
    } catch (err) {
      console.error(`[cam${camId}] WebRTC error:`, err);
      this._resetCalibration();
      this._showSpinner(video);
      setTimeout(() => this._startWebRTC(video, webrtcUrl, camId), 3000);
    }
  },

  destroyed() {
    if (this.pc) {
      this.pc.close();
      this.pc = null;
    }
    if (this.channel) this.channel.leave();
    if (this.socket) this.socket.disconnect();
    if (this._onVisibilityChange) {
      document.removeEventListener("visibilitychange", this._onVisibilityChange);
    }
    this._hideSpinner();
    if (this._staleTimer) {
      clearTimeout(this._staleTimer);
    }
    if (this._debugInterval) {
      clearInterval(this._debugInterval);
    }
  },
};

export default VideoOverlay;
