#!/usr/bin/env python3
"""Local Screen Sharing relay that requires an Apple virtual user session."""
import asyncio

LOOPBACK = "127.0.0.1"
LISTEN_PORT = 5903
SCREEN_SHARING_PORT = 5900
RFB_VERSION = b"RFB 003.889\n"


class UnsupportedHandshake(Exception):
    pass


def require(condition, stage):
    if not condition:
        raise UnsupportedHandshake(stage)


def unsigned(data):
    return int.from_bytes(data, "big")


async def send(writer, data):
    writer.write(data)
    await writer.drain()


async def read_record(reader, prefix, minimum, stage):
    header = await reader.readexactly(prefix)
    length = unsigned(header)
    require(minimum <= length <= 16384, stage)
    return header + await reader.readexactly(length)


async def negotiate(client, client_writer, screen, screen_writer, banner):
    require(banner == RFB_VERSION, "server protocol")
    await send(client_writer, banner)
    require(await client.readexactly(12) == RFB_VERSION, "viewer protocol")
    await send(screen_writer, RFB_VERSION)

    count = await screen.readexactly(1)
    methods = await screen.readexactly(count[0])
    # Only the observed native RSA/SRP authentication path is supported.
    require(33 in methods, "server authentication methods")
    await send(client_writer, count + methods)
    method = await client.readexactly(1)
    require(method == b"\x21", f"viewer authentication method {method[0]}")
    print("Native authentication started", flush=True)

    packet = await read_record(client, 4, 10, "RSA identity envelope")
    require(packet[6:10] == b"RSA1", "RSA identity envelope")
    first_selector = method
    if unsigned(packet[10:12]) == 0:
        await send(screen_writer, first_selector + packet)
        first_selector = b""
        await send(client_writer, await read_record(screen, 4, 6, "RSA public key"))
        packet = await read_record(client, 4, 10, "RSA identity envelope")
    require(packet[6:12] == b"RSA1\x00\x02", "RSA identity envelope")
    await send(screen_writer, first_selector + packet)
    await send(client_writer, await read_record(screen, 4, 9, "SRP challenge"))
    packet = await read_record(client, 4, 10, "SRP proof envelope")
    require(packet[6:12] == b"RSA1\x00\x02", "SRP proof envelope")
    await send(screen_writer, packet)
    await send(client_writer, await read_record(screen, 4, 9, "SRP proof"))
    result = await screen.readexactly(4)
    await send(client_writer, result)
    require(result == bytes(4), "authentication result")
    print("Native authentication accepted", flush=True)

    require(await client.readexactly(1) == b"\xc1", "virtual session initialization")
    await send(screen_writer, b"\xc1")
    header = await screen.readexactly(24)
    length = unsigned(header[20:24])
    require(22 <= length <= 4096, "server initialization")
    name = await screen.readexactly(length)
    flags = unsigned(name[2:6])
    require(name[0] == 0 and flags & 4 and not flags & 8, "session selection required")
    offer = await read_record(screen, 2, 10, "session offer")
    require(offer[2:4] == b"\x00\x01" and unsigned(offer[4:8]) & 4, "virtual session offered")
    await send(client_writer, header + name + offer)

    choice = bytearray(await client.readexactly(74))
    require(choice[:4] == b"\x00\x48\x00\x01", "session choice")
    # The established Agent Desktop client requests command 2 here.
    # Pass no console request upstream, regardless of the viewer default.
    print("Requesting a virtual session", flush=True)
    choice[8:10] = b"\x02\x00"
    await send(screen_writer, choice)
    for _ in range(32):
        reply = await read_record(screen, 2, 6, "session grant")
        require(reply[2:4] == b"\x00\x01", "session grant")
        status = unsigned(reply[4:8])
        require(status in (0, 2, 3, 4), "virtual session denied")
        await send(client_writer, reply)
        if status in (0, 4):
            print("Verified virtual session grant", flush=True)
            return
    raise UnsupportedHandshake("virtual session did not become ready")


async def copy_stream(reader, writer):
    while data := await reader.read(65536):
        await send(writer, data)
    writer.write_eof()


async def forward(client, client_writer):
    screen_writer = None
    try:
        print("Waiting for Screen Sharing service", flush=True)
        for attempt in range(4):
            screen, screen_writer = await asyncio.wait_for(
                asyncio.open_connection(LOOPBACK, SCREEN_SHARING_PORT), timeout=3
            )
            try:
                banner = await asyncio.wait_for(screen.readexactly(12), timeout=2)
                break
            except TimeoutError:
                screen_writer.close()
                if attempt == 3:
                    raise
        await asyncio.wait_for(negotiate(client, client_writer, screen, screen_writer, banner), timeout=90)
        async with asyncio.TaskGroup() as tasks:
            request = tasks.create_task(copy_stream(client, screen_writer))
            response = tasks.create_task(copy_stream(screen, client_writer))
            _, pending = await asyncio.wait((request, response), return_when=asyncio.FIRST_COMPLETED)
            if pending:
                _, pending = await asyncio.wait(pending, timeout=5)
                for task in pending:
                    task.cancel()
    except* UnsupportedHandshake as errors:
        for error in errors.exceptions:
            print(f"Closed at {error}", flush=True)
    except* TimeoutError:
        print("Screen Sharing negotiation timed out", flush=True)
    except* (OSError, asyncio.IncompleteReadError):
        pass
    finally:
        client_writer.close()
        if screen_writer is not None:
            screen_writer.close()


async def main():
    server = await asyncio.start_server(forward, LOOPBACK, LISTEN_PORT)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    asyncio.run(main())
