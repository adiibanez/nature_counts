"""
Phoenix Channel WebSocket client for pushing DeepStream detections.

Implements the Phoenix Channel wire protocol (v2 JSON serializer) over
a plain WebSocket connection. Joins the "ingestion:lobby" topic and pushes
"detection_batch" events.
"""

import asyncio
import json
import logging

import websockets

logger = logging.getLogger("phoenix_channel_client")


class PhoenixChannelClient:
    HEARTBEAT_INTERVAL = 30

    def __init__(self, phoenix_url="ws://phoenix:4005/deepstream/websocket", token=""):
        self.url = phoenix_url
        self.token = token
        self.ws = None
        self.ref = 0
        self._joined = False
        self._heartbeat_task = None
        self._push_count = 0

    async def connect(self):
        if self.ws:
            try:
                await self.ws.close()
            except Exception:
                pass

        url = "{0}?token={1}&vsn=2.0.0".format(self.url, self.token)
        logger.info("Connecting to %s", url)
        self.ws = await websockets.connect(url, ping_interval=20, ping_timeout=10)
        self._joined = False
        self.ref = 0
        self._push_count = 0

        # Join the ingestion channel
        await self._send("phx_join", "ingestion:lobby", {})

        # Wait for join reply
        reply = await asyncio.wait_for(self.ws.recv(), timeout=5.0)
        msg = json.loads(reply)
        logger.info("Join reply: %s", msg)

        if isinstance(msg, list) and len(msg) >= 5:
            if msg[3] == "phx_reply" and msg[4].get("status") == "ok":
                self._joined = True
                logger.info("Successfully joined ingestion:lobby")
            else:
                raise ConnectionError("Join failed: {0}".format(msg))
        else:
            raise ConnectionError("Unexpected join response: {0}".format(msg))

        if self._heartbeat_task:
            self._heartbeat_task.cancel()
        self._heartbeat_task = asyncio.ensure_future(self._heartbeat_loop())

    async def push_detections(self, cam_id, payload):
        if not self._joined or not self.ws:
            raise ConnectionError("Not connected to Phoenix")
        await self._send("detection_batch", "ingestion:lobby", payload)
        self._push_count += 1
        if self._push_count % 50 == 1:
            n_obj = len(payload.get("objects", []))
            logger.info("Pushed detection batch #%d (cam %s, %d objects)",
                        self._push_count, cam_id, n_obj)

    async def _send(self, event, topic, payload):
        self.ref += 1
        join_ref = "1" if topic == "ingestion:lobby" else None
        msg = json.dumps([join_ref, str(self.ref), topic, event, payload])
        await self.ws.send(msg)

    async def _heartbeat_loop(self):
        try:
            while True:
                await asyncio.sleep(self.HEARTBEAT_INTERVAL)
                if self.ws:
                    self.ref += 1
                    msg = json.dumps([None, str(self.ref), "phoenix", "heartbeat", {}])
                    await self.ws.send(msg)
                    logger.debug("Heartbeat sent")
        except asyncio.CancelledError:
            pass
        except Exception as e:
            logger.warning("Heartbeat failed: %s", e)

    async def close(self):
        if self._heartbeat_task:
            self._heartbeat_task.cancel()
        if self.ws:
            await self.ws.close()
