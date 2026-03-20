#!/usr/bin/env python3
"""Minimal test: does nvstreamdemux output data?"""
import gi
gi.require_version("Gst", "1.0")
from gi.repository import Gst, GLib

Gst.init(None)

pipe = Gst.Pipeline()

src = Gst.ElementFactory.make("videotestsrc", "src")
src.set_property("num-buffers", 30)
pipe.add(src)

mux = Gst.ElementFactory.make("nvstreammux", "mux")
mux.set_property("width", 320)
mux.set_property("height", 240)
mux.set_property("batch-size", 1)
mux.set_property("batched-push-timeout", 4000)
pipe.add(mux)

dmx = Gst.ElementFactory.make("nvstreamdemux", "dmx")
pipe.add(dmx)

sink = Gst.ElementFactory.make("fakesink", "sink")
sink.set_property("sync", False)
pipe.add(sink)

sinkpad = mux.get_request_pad("sink_0")
src.get_static_pad("src").link(sinkpad)
mux.link(dmx)

dmx_src = dmx.get_request_pad("src_0")
sink_pad = sink.get_static_pad("sink")
ret = dmx_src.link(sink_pad)
print("dmx link: %s" % ret)

count = [0]
def probe(pad, info):
    count[0] += 1
    if count[0] == 1:
        print("Demux output: buffer #%d" % count[0])
    return Gst.PadProbeReturn.OK
dmx_src.add_probe(Gst.PadProbeType.BUFFER, probe)

pipe.set_state(Gst.State.PLAYING)

loop = GLib.MainLoop()
bus = pipe.get_bus()
bus.add_signal_watch()
def on_msg(_, msg):
    if msg.type in (Gst.MessageType.EOS, Gst.MessageType.ERROR):
        if msg.type == Gst.MessageType.ERROR:
            err, dbg = msg.parse_error()
            print("Error: %s" % err)
        loop.quit()
bus.connect("message", on_msg)

GLib.timeout_add_seconds(5, loop.quit)
loop.run()
pipe.set_state(Gst.State.NULL)
print("Total demux buffers: %d" % count[0])
