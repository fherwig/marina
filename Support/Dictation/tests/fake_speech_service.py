"""A stand-in for the session dashboard's speech service (docs/SPEECH.md, protocol 1).
usage: fake_speech_service.py <dir> <mode>   mode: normal | drop | loading | fatal
Writes <dir>/speech.json and <dir>/log.jsonl (every line received)."""
import asyncio, json, os, sys
d, mode = sys.argv[1], sys.argv[2]
sock = os.path.join(d, "s.sock")
clients = []
def log(obj):
    with open(os.path.join(d, "log.jsonl"), "a") as f: f.write(json.dumps(obj) + "\n")
async def serve(reader, writer):
    def say(obj):
        writer.write((json.dumps(obj) + "\n").encode())
    base = {"model": "mlx-community/whisper-small-mlx", "engine": "mlx", "protocol": 1}
    if mode == "fatal":
        say({"error": "no module named mlx_whisper", "fatal": True, **base}); await writer.drain(); writer.close(); return
    if mode == "loading":
        say({"loading": True, **base})
    else:
        say({"ready": True, "load": 0.4, **base})
    await writer.drain()
    while True:
        line = await reader.readline()
        if not line: break
        obj = json.loads(line); log(obj)
        if "client" in obj: clients.append(obj["client"])
        elif obj.get("status"):
            say({"id": obj["id"], "model": base["model"], "engine": "mlx", "phase": "ready",
                 "loaded": mode != "loading", "queue": 0, "served": 1,
                 "clients": clients + ["session-dashboard"], "protocol": 1})
        elif "path" in obj:
            if mode == "drop":
                writer.close(); return
            size = os.path.getsize(obj["path"])
            say({"id": obj["id"], "text": f"From the shared service, a clip of {size} bytes.", "lang": "en", "secs": 0.2})
        await writer.drain()
async def main():
    if os.path.exists(sock): os.remove(sock)
    server = await asyncio.start_unix_server(serve, path=sock)
    json.dump({"socket": sock, "protocol": 1, "by": "fake", "model": "whisper-small-mlx", "engine": "mlx", "pid": os.getpid()},
              open(os.path.join(d, "speech.json"), "w"))
    async with server: await server.serve_forever()
asyncio.run(main())
