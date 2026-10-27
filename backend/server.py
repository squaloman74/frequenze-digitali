import asyncio
import json
import logging
from collections.abc import Awaitable, Callable

from websockets.asyncio.server import ServerConnection, serve
from websockets.exceptions import ConnectionClosed


logger = logging.getLogger(__name__)


class TelemetryServer:
    """Broadcast the most recent telemetry frame to connected WebSocket clients."""

    def __init__(
        self,
        host="127.0.0.1",
        port=8765,
        on_message: Callable[[str], Awaitable[None]] | None = None,
    ):
        self.host = host
        self.port = port
        self.on_message = on_message
        self._server = None
        self._clients = set()

    async def start(self):
        if self._server is not None:
            return

        self._server = await serve(
            self._handle_client,
            self.host,
            self.port,
            max_queue=1,
            origins=[None, "null", "file://"],
        )
        logger.info("Telemetry WebSocket listening on ws://%s:%d", self.host, self.port)

    async def publish(self, frame):
        """Queue a frame for each client, replacing any frame not yet sent."""
        if self._server is None:
            raise RuntimeError("Telemetry server must be started before publishing")

        for queue in tuple(self._clients):
            if queue.full():
                try:
                    queue.get_nowait()
                except asyncio.QueueEmpty:
                    pass
            try:
                queue.put_nowait(frame)
            except asyncio.QueueFull:
                logger.warning("Dropping telemetry frame for a backlogged client")

    async def close(self):
        server, self._server = self._server, None
        if server is None:
            return

        server.close()
        await server.wait_closed()
        self._clients.clear()

    async def _handle_client(self, websocket: ServerConnection):
        queue = asyncio.Queue(maxsize=1)
        self._clients.add(queue)
        sender = asyncio.create_task(self._send_frames(websocket, queue))
        try:
            async for message in websocket:
                if self.on_message is None:
                    continue
                try:
                    await self.on_message(message)
                except (json.JSONDecodeError, ValueError):
                    logger.warning("Ignoring invalid telemetry control message")
        finally:
            self._clients.discard(queue)
            sender.cancel()
            await asyncio.gather(sender, return_exceptions=True)

    @staticmethod
    async def _send_frames(websocket: ServerConnection, queue: asyncio.Queue):
        try:
            while True:
                frame = await queue.get()
                await websocket.send(json.dumps(frame, separators=(",", ":")))
        except asyncio.CancelledError:
            raise
        except ConnectionClosed:
            logger.debug("Telemetry client disconnected during send", exc_info=True)
