"""Stand-in for openai-whisper: answers with what it was given, so the
worker's protocol and options can be checked without the 2 GB model."""
import json
import os


class _Model:
    def __init__(self, name):
        self.name = name

    def transcribe(self, path, **options):
        if not os.path.exists(path):
            raise FileNotFoundError(path)
        given = {"model": self.name, "clip": os.path.basename(path), "options": options}
        return {"text": "  " + json.dumps(given, sort_keys=True) + "  ", "language": "en"}


def load_model(name):
    if name == "broken":
        raise RuntimeError("no such model")
    return _Model(name)
