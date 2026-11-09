#!/usr/bin/env python3
"""Exercise the native relay without a real account or graphical session."""
import asyncio
import importlib.util
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "relay", Path(__file__).with_name("screen-sharing-relay.py")
)
relay = importlib.util.module_from_spec(spec)
spec.loader.exec_module(relay)


def record(payload, prefix=4):
    return len(payload).to_bytes(prefix, "big") + payload


METHODS = b"\x04\x1e\x21\x24\x23"
IDENTITY = record(b"\x01\x00RSA1\x00\x02\x00\x00")
PROOF = record(bytes(9))
OFFER = record(b"\x00\x01" + bytes.fromhex("00000004") + bytes(4), 2)
CONSOLE_CHOICE = record(b"\x00\x01" + bytes(70), 2)


async def exercise(offer_virtual, grant_virtual):
    upstream_done = asyncio.get_running_loop().create_future()
    name = b"\0\0" + bytes.fromhex("00000004" if offer_virtual else "00000000") + bytes(16)
    init = bytes(20) + record(name)
    grant = record(b"\x00\x01" + (0 if grant_virtual else 1).to_bytes(4, "big"), 2)

    async def upstream(reader, writer):
        try:
            await relay.send(writer, relay.RFB_VERSION)
            assert await reader.readexactly(12) == relay.RFB_VERSION
            await relay.send(writer, METHODS)
            assert await reader.readexactly(1 + len(IDENTITY)) == b"\x21" + IDENTITY
            await relay.send(writer, PROOF)
            assert await reader.readexactly(len(IDENTITY)) == IDENTITY
            await relay.send(writer, PROOF + bytes(4))
            assert await reader.readexactly(1) == b"\xc1"
            await relay.send(writer, init + OFFER)
            if offer_virtual:
                command = await reader.readexactly(74)
                assert command == CONSOLE_CHOICE[:8] + b"\x02\0" + CONSOLE_CHOICE[10:]
                await relay.send(writer, grant + b"screen data")
            else:
                assert await reader.read() == b""
            upstream_done.set_result(None)
        except Exception as error:
            upstream_done.set_exception(error)
        finally:
            writer.close()

    source = await asyncio.start_server(upstream, relay.LOOPBACK, 0)
    relay.SCREEN_SHARING_PORT = source.sockets[0].getsockname()[1]
    server = await asyncio.start_server(relay.forward, relay.LOOPBACK, 0)
    async with source, server:
        reader, writer = await asyncio.open_connection(relay.LOOPBACK, server.sockets[0].getsockname()[1])
        try:
            assert await reader.readexactly(12) == relay.RFB_VERSION
            await relay.send(writer, relay.RFB_VERSION)
            assert await reader.readexactly(len(METHODS)) == METHODS
            # A split viewer write still arrives upstream as selector + envelope.
            await relay.send(writer, b"\x21")
            await relay.send(writer, IDENTITY)
            assert await reader.readexactly(len(PROOF)) == PROOF
            await relay.send(writer, IDENTITY)
            assert await reader.readexactly(len(PROOF) + 4) == PROOF + bytes(4)
            await relay.send(writer, b"\xc1")
            if offer_virtual:
                assert await reader.readexactly(len(init) + len(OFFER)) == init + OFFER
                await relay.send(writer, CONSOLE_CHOICE)
            expected = grant + b"screen data" if offer_virtual and grant_virtual else b""
            assert await reader.read() == expected
            await upstream_done
        finally:
            writer.close()
            await writer.wait_closed()


async def main():
    for offer, grant in [(True, True), (True, False), (False, False)]:
        await asyncio.wait_for(exercise(offer, grant), timeout=5)
    print("PASS: native relay requires a virtual-session offer and grant")


if __name__ == "__main__":
    asyncio.run(main())
