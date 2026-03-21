#!/usr/bin/env python3
"""Minimal DS 6.4 pipeline to isolate segfault.

Test 1: sources → mux → nvinfer → tracker → fakesink  (no demux)
Test 2: sources → mux → nvinfer → tracker → demux → fakesinks
Test 3: sources → mux → nvinfer → tracker → demux → osd → fakesinks
Test 4: sources → mux → nvinfer → tracker → demux → osd → enc → fakesinks
"""
import sys
import os
import time
import gi
gi.require_version("Gst", "1.0")
from gi.repository import Gst, GLib

Gst.init(None)

CONFIG_DIR = os.environ.get(
    "DS_CONFIG_DIR",
    "/opt/nvidia/deepstream/deepstream-6.4/samples/configs/deepstream-app-fish",
)
INFER_CONFIG = os.path.join(CONFIG_DIR, "config_infer_primary_cfd_yolov12_ds64.txt")
TRACKER_CONFIG = os.path.join(CONFIG_DIR, "config_tracker_IOU.yml")
TRACKER_LIB = "/opt/nvidia/deepstream/deepstream-6.4/lib/libnvds_nvmultiobjecttracker.so"

SOURCE_URIS = os.environ.get("SOURCE_URIS", "").split(",")
SOURCE_URIS = [u.strip() for u in SOURCE_URIS if u.strip()]
TEST_LEVEL = int(sys.argv[1]) if len(sys.argv) > 1 else 1

print(f"=== Test level {TEST_LEVEL}, {len(SOURCE_URIS)} sources ===")


def make_pipeline():
    pipeline = Gst.Pipeline()
    num = len(SOURCE_URIS)

    # Streammux
    mux = Gst.ElementFactory.make("nvstreammux", "mux")
    mux.set_property("width", 1920)
    mux.set_property("height", 1080)
    mux.set_property("batch-size", num)
    mux.set_property("batched-push-timeout", 4000)
    mux.set_property("live-source", 1)
    mux.set_property("gpu-id", 0)
    mux.set_property("nvbuf-memory-type", 3)
    pipeline.add(mux)

    # Sources
    for i, uri in enumerate(SOURCE_URIS):
        src = Gst.ElementFactory.make("uridecodebin", f"src-{i}")
        src.set_property("uri", uri)
        pipeline.add(src)

        cpu_conv = Gst.ElementFactory.make("videoconvert", f"cpu-conv-{i}")
        pipeline.add(cpu_conv)
        gpu_conv = Gst.ElementFactory.make("nvvideoconvert", f"gpu-conv-{i}")
        gpu_conv.set_property("gpu-id", 0)
        gpu_conv.set_property("nvbuf-memory-type", 3)
        pipeline.add(gpu_conv)
        cpu_conv.link(gpu_conv)

        sinkpad = mux.get_request_pad(f"sink_{i}")
        gpu_conv.get_static_pad("src").link(sinkpad)

        def on_pad(decodebin, pad, conv=cpu_conv):
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

        src.connect("pad-added", on_pad)

    # nvinfer
    pgie = Gst.ElementFactory.make("nvinfer", "pgie")
    pgie.set_property("config-file-path", INFER_CONFIG)
    pgie.set_property("batch-size", num)
    pgie.set_property("interval", 3)
    pgie.set_property("gpu-id", 0)
    pipeline.add(pgie)

    # tracker
    tracker = Gst.ElementFactory.make("nvtracker", "tracker")
    tracker.set_property("tracker-width", 640)
    tracker.set_property("tracker-height", 384)
    tracker.set_property("ll-lib-file", TRACKER_LIB)
    tracker.set_property("ll-config-file", TRACKER_CONFIG)
    tracker.set_property("gpu-id", 0)
    tracker.set_property("display-tracking-id", 1)
    pipeline.add(tracker)

    mux.link(pgie)
    pgie.link(tracker)

    if TEST_LEVEL == 1:
        # Just fakesink after tracker
        sink = Gst.ElementFactory.make("fakesink", "sink")
        pipeline.add(sink)
        tracker.link(sink)
        print("Pipeline: mux → pgie → tracker → fakesink")

    elif TEST_LEVEL >= 2:
        demux = Gst.ElementFactory.make("nvstreamdemux", "demux")
        pipeline.add(demux)
        tracker.link(demux)

        for i in range(num):
            q = Gst.ElementFactory.make("queue", f"q-{i}")
            pipeline.add(q)

            demux_src = demux.get_request_pad(f"src_{i}")
            demux_src.link(q.get_static_pad("sink"))

            if TEST_LEVEL == 2:
                sink = Gst.ElementFactory.make("fakesink", f"sink-{i}")
                pipeline.add(sink)
                q.link(sink)
            elif TEST_LEVEL == 3:
                osd = Gst.ElementFactory.make("nvdsosd", f"osd-{i}")
                pipeline.add(osd)
                sink = Gst.ElementFactory.make("fakesink", f"sink-{i}")
                pipeline.add(sink)
                q.link(osd)
                osd.link(sink)
            elif TEST_LEVEL == 4:
                osd = Gst.ElementFactory.make("nvdsosd", f"osd-{i}")
                pipeline.add(osd)
                conv = Gst.ElementFactory.make("nvvideoconvert", f"conv-{i}")
                pipeline.add(conv)
                capsf = Gst.ElementFactory.make("capsfilter", f"caps-{i}")
                capsf.set_property("caps", Gst.Caps.from_string("video/x-raw(memory:NVMM), format=I420"))
                pipeline.add(capsf)
                enc = Gst.ElementFactory.make("nvv4l2h264enc", f"enc-{i}")
                enc.set_property("bitrate", 4000000)
                pipeline.add(enc)
                sink = Gst.ElementFactory.make("fakesink", f"sink-{i}")
                pipeline.add(sink)
                q.link(osd)
                osd.link(conv)
                conv.link(capsf)
                capsf.link(enc)
                enc.link(sink)

        print(f"Pipeline: mux → pgie → tracker → demux → (level {TEST_LEVEL}) × {num}")

    return pipeline


pipeline = make_pipeline()
loop = GLib.MainLoop()


def on_msg(_, msg):
    t = msg.type
    if t == Gst.MessageType.EOS:
        src = msg.src.get_name() if msg.src else "?"
        print(f"EOS from {src}")
        loop.quit()
    elif t == Gst.MessageType.ERROR:
        err, dbg = msg.parse_error()
        src = msg.src.get_name() if msg.src else "?"
        print(f"ERROR from {src}: {err}\n{dbg}")
        loop.quit()
    elif t == Gst.MessageType.STATE_CHANGED:
        if msg.src == pipeline:
            old, new, pend = msg.parse_state_changed()
            print(f"Pipeline: {old.value_nick} → {new.value_nick} (pending: {pend.value_nick})")
    elif t == Gst.MessageType.WARNING:
        err, dbg = msg.parse_warning()
        src = msg.src.get_name() if msg.src else "?"
        print(f"WARN from {src}: {err}")


bus = pipeline.get_bus()
bus.add_signal_watch()
bus.connect("message", on_msg)

print("Setting pipeline to PLAYING...")
pipeline.set_state(Gst.State.PLAYING)
print("set_state returned, running main loop...")

try:
    loop.run()
except KeyboardInterrupt:
    pass

pipeline.set_state(Gst.State.NULL)
print("Done.")
