#!/usr/bin/env python3
"""
DeepStream 6.4 fish detection pipeline with per-camera RTSP output.

Pipeline:
  uridecodebin × N → nvstreammux → nvinfer(YOLOv12) → nvtracker(IOU) → nvstreamdemux
    ├─ src_0 → nvdsosd → nvvideoconvert → nvv4l2h264enc → h264parse → rtspclientsink → mediamtx /cam1
    ├─ src_1 → ...                                                                   → /cam2
    └─ src_N → ...                                                                   → /camN

Each camera branch pushes its H264 stream directly to MediaMTX via rtspclientsink.
MediaMTX serves the streams to browsers via WebRTC/HLS.

pyds extracts detection metadata (bboxes, tracking IDs) and pushes to Phoenix.
"""

import sys
import os
import time
import asyncio
import queue
import threading
import logging
from collections import defaultdict

import gi
gi.require_version("Gst", "1.0")
from gi.repository import Gst, GLib

from phoenix_channel_client import PhoenixChannelClient

# pyds must be built from source for DS 6.4 (pre-built wheels SIGABRT).
try:
    import pyds
    import numpy as np
    import cv2
    import base64
    HAS_PYDS = True
except Exception:
    HAS_PYDS = False

LABELS = ["fish"]
THUMB_SIZE = 96

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
logger = logging.getLogger("ds_fish_pipeline")

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
MUXER_WIDTH = 1920
MUXER_HEIGHT = 1080
MUXER_BATCH_TIMEOUT = 4000
INFER_INTERVAL = 3
GPU_ID = 0
TRACKER_WIDTH = 640
TRACKER_HEIGHT = 384

CONFIG_DIR = os.environ.get(
    "DS_CONFIG_DIR",
    "/opt/nvidia/deepstream/deepstream-6.4/samples/configs/deepstream-app-fish",
)
INFER_CONFIG = os.path.join(CONFIG_DIR, "config_infer_primary_cfd_yolov12_ds64.txt")
TRACKER_CONFIG = os.path.join(CONFIG_DIR, "config_tracker_IOU.yml")
TRACKER_LIB = "/opt/nvidia/deepstream/deepstream-6.4/lib/libnvds_nvmultiobjecttracker.so"

SOURCE_URIS = os.environ.get("SOURCE_URIS", "")
RTSP_BASE_URI = os.environ.get("RTSP_BASE_URI", "rtsp://mediamtx:8554/raw-cam")
NUM_SOURCES = int(os.environ.get("NUM_SOURCES", "1"))
FILE_LOOP = int(os.environ.get("FILE_LOOP", "0"))

RTSP_BITRATE = int(os.environ.get("RTSP_BITRATE", "4000000"))
ENABLE_THUMBNAILS = int(os.environ.get("ENABLE_THUMBNAILS", "1")) != 0

# Where to push processed RTSP streams (mediamtx)
RTSP_OUTPUT_BASE = os.environ.get("RTSP_OUTPUT_BASE", "rtsp://mediamtx:8554/cam")

PHOENIX_URL = os.environ.get("PHOENIX_URL", "ws://phoenix:4005/deepstream/websocket")
PHOENIX_TOKEN = os.environ.get("DEEPSTREAM_TOKEN", "dev-secret-token")


# ---------------------------------------------------------------------------
# Detection extraction + thumbnail cropping
#
# Two-stage approach:
#   1. Tracker probe (GStreamer thread): extracts metadata per camera, stores it
#   2. Appsink callback (GStreamer thread): copies RGBA frame (fast), dispatches
#      to worker thread for thumbnail cropping (slow CPU work off the pipeline)
# ---------------------------------------------------------------------------
_pending_detections = {}  # cam_id → latest detection dict (no thumbnails yet)
_det_lock = threading.Lock()
_det_frame_count = defaultdict(int)

# Worker queue: (frame_copy, det, src_w, src_h, frame_w, frame_h)
_thumb_queue = queue.Queue(maxsize=10)


def _crop_thumbnail(frame, bbox):
    """Crop bbox from RGBA frame → base64 JPEG."""
    try:
        x1 = max(0, int(bbox["left"]))
        y1 = max(0, int(bbox["top"]))
        x2 = min(frame.shape[1], int(bbox["left"] + bbox["width"]))
        y2 = min(frame.shape[0], int(bbox["top"] + bbox["height"]))
        if x2 <= x1 or y2 <= y1:
            return None
        crop = frame[y1:y2, x1:x2]
        crop = cv2.cvtColor(crop, cv2.COLOR_RGBA2BGR)
        h, w = crop.shape[:2]
        scale = min(THUMB_SIZE / max(h, w), 1.0)
        if scale < 1.0:
            crop = cv2.resize(crop, (int(w * scale), int(h * scale)))
        _, jpg = cv2.imencode(".jpg", crop, [cv2.IMWRITE_JPEG_QUALITY, 60])
        return base64.b64encode(jpg.tobytes()).decode("ascii")
    except Exception:
        return None


def _thumbnail_worker():
    """Background thread: crops thumbnails and pushes completed detections."""
    while True:
        try:
            frame, det, src_w, src_h, fw, fh = _thumb_queue.get(timeout=2)
        except queue.Empty:
            continue

        sx = fw / src_w if src_w else 1
        sy = fh / src_h if src_h else 1

        for obj in det["objects"]:
            bbox = obj["bbox"]
            scaled = {
                "left": bbox["left"] * sx,
                "top": bbox["top"] * sy,
                "width": bbox["width"] * sx,
                "height": bbox["height"] * sy,
            }
            thumb = _crop_thumbnail(frame, scaled)
            if thumb:
                obj["thumbnail"] = thumb

        try:
            detection_queue.put_nowait(det)
        except queue.Full:
            pass


def _make_appsink_callback(cam_id):
    """Appsink callback: copy frame (fast) and dispatch to worker thread."""
    def on_sample(appsink):
        sample = appsink.emit("pull-sample")
        if sample is None:
            return Gst.FlowReturn.OK

        with _det_lock:
            det = _pending_detections.pop(cam_id, None)
        if det is None:
            return Gst.FlowReturn.OK

        buf = sample.get_buffer()
        caps = sample.get_caps()
        struct = caps.get_structure(0)
        width = struct.get_value("width")
        height = struct.get_value("height")
        success, mapinfo = buf.map(Gst.MapFlags.READ)
        if not success:
            try:
                detection_queue.put_nowait(det)
            except queue.Full:
                pass
            return Gst.FlowReturn.OK

        # Fast copy — release the GStreamer buffer immediately
        frame = np.frombuffer(mapinfo.data, dtype=np.uint8).reshape(height, width, 4).copy()
        buf.unmap(mapinfo)

        src_w = det["resolution"]["width"] or MUXER_WIDTH
        src_h = det["resolution"]["height"] or MUXER_HEIGHT

        try:
            _thumb_queue.put_nowait((frame, det, src_w, src_h, width, height))
        except queue.Full:
            # Worker overloaded — push without thumbnails
            try:
                detection_queue.put_nowait(det)
            except queue.Full:
                pass

        return Gst.FlowReturn.OK
    return on_sample


def _tracker_src_probe(pad, info, _user_data):
    """Post-tracker probe: extract metadata, store for appsink to add thumbnails."""
    gst_buffer = info.get_buffer()
    if not gst_buffer:
        return Gst.PadProbeReturn.OK

    batch_meta = pyds.gst_buffer_get_nvds_batch_meta(hash(gst_buffer))
    if not batch_meta:
        return Gst.PadProbeReturn.OK

    l_frame = batch_meta.frame_meta_list
    while l_frame is not None:
        try:
            frame_meta = pyds.NvDsFrameMeta.cast(l_frame.data)
        except StopIteration:
            break

        source_id = frame_meta.source_id
        pts = frame_meta.buf_pts
        _det_frame_count[source_id] += 1

        objects = []
        l_obj = frame_meta.obj_meta_list
        while l_obj is not None:
            try:
                obj_meta = pyds.NvDsObjectMeta.cast(l_obj.data)
            except StopIteration:
                break

            class_id = obj_meta.class_id
            label = LABELS[class_id] if class_id < len(LABELS) else "object"
            rect = obj_meta.rect_params

            objects.append({
                "track_id": obj_meta.object_id,
                "class_id": class_id,
                "label": label,
                "confidence": round(obj_meta.confidence, 3),
                "bbox": {
                    "left": round(rect.left, 1),
                    "top": round(rect.top, 1),
                    "width": round(rect.width, 1),
                    "height": round(rect.height, 1),
                },
            })

            try:
                l_obj = l_obj.next
            except StopIteration:
                break

        det = {
            "cam_id": source_id,
            "ts": int(time.time() * 1000),
            "pts": pts,
            "resolution": {
                "width": frame_meta.source_frame_width,
                "height": frame_meta.source_frame_height,
            },
            "objects": objects,
        }
        if ENABLE_THUMBNAILS:
            # Store for appsink to add thumbnails
            with _det_lock:
                _pending_detections[source_id] = det
        else:
            # Push directly without thumbnails
            try:
                detection_queue.put_nowait(det)
            except queue.Full:
                pass

        try:
            l_frame = l_frame.next
        except StopIteration:
            break

    return Gst.PadProbeReturn.OK


# ---------------------------------------------------------------------------
# GStreamer pipeline
# ---------------------------------------------------------------------------
_h264_counts = defaultdict(int)


def create_pipeline():
    pipeline = Gst.Pipeline()

    # --- Sources ---
    if SOURCE_URIS:
        uris = [u.strip() for u in SOURCE_URIS.split(",") if u.strip()]
    else:
        uris = ["{0}{1}".format(RTSP_BASE_URI, i + 1) for i in range(NUM_SOURCES)]
    num_sources = len(uris)

    # --- Streammux ---
    streammux = Gst.ElementFactory.make("nvstreammux", "streammux")
    streammux.set_property("width", MUXER_WIDTH)
    streammux.set_property("height", MUXER_HEIGHT)
    streammux.set_property("batch-size", num_sources)
    streammux.set_property("batched-push-timeout", MUXER_BATCH_TIMEOUT)
    streammux.set_property("live-source", 1)
    streammux.set_property("gpu-id", GPU_ID)
    streammux.set_property("enable-padding", True)
    streammux.set_property("nvbuf-memory-type", 3)  # CUDA_UNIFIED
    pipeline.add(streammux)

    for i, uri in enumerate(uris):
        logger.info("Adding source %d: %s", i, uri)
        sinkpad = streammux.request_pad_simple("sink_{0}".format(i))

        source_bin = Gst.ElementFactory.make("uridecodebin", "source-{0}".format(i))
        source_bin.set_property("uri", uri)

        cpu_conv = Gst.ElementFactory.make("videoconvert", "cpu-conv-{0}".format(i))
        pipeline.add(cpu_conv)

        gpu_conv = Gst.ElementFactory.make("nvvideoconvert", "gpu-conv-{0}".format(i))
        gpu_conv.set_property("gpu-id", GPU_ID)
        gpu_conv.set_property("nvbuf-memory-type", 3)
        pipeline.add(gpu_conv)

        cpu_conv.link(gpu_conv)
        gpu_conv.get_static_pad("src").link(sinkpad)

        def pad_added_handler(decodebin, pad, conv=cpu_conv):
            caps = pad.get_current_caps()
            if not caps:
                return
            name = caps.get_structure(0).get_name()
            if name.startswith("video"):
                conv_sink = conv.get_static_pad("sink")
                if not conv_sink.is_linked():
                    ret = pad.link(conv_sink)
                    logger.info("Source %s: linked video pad (%s)", decodebin.get_name(), ret)

        source_bin.connect("pad-added", pad_added_handler)
        pipeline.add(source_bin)

    # --- nvinfer ---
    pgie = Gst.ElementFactory.make("nvinfer", "primary-inference")
    pgie.set_property("config-file-path", INFER_CONFIG)
    pgie.set_property("batch-size", num_sources)
    pgie.set_property("interval", INFER_INTERVAL)
    pgie.set_property("gpu-id", GPU_ID)
    pgie.set_property("unique-id", 1)
    pipeline.add(pgie)

    # --- Tracker ---
    tracker = Gst.ElementFactory.make("nvtracker", "tracker")
    tracker.set_property("tracker-width", TRACKER_WIDTH)
    tracker.set_property("tracker-height", TRACKER_HEIGHT)
    tracker.set_property("ll-lib-file", TRACKER_LIB)
    tracker.set_property("ll-config-file", TRACKER_CONFIG)
    tracker.set_property("gpu-id", GPU_ID)
    tracker.set_property("display-tracking-id", 1)
    pipeline.add(tracker)

    # --- nvstreamdemux ---
    demux = Gst.ElementFactory.make("nvstreamdemux", "demux")
    pipeline.add(demux)

    # --- Link core ---
    streammux.link(pgie)
    pgie.link(tracker)
    tracker.link(demux)

    # Detection metadata probe (after tracker, before demux)
    # Thumbnails are disabled: pyds.get_nvds_buf_surface needs RGBA but converting
    # the batched stream deadlocks the pipeline on desktop GPUs.
    if HAS_PYDS:
        tracker.get_static_pad("src").add_probe(
            Gst.PadProbeType.BUFFER, _tracker_src_probe, None
        )
        logger.info("pyds detection probe enabled")
    else:
        logger.warning("pyds not available — detection metadata disabled")

    # --- Per-camera branches ---
    # demux → q → tee ─┬─ q → osd → conv(I420) → enc → parse → rtspclientsink
    #                   └─ q(leaky,2fps) → conv(RGBA,CPU) → appsink (clean thumbs)
    for i in range(num_sources):
        rtsp_url = "{0}{1}".format(RTSP_OUTPUT_BASE, i + 1)
        logger.info("Branch %d: demux → tee → osd+enc / thumb → %s", i, rtsp_url)

        q = Gst.ElementFactory.make("queue", "q-{0}".format(i))
        pipeline.add(q)

        tee = Gst.ElementFactory.make("tee", "tee-{0}".format(i))
        pipeline.add(tee)

        # --- Render branch (OSD is here, after tee, so thumbnails get clean frames) ---
        q_render = Gst.ElementFactory.make("queue", "q-render-{0}".format(i))
        pipeline.add(q_render)

        # Default process-mode is GPU_MODE (1) — do NOT set to 0 (that's CPU!)
        osd = Gst.ElementFactory.make("nvdsosd", "osd-{0}".format(i))
        osd.set_property("display-text", 1)
        osd.set_property("display-bbox", 1)
        osd.set_property("display-mask", 0)
        pipeline.add(osd)

        conv = Gst.ElementFactory.make("nvvideoconvert", "conv-{0}".format(i))
        conv.set_property("gpu-id", GPU_ID)
        pipeline.add(conv)

        capsf = Gst.ElementFactory.make("capsfilter", "caps-{0}".format(i))
        capsf.set_property("caps", Gst.Caps.from_string(
            "video/x-raw(memory:NVMM), format=I420"
        ))
        pipeline.add(capsf)

        enc = Gst.ElementFactory.make("nvv4l2h264enc", "enc-{0}".format(i))
        enc.set_property("bitrate", RTSP_BITRATE)
        enc.set_property("iframeinterval", 15)
        pipeline.add(enc)

        parse = Gst.ElementFactory.make("h264parse", "parse-{0}".format(i))
        parse.set_property("config-interval", -1)
        pipeline.add(parse)

        rtsp_sink = Gst.ElementFactory.make("rtspclientsink", "rtsp-sink-{0}".format(i))
        rtsp_sink.set_property("location", rtsp_url)
        rtsp_sink.set_property("protocols", "tcp")
        pipeline.add(rtsp_sink)

        # --- Thumbnail branch: low-rate RGBA appsink for detection crops ---
        if ENABLE_THUMBNAILS:
            q_thumb = Gst.ElementFactory.make("queue", "q-thumb-{0}".format(i))
            q_thumb.set_property("max-size-buffers", 2)
            q_thumb.set_property("leaky", 2)
            pipeline.add(q_thumb)

            thumb_rate = Gst.ElementFactory.make("videorate", "thumb-rate-{0}".format(i))
            thumb_rate.set_property("drop-only", True)
            thumb_rate.set_property("max-rate", 2)
            pipeline.add(thumb_rate)

            thumb_conv = Gst.ElementFactory.make("nvvideoconvert", "thumb-conv-{0}".format(i))
            thumb_conv.set_property("gpu-id", GPU_ID)
            pipeline.add(thumb_conv)

            thumb_caps = Gst.ElementFactory.make("capsfilter", "thumb-caps-{0}".format(i))
            thumb_caps.set_property("caps", Gst.Caps.from_string(
                "video/x-raw, format=RGBA, width=480, height=270"
            ))
            pipeline.add(thumb_caps)

            appsink = Gst.ElementFactory.make("appsink", "thumb-sink-{0}".format(i))
            appsink.set_property("emit-signals", True)
            appsink.set_property("drop", True)
            appsink.set_property("max-buffers", 1)
            appsink.set_property("sync", False)
            appsink.connect("new-sample", _make_appsink_callback(i))
            pipeline.add(appsink)

        # --- Link ---
        demux_pad = demux.request_pad_simple("src_{0}".format(i))
        demux_pad.link(q.get_static_pad("sink"))
        q.link(tee)

        tee.link(q_render)
        q_render.link(osd)
        osd.link(conv)
        conv.link(capsf)
        capsf.link(enc)
        enc.link(parse)
        parse.link(rtsp_sink)

        if ENABLE_THUMBNAILS:
            tee.link(q_thumb)
            q_thumb.link(thumb_rate)
            thumb_rate.link(thumb_conv)
            thumb_conv.link(thumb_caps)
            thumb_caps.link(appsink)

    return pipeline, num_sources


# ---------------------------------------------------------------------------
# Detection queue (placeholder — pyds needed for metadata extraction)
# ---------------------------------------------------------------------------
detection_queue = queue.Queue(maxsize=100)


# ---------------------------------------------------------------------------
# Async Phoenix pusher
# ---------------------------------------------------------------------------
async def detection_pusher(phoenix):
    loop = asyncio.get_event_loop()
    while True:
        try:
            batch = await loop.run_in_executor(None, detection_queue.get, True, 1.0)
        except queue.Empty:
            continue
        try:
            await phoenix.push_detections(batch["cam_id"], batch)
        except Exception as e:
            logger.error("Failed to push detections: %s", e)
            raise


async def phoenix_connection_loop(phoenix):
    while True:
        try:
            await phoenix.connect()
            logger.info("Connected to Phoenix at %s", PHOENIX_URL)
            await detection_pusher(phoenix)
        except Exception as e:
            logger.error("Phoenix connection error: %s — retrying in 3s", e)
            while not detection_queue.empty():
                try:
                    detection_queue.get_nowait()
                except queue.Empty:
                    break
            await asyncio.sleep(3)


# ---------------------------------------------------------------------------
# GStreamer main loop
# ---------------------------------------------------------------------------
def run_gstreamer_loop():
    while True:
        pipeline, num_sources = create_pipeline()
        loop = GLib.MainLoop()

        bus = pipeline.get_bus()
        bus.add_signal_watch()

        def on_message(_, msg):
            t = msg.type
            if t == Gst.MessageType.EOS:
                src = msg.src.get_name() if msg.src else "unknown"
                logger.info("End of stream from %s", src)
                loop.quit()
            elif t == Gst.MessageType.ERROR:
                err, debug = msg.parse_error()
                src = msg.src.get_name() if msg.src else "unknown"
                logger.error("GStreamer error from %s: %s\n%s", src, err, debug)
                loop.quit()
            elif t == Gst.MessageType.WARNING:
                err, debug = msg.parse_warning()
                src = msg.src.get_name() if msg.src else "unknown"
                logger.warning("GStreamer warning from %s: %s\n%s", src, err, debug)
            elif t == Gst.MessageType.STATE_CHANGED:
                if msg.src == pipeline:
                    old, new, _pend = msg.parse_state_changed()
                    if new == Gst.State.PLAYING:
                        logger.info("Pipeline PLAYING")

        bus.connect("message", on_message)
        pipeline.set_state(Gst.State.PLAYING)

        try:
            loop.run()
        except KeyboardInterrupt:
            pipeline.set_state(Gst.State.NULL)
            break

        pipeline.set_state(Gst.State.NULL)
        del pipeline
        logger.info("Pipeline stopped")

        if not FILE_LOOP:
            break

        logger.info("Restarting pipeline...")
        time.sleep(1)


def main():
    phoenix = PhoenixChannelClient(
        phoenix_url=PHOENIX_URL,
        token=PHOENIX_TOKEN,
    )

    def phoenix_thread_fn():
        ev_loop = asyncio.new_event_loop()
        asyncio.set_event_loop(ev_loop)
        try:
            ev_loop.run_until_complete(phoenix_connection_loop(phoenix))
        finally:
            ev_loop.close()

    phoenix_thread = threading.Thread(target=phoenix_thread_fn, daemon=True)
    phoenix_thread.start()

    # Thumbnail worker — crops thumbnails off the GStreamer thread
    if ENABLE_THUMBNAILS:
        thumb_thread = threading.Thread(target=_thumbnail_worker, daemon=True)
        thumb_thread.start()

    # GStreamer runs in the main thread
    run_gstreamer_loop()


if __name__ == "__main__":
    Gst.init(None)
    main()
