#!/bin/sh
# Dictation tests that need neither a microphone nor the Whisper model:
# the hold logic and controller with fakes, and the worker's protocol against
# a stand-in whisper module. From the repository root:
#   Support/Dictation/tests/run.sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
src="$here/../../../Sources/Marina/Dictation"
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

echo "== hold logic and controller"
# top-level code is only allowed in a file called main.swift
cp "$here/ControllerTests.swift" "$out/main.swift"
swiftc -o "$out/controller" "$src/HoldToTalk.swift" "$src/DictationController.swift" "$out/main.swift"
"$out/controller" "$out"

echo "== worker protocol (stand-in whisper)"
: > "$out/clip.wav"
reply=$(printf '%s\n' \
    "{\"path\": \"$out/clip.wav\", \"prompt\": \"tmux-ops, Marina\", \"language\": \"\"}" \
    "{\"path\": \"$out/clip.wav\", \"language\": \"de\"}" \
    "{\"path\": \"$out/missing.wav\"}" \
    | PYTHONPATH="$here/fake_whisper" python3 "$here/../dictate_worker.py" small)
echo "$reply"
expect() { echo "$reply" | grep -q -- "$1" && echo "ok   $2" || { echo "FAIL $2"; exit 1; }; }
expect '"ready": true, "model": "small"' "ready line first"
expect 'condition_on_previous_text\\": false, \\"fp16\\": false, \\"initial_prompt\\": \\"tmux-ops, Marina' "options and prompt"
expect '\\"language\\": \\"de\\"' "a language when given"
expect '"error": "FileNotFoundError' "a missing clip is an error line, and the worker goes on"
[ -f "$out/clip.wav" ] && echo "ok   the worker leaves the clip to Marina"
broken=$(echo '{}' | PYTHONPATH="$here/fake_whisper" python3 "$here/../dictate_worker.py" broken || true)
echo "$broken" | grep -q '"error": "RuntimeError: no such model"' && echo "ok   a model that will not load says so"
