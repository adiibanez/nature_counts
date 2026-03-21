#!/usr/bin/env python3
"""Test the full DS 6.4 pipeline structure without pyds/phoenix/probe."""
import os
import sys
import gi
gi.require_version("Gst", "1.0")
gi.require_version("GstRtspServer", "1.0")
from gi.repository import Gst, GLib, GstRtspServer

Gst.init(None)

CONFIG_DIR = os.environ.get(
    "DS_CONFIG_DIR",
    "/opt/nvidia/deepstream/deepstream-6.4/samples/configs/deepstream-app-fish",
)
INFER_CONFIG = os.path.join(CONFIG_DIR, "config_infer_primary_cfd_yolov12_ds64.txt")
TRACKER_CONFIG = os.path.join(CONFIG_DIR, "config_tracker_IOU.yml")
TRACKER_LIB = "/opt/nvidia/deepstream/deepstream-6.4/lib/libnvds_nvmultiobjecttracker.so"
SOURCE_URIS = [u.strip() for u in os.environ.get("SOURCE_URIS", "").split(",") if u.strip()]
GPU_ID = 0

print(f"Sources: {SOURCE_URIS}")

pipeline = Gst.Pipeline()
num = len(SOURCE_URIS)

# Streammux
mux = Gst.ElementFactory.make("nvstreammux", "mux")
mux.set_property("width", 1920)
mux.set_property("height", 1080)
mux.set_property("batch-size", num)
mux.set_property("batched-push-timeout", 4000)
mux.set_property("live-source", 1)
mux.set_property("gpu-id", GPU_ID)
mux.set_property("enable-padding", True)
mux.set_property("nvbuf-memory-type", 3)
pipeline.add(mux)

# Sources — same pad-added handler as ds_fish_pipeline.py
for i, uri in enumerate(SOURCE_URIS):
    padname = f"sink_{i}"
    sinkpad = mux.get_request_pad(padname)

    src = Gst.ElementFactory.make("uridecodebin", f"source-{i}")
    src.set_property("uri", uri)

    cpu_conv = Gst.ElementFactory.make("videoconvert", f"cpu-conv-{i}")
    pipeline.add(cpu_conv)

    gpu_conv = Gst.ElementFactory.make("nvvideoconvert", f"gpu-conv-{i}")
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
        print(f"  pad-added: {name}")
        if name.startswith("video"):
            sink = conv.get_static_pad("sink")
            if not sink.is_linked():
                pad.link(sink)
                print(f"  Linked video pad")

    src.connect("pad-added", pad_added_handler)
    pipeline.add(src)

# nvinfer
pgie = Gst.ElementFactory.make("nvinfer", "pgie")
pgie.set_property("config-file-path", INFER_CONFIG)
pgie.set_property("batch-size", num)
pgie.set_property("interval", 3)
pgie.set_property("gpu-id", GPU_ID)
pgie.set_property("unique-id", 1)
pipeline.add(pgie)

# tracker
tracker = Gst.ElementFactory.make("nvtracker", "tracker")
tracker.set_property("tracker-width", 640)
tracker.set_property("tracker-height", 384)
tracker.set_property("ll-lib-file", TRACKER_LIB)
tracker.set_property("ll-config-file", TRACKER_CONFIG)
tracker.set_property("gpu-id", GPU_ID)
tracker.set_property("display-tracking-id", 1)
pipeline.add(tracker)

# demux
demux = Gst.ElementFactory.make("nvstreamdemux", "demux")
pipeline.add(demux)

mux.link(pgie)
pgie.link(tracker)
tracker.link(demux)

# Per-camera branches: demux → queue → osd → nvvideoconvert → capsfilter → enc → h264parse → fakesink
for i in range(num):
    q = Gst.ElementFactory.make("queue", f"q-{i}")
    pipeline.add(q)

    osd = Gst.ElementFactory.make("nvdsosd", f"osd-{i}")
    osd.set_property("process-mode", 0)
    osd.set_property("display-text", 1)
    osd.set_property("display-bbox", 1)
    osd.set_property("display-mask", 0)
    pipeline.add(osd)

    conv = Gst.ElementFactory.make("nvvideoconvert", f"conv-{i}")
    conv.set_property("gpu-id", GPU_ID)
    pipeline.add(conv)

    capsf = Gst.ElementFactory.make("capsfilter", f"caps-{i}")
    capsf.set_property("caps", Gst.Caps.from_string("video/x-raw(memory:NVMM), format=I420"))
    pipeline.add(capsf)

    enc = Gst.ElementFactory.make("nvv4l2h264enc", f"enc-{i}")
    enc.set_property("bitrate", 4000000)
    enc.set_property("iframeinterval", 15)
    pipeline.add(enc)

    parse = Gst.ElementFactory.make("h264parse", f"parse-{i}")
    pipeline.add(parse)

    sink = Gst.ElementFactory.make("fakesink", f"sink-{i}")
    sink.set_property("sync", False)
    sink.set_property("async", False)
    pipeline.add(sink)

    demux_src = demux.get_request_pad(f"src_{i}")
    demux_src.link(q.get_static_pad("sink"))
    q.link(osd)
    osd.link(conv)
    conv.link(capsf)
    capsf.link(enc)
    enc.link(parse)
    parse.link(sink)

loop = GLib.MainLoop()


def on_msg(_, msg):
    t = msg.type
    if t == Gst.MessageType.EOS:
        print(f"EOS from {msg.src.get_name()}")
        loop.quit()
    elif t == Gst.MessageType.ERROR:
        err, dbg = msg.parse_error()
        print(f"ERROR from {msg.src.get_name()}: {err}\n{dbg}")
        loop.quit()
    elif t == Gst.MessageType.STATE_CHANGED:
        if msg.src == pipeline:
            old, new, pend = msg.parse_state_changed()
            print(f"Pipeline: {old.value_nick} → {new.value_nick} (pending: {pend.value_nick})")


bus = pipeline.get_bus()
bus.add_signal_watch()
bus.connect("message", on_msg)

print("Setting pipeline to PLAYING...")
pipeline.set_state(Gst.State.PLAYING)
print("Running main loop...")

try:
    loop.run()
except KeyboardInterrupt:
    pass

pipeline.set_state(Gst.State.NULL)
print("Done.")
