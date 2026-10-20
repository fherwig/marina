"""Marina's dictation worker: keeps one Whisper model loaded and turns audio
clips into text, one JSON line in and one JSON line out per clip.

    python dictate_worker.py <model>

    out, once:  {"ready": true, "model": "small", "load": 2.9}   or {"error": "..."}, then exit
    in:         {"path": "/…/clip.wav", "prompt": "names to expect", "language": ""}
    out:        {"text": "…", "lang": "en", "secs": 1.4}         or {"error": "..."}

Marina owns the clips and deletes them; this only reads them. It runs until
its stdin closes, which is how Marina unloads the model.

Part of Marina, GPL-3.0-or-later.
"""
import json
import sys
import time


def say(**fields):
    sys.stdout.write(json.dumps(fields) + "\n")
    sys.stdout.flush()


def main():
    model_name = sys.argv[1] if len(sys.argv) > 1 else "small"
    started = time.time()
    try:
        # numpy before whisper: some conda environments carry two copies of
        # the OpenMP library, and torch imported first aborts (OMP Error #15).
        # Importing numpy first makes both use one copy. KMP_DUPLICATE_LIB_OK
        # would let two run instead, which is not a fix.
        try:
            import numpy  # noqa: F401
        except ImportError:
            pass
        import whisper
        model = whisper.load_model(model_name)
    except Exception as error:  # noqa: BLE001 — every failure is reported
        say(error=f"{type(error).__name__}: {error}")
        return 1
    say(ready=True, model=model_name, load=round(time.time() - started, 1))

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
            started = time.time()
            options = {
                # a dictated clip stands on its own; carrying text over is
                # what makes Whisper repeat a phrase after a pause
                "condition_on_previous_text": False,
                # on the CPU fp16 only produces a warning
                "fp16": False,
            }
            if request.get("prompt"):
                options["initial_prompt"] = request["prompt"]
            if request.get("language"):
                options["language"] = request["language"]
            result = model.transcribe(request["path"], **options)
            say(text=result.get("text", "").strip(),
                lang=result.get("language", ""),
                secs=round(time.time() - started, 1))
        except Exception as error:  # noqa: BLE001
            say(error=f"{type(error).__name__}: {error}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
