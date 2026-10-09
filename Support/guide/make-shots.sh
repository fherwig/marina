#!/bin/sh
# Photograph Marina for docs/user-guide.md — the raw shots, before annotation.
#
#   Support/guide/make-shots.sh            (after make app)
#
# Stages the book's own example folders, ~/Documents/letters and
# ~/Documents/notes, runs an ISOLATED copy of the app (its own bundle id and
# preferences) with --guide-shots, and removes everything again. The copy
# stays in the background and off screen; it takes no keyboard and needs no
# screen-recording permission. It refuses to run if either folder already
# exists, rather than touch real files.
set -eu
cd "$(dirname "$0")/../.."
OUT="docs/images/raw"
DOCS="$HOME/Documents"
APP=/tmp/marina-guide/MarinaGuide.app

for d in "$DOCS/letters" "$DOCS/notes"; do
  if [ -e "$d" ]; then echo "refusing: $d already exists, and this script would remove it" >&2; exit 1; fi
done
cleanup() {
  rm -rf "$DOCS/letters" "$DOCS/notes" /tmp/marina-guide
  defaults delete org.fherwig.marinaguide >/dev/null 2>&1 || true
}
trap cleanup EXIT

# ── the staged world, in the book's words (M1 to M3) ────────────────────────
mkdir -p "$DOCS/letters" "$DOCS/notes/drafts" "$DOCS/notes/old" "$DOCS/notes/.claude"
cat > "$DOCS/letters/apology.md" <<'T'
Dear members of the committee,

I am sorry that the report reached you a day late.
T
cat > "$DOCS/letters/invitation.md" <<'T'
Dear members of the committee,

You are warmly invited to the open afternoon on 14 November.
T
cat > "$DOCS/letters/thank-you.md" <<'T'
Dear Katrin,

Thank you for chairing the meeting in September.
T
cat > "$DOCS/letters/CLAUDE.md" <<'T'
# Letters

Replies to the committee, one file per letter.

## Standing instructions

- Katrin spells her name **without an h**.
- Sign every letter with the committee's name.
- Keep each reply under one page.
T
cat > "$DOCS/notes/ideas.md" <<'T'
# Ideas

- A shorter agenda for the spring meeting.
T
cat > "$DOCS/notes/meeting.md" <<'T'
# Meeting notes

Decisions are recorded in the minutes.
T
cat > "$DOCS/notes/.claude/settings.local.json" <<'T'
{
  "permissions": {
    "allow": [
      "Bash(mkdir:*)"
    ]
  }
}
T
# newest first means something only if the times differ: the session has just
# fixed thank-you.md, so it is the newest file in letters
touch -t 202610050900 "$DOCS/letters/apology.md" "$DOCS/letters/invitation.md"
touch -t 202610060930 "$DOCS/letters/CLAUDE.md"
touch -t 202610071015 "$DOCS/letters/thank-you.md"
touch -t 202610040800 "$DOCS/notes/ideas.md" "$DOCS/notes/meeting.md"
touch -t 202610071100 "$DOCS/notes/drafts" "$DOCS/notes/old"

# ── a shell that shows the folder and nothing else ─────────────────────────
# zsh reads its start-up files from ZDOTDIR, which guide mode points here: no
# user name, no host, nothing from the real profile in the pictures
mkdir -p /tmp/marina-guide/zdotdir
printf "PROMPT='%%~ %%# '\nunsetopt PROMPT_SP\n" > /tmp/marina-guide/zdotdir/.zshrc
: > /tmp/marina-guide/zdotdir/.zprofile
: > /tmp/marina-guide/zdotdir/.zshenv

# ── the isolated copy ──────────────────────────────────────────────────────
mkdir -p /tmp/marina-guide
cp -R build/Marina.app "$APP"
chmod -R u+w "$APP"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier org.fherwig.marinaguide" \
  -c "Set :CFBundleName MarinaGuide" "$APP/Contents/Info.plist"
xattr -cr "$APP"
codesign --force --sign - "$APP" 2>/dev/null

rm -rf "$OUT"; mkdir -p "$OUT"
# run the executable directly, so the argument reaches it; it quits by itself
"$APP/Contents/MacOS/Marina" --guide-shots "$PWD/$OUT" >/tmp/marina-guide.log 2>&1 &
PID=$!
i=0
while kill -0 $PID 2>/dev/null; do
  sleep 1; i=$((i+1))
  if [ $i -gt 300 ]; then echo "guide mode did not finish in 300 s" >&2; kill $PID; exit 1; fi
done
ls -1 "$OUT"
