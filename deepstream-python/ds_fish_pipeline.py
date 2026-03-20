#!/usr/bin/env python3
"""
DeepStream Python fish detection pipeline with Phoenix Channel integration.

DS 6.4 pipeline with nvstreamdemux for per-camera output:
  uridecodebin → nvstreammux → nvinfer(YOLOv12) → nvtracker(IOU) → nvstreamdemux
    ├─ src_0 → nvdsosd → tee → encoder → rtspclientsink → mediamtx/cam1
    │                       └─ appsink (per-camera thumbnails)
    ├─ src_1 → nvdsosd → tee → encoder → rtspclientsink → mediamtx/cam2
    └─ src_N → nvdsosd → tee → encoder → rtspclientsink → mediamtx/camN

No tiler. No ffmpeg forwarder. Full resolution per camera.
Probe on tracker src pad extracts metadata → Phoenix Channel → browser stats.
"""

import sys
import os
import time
import asyncio
import queue
import threading
import logging
import base64
from collections import defaultdict

import gi
gi.require_version("Gst", "1.0")
from gi.repository import Gst, GLib

import pyds
import numpy as np
import cv2

from phoenix_channel_client import PhoenixChannelClient

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
MEDIAMTX_RTSP_URL = os.environ.get("MEDIAMTX_RTSP_URL", "rtsp://mediamtx:8554")

PHOENIX_URL = os.environ.get("PHOENIX_URL", "ws://phoenix:4005/deepstream/websocket")
PHOENIX_TOKEN = os.environ.get("DEEPSTREAM_TOKEN", "dev-secret-token")

PUSH_INTERVAL = 0.1  # 10 Hz
THUMBNAIL_MAX_PX = 96
THUMBNAIL_JPEG_QUALITY = 70

# OSD settings
OSD_BORDER_WIDTH = int(os.environ.get("OSD_BORDER_WIDTH", "2"))
OSD_TEXT_SIZE = int(os.environ.get("OSD_TEXT_SIZE", "12"))


# ---------------------------------------------------------------------------
# Per-camera frame store — updated by per-camera appsinks
# ---------------------------------------------------------------------------
_latest_frames = {}  # cam_id → numpy array (RGBA)
_frame_lock = threading.Lock()


def _make_appsink_callback(cam_id):
    """Create an appsink callback that stores the latest frame for a specific camera."""
    def on_sample(appsink):
        sample = appsink.emit("pull-sample")
        if sample is None:
            return Gst.FlowReturn.OK
        buf = sample.get_buffer()
        caps = sample.get_caps()
        struct = caps.get_structure(0)
        width = struct.get_value("width")
        height = struct.get_value("height")
        success, mapinfo = buf.map(Gst.MapFlags.READ)
        if success:
            frame = np.frombuffer(mapinfo.data, dtype=np.uint8).reshape(height, width, 4)
            with _frame_lock:
                _latest_frames[cam_id] = frame.copy()
            buf.unmap(mapinfo)
        return Gst.FlowReturn.OK
    return on_sample


def crop_thumbnail(bbox, cam_id=0):
    """Crop a bbox region from the per-camera frame and return base64 JPEG, or None."""
    with _frame_lock:
        frame = _latest_frames.get(cam_id)
    if frame is None:
        return None
    try:
        # Bbox coords are already in source resolution — no tile offset math needed
        x1 = max(0, int(bbox["left"]))
        y1 = max(0, int(bbox["top"]))
        x2 = min(frame.shape[1], int(bbox["left"] + bbox["width"]))
        y2 = min(frame.shape[0], int(bbox["top"] + bbox["height"]))
        if x2 <= x1 or y2 <= y1:
            return None
        crop = frame[y1:y2, x1:x2]
        crop = cv2.cvtColor(crop, cv2.COLOR_RGBA2BGR)
        ch, cw = crop.shape[:2]
        scale = min(THUMBNAIL_MAX_PX / max(ch, cw), 1.0)
        if scale < 1.0:
            crop = cv2.resize(crop, (int(cw * scale), int(ch * scale)))
        _, jpeg = cv2.imencode(".jpg", crop, [cv2.IMWRITE_JPEG_QUALITY, THUMBNAIL_JPEG_QUALITY])
        return base64.b64encode(jpeg.tobytes()).decode("ascii")
    except Exception as e:
        logger.debug("crop_thumbnail failed: %s", e)
        return None

# ---------------------------------------------------------------------------
# Detection queue
# ---------------------------------------------------------------------------
detection_queue = queue.Queue(maxsize=100)
last_push_time = defaultdict(float)
frame_count = [0]  # mutable for closure


def probe_callback(pad, info, _user_data):
    """Post-tracker probe: extract metadata and enqueue for Phoenix stats."""
    frame_count[0] += 1
    if frame_count[0] % 100 == 1:
        logger.info("Probe: frame %d", frame_count[0])

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

        cam_id = frame_meta.source_id
        pts = frame_meta.buf_pts

        now = time.monotonic()
        if now - last_push_time[cam_id] < PUSH_INTERVAL:
            try:
                l_frame = l_frame.next
            except StopIteration:
                break
            continue

        objects = []
        l_obj = frame_meta.obj_meta_list
        while l_obj is not None:
            try:
                obj_meta = pyds.NvDsObjectMeta.cast(l_obj.data)
            except StopIteration:
                break

            rect = obj_meta.rect_params
            bbox = {
                "left": round(rect.left, 1),
                "top": round(rect.top, 1),
                "width": round(rect.width, 1),
                "height": round(rect.height, 1),
            }
            obj_data = {
                "track_id": obj_meta.object_id,
                "class_id": obj_meta.class_id,
                "label": obj_meta.obj_label,
                "confidence": round(obj_meta.confidence, 4),
                "bbox": bbox,
            }

            thumb = crop_thumbnail(bbox, cam_id=cam_id)
            if thumb:
                obj_data["thumbnail"] = thumb

            objects.append(obj_data)

            try:
                l_obj = l_obj.next
            except StopIteration:
                break

        if objects:
            last_push_time[cam_id] = now
            batch = {
                "cam_id": cam_id,
                "ts": time.time(),
                "pts": pts,
                "resolution": {"w": MUXER_WIDTH, "h": MUXER_HEIGHT},
                "objects": objects,
            }
            try:
                detection_queue.put_nowait(batch)
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
def create_pipeline():
    Gst.init(None)
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
        padname = "sink_{0}".format(i)
        sinkpad = streammux.get_request_pad(padname)

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
            struct = caps.get_structure(0)
            name = struct.get_name()
            logger.info("pad-added: %s caps=%s", pad.get_name(), name)
            if name.startswith("video"):
                conv_sink = conv.get_static_pad("sink")
                if not conv_sink.is_linked():
                    ret = pad.link(conv_sink)
                    logger.info("Linked video pad to nvvideoconvert: %s", ret)

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
    tracker.set_property("enable-batch-process", 1)
    tracker.set_property("enable-past-frame", 1)
    tracker.set_property("display-tracking-id", 1)
    pipeline.add(tracker)

    # --- nvstreamdemux: split batched stream into per-camera streams ---
    demux = Gst.ElementFactory.make("nvstreamdemux", "demux")
    pipeline.add(demux)

    # --- Link core: streammux → pgie → tracker → demux ---
    streammux.link(pgie)
    pgie.link(tracker)
    tracker.link(demux)

    # --- Probe on tracker src pad for metadata extraction (before demux) ---
    tracker_src_pad = tracker.get_static_pad("src")
    tracker_src_pad.add_probe(Gst.PadProbeType.BUFFER, probe_callback, None)

    # --- Per-camera branches from demux ---
    for i in range(num_sources):
        cam_name = "cam{0}".format(i + 1)
        rtsp_url = "{0}/{1}".format(MEDIAMTX_RTSP_URL, cam_name)
        logger.info("Setting up per-camera branch %d → %s", i, rtsp_url)

        # OSD: draws bboxes on per-camera GPU frames
        osd = Gst.ElementFactory.make("nvdsosd", "osd-{0}".format(i))
        osd.set_property("process-mode", 0)
        osd.set_property("display-text", 1)
        osd.set_property("display-bbox", 1)
        osd.set_property("display-mask", 0)
        pipeline.add(osd)

        # Queue between demux and osd
        q_demux = Gst.ElementFactory.make("queue", "queue-demux-{0}".format(i))
        pipeline.add(q_demux)

        # Tee: split into render + thumbnail branches
        tee = Gst.ElementFactory.make("tee", "tee-{0}".format(i))
        pipeline.add(tee)

        # --- Render branch: encode → rtspclientsink → MediaMTX ---
        queue_render = Gst.ElementFactory.make("queue", "queue-render-{0}".format(i))
        pipeline.add(queue_render)

        conv = Gst.ElementFactory.make("nvvideoconvert", "conv-{0}".format(i))
        conv.set_property("gpu-id", GPU_ID)
        pipeline.add(conv)

        capsf = Gst.ElementFactory.make("capsfilter", "caps-{0}".format(i))
        capsf.set_property(
            "caps", Gst.Caps.from_string("video/x-raw(memory:NVMM), format=I420")
        )
        pipeline.add(capsf)

        enc = Gst.ElementFactory.make("nvv4l2h264enc", "enc-{0}".format(i))
        enc.set_property("bitrate", RTSP_BITRATE)
        enc.set_property("iframeinterval", 15)
        pipeline.add(enc)

        parse = Gst.ElementFactory.make("h264parse", "parse-{0}".format(i))
        pipeline.add(parse)

        rtsp_sink = Gst.ElementFactory.make("rtspclientsink", "rtsp-sink-{0}".format(i))
        rtsp_sink.set_property("location", rtsp_url)
        rtsp_sink.set_property("protocols", 4)  # TCP
        pipeline.add(rtsp_sink)

        # --- Thumbnail branch: appsink for per-camera detection crops ---
        queue_thumb = Gst.ElementFactory.make("queue", "queue-thumb-{0}".format(i))
        queue_thumb.set_property("max-size-buffers", 1)
        queue_thumb.set_property("leaky", 2)
        pipeline.add(queue_thumb)

        thumb_conv = Gst.ElementFactory.make("nvvideoconvert", "thumb-conv-{0}".format(i))
        thumb_conv.set_property("gpu-id", GPU_ID)
        pipeline.add(thumb_conv)

        thumb_caps = Gst.ElementFactory.make("capsfilter", "thumb-caps-{0}".format(i))
        thumb_caps.set_property(
            "caps", Gst.Caps.from_string("video/x-raw, format=RGBA")
        )
        pipeline.add(thumb_caps)

        appsink = Gst.ElementFactory.make("appsink", "thumb-sink-{0}".format(i))
        appsink.set_property("emit-signals", True)
        appsink.set_property("drop", True)
        appsink.set_property("max-buffers", 1)
        appsink.connect("new-sample", _make_appsink_callback(i))
        pipeline.add(appsink)

        # --- Link demux src_i → queue → osd → tee ---
        demux_src = demux.get_request_pad("src_{0}".format(i))
        q_demux_sink = q_demux.get_static_pad("sink")
        demux_src.link(q_demux_sink)

        q_demux.link(osd)
        osd.link(tee)

        # --- Link tee → render branch ---
        tee.link(queue_render)
        queue_render.link(conv)
        conv.link(capsf)
        capsf.link(enc)
        enc.link(parse)
        parse.link(rtsp_sink)

        # --- Link tee → thumbnail branch ---
        tee.link(queue_thumb)
        queue_thumb.link(thumb_conv)
        thumb_conv.link(thumb_caps)
        thumb_caps.link(appsink)

    return pipeline


# ---------------------------------------------------------------------------
# Async detection pusher (for stats only, not bbox rendering)
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
        pipeline = create_pipeline()
        loop = GLib.MainLoop()

        bus = pipeline.get_bus()
        bus.add_signal_watch()

        def on_message(_, msg):
            t = msg.type
            if t == Gst.MessageType.EOS:
                logger.info("End of stream")
                loop.quit()
            elif t == Gst.MessageType.ERROR:
                err, debug = msg.parse_error()
                logger.error("GStreamer error: %s\n%s", err, debug)
                loop.quit()
            elif t == Gst.MessageType.WARNING:
                err, debug = msg.parse_warning()
                logger.warning("GStreamer warning: %s\n%s", err, debug)

        bus.connect("message", on_message)

        # Set pipeline latency high enough for live RTSP sources + encoding
        pipeline.set_latency(3 * Gst.SECOND)

        pipeline.set_state(Gst.State.PLAYING)
        logger.info("Pipeline PLAYING — per-camera RTSP via rtspclientsink")

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

        logger.info("Restarting pipeline for file loop...")
        time.sleep(1)


async def async_main():
    phoenix = PhoenixChannelClient(
        phoenix_url=PHOENIX_URL,
        token=PHOENIX_TOKEN,
    )
    gst_thread = threading.Thread(target=run_gstreamer_loop, daemon=True)
    gst_thread.start()
    await phoenix_connection_loop(phoenix)


def main():
    loop = asyncio.get_event_loop()
    try:
        loop.run_until_complete(async_main())
    finally:
        loop.close()


if __name__ == "__main__":
    main()
