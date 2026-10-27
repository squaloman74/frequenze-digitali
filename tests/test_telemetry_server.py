import asyncio
import json
import socket
import unittest

from websockets.asyncio.client import connect

from backend.server import TelemetryServer


class TelemetryControlTests(unittest.IsolatedAsyncioTestCase):
    async def test_client_can_request_calibration_over_websocket(self):
        received = asyncio.Event()

        async def on_message(message):
            request = json.loads(message)
            self.assertEqual(request, {"type": "calibrate"})
            received.set()

        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            port = probe.getsockname()[1]

        server = TelemetryServer(port=port, on_message=on_message)
        await server.start()
        try:
            async with connect(f"ws://127.0.0.1:{port}") as client:
                await client.send(json.dumps({"type": "calibrate"}))
                await asyncio.wait_for(received.wait(), timeout=2)
        finally:
            await server.close()

    async def test_invalid_control_message_is_ignored_and_connection_stays_open(self):
        received = asyncio.Event()

        async def on_message(message):
            request = json.loads(message)
            if request.get("type") != "calibrate":
                raise ValueError("unsupported message")
            received.set()

        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            port = probe.getsockname()[1]

        server = TelemetryServer(port=port, on_message=on_message)
        await server.start()
        try:
            async with connect(f"ws://127.0.0.1:{port}") as client:
                await client.send("{")
                await client.send(json.dumps({"type": "calibrate"}))
                await asyncio.wait_for(received.wait(), timeout=2)
        finally:
            await server.close()


if __name__ == "__main__":
    unittest.main()
