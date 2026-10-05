# Marina

A native macOS file manager with a terminal in every tab — a modern, minimal
descendant of Midnight Commander. Keyboard-first, dual-pane on demand, and the
file view and the shell keep each other in sync.

Built with Swift/SwiftUI and [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm).
No Xcode required — builds with the Command Line Tools alone.

## Features

- **Full keyboard navigation** — arrows move, ← goes to the parent folder,
  → descends into a folder, Space quick-looks, Return opens. Adding ⌘ moves
  between the units on screen the way a mouse would — ⌘← to the sidebar,
  ⌘↑ to the tab bar, ⌘↓ into the terminal. Every quick action is also in the
  right-click menu with its shortcut shown, and in the menu bar.
- **Second pane** (⌘2) — the Midnight Commander move: the same folder beside the
  current one, in equal halves, not in a tab. Tab switches panes; ⌘M moves the
  selection across; drag the divider to resize, and ⌘2 puts it back to halves.
  See [Working with two panes](#working-with-two-panes).
- **Viewer** (⌘3) — the other thing that can sit beside the file list: images
  (including HEIC, RAW and animated GIFs), video and audio with the system's
  controls, PDFs, and text or source files. It follows the selection, so you
  arrow down a folder and watch it go past. Anything else falls back to Quick
  Look, which covers Office documents, archives and fonts.
- **Tabs** (⌘T) — each with its own pane layout and its own shell. ⌥⌘N opens a
  whole new Marina window, with its own tabs; the menu bar always acts on the
  window that has the keyboard.
- **Favourites sidebar** — like Finder's, and fully keyboard-reachable (⌘0,
  then arrows, Return or → to jump). Favourites live in sections you make and
  name (⇧⌥⌘N); each folds away with ← / → or its disclosure triangle, and items
  are reordered — or moved between sections — by dragging them. One list for
  the whole app: it is shared by every window and survives a restart. Add items
  by dropping them onto the sidebar or with ⌥⌘←; folders navigate, files open
  in their default app.
- **Claude Sessions section** — the sidebar also lists the working directory of
  every Claude Code session running right now, so you can jump straight to the
  one you were just in. It is a snapshot: press ⟳ in the section header (or
  ⇧⌥⌘R) to take a new one. Sessions living in a tmux pane show that pane's
  path and are marked with a split-pane icon; ones started straight from a
  terminal show a terminal icon.
- **Volumes section** — every mounted volume and cloud drive in one place: the
  startup disk, attached and network drives, and the file-provider roots of
  iCloud Drive, OneDrive, Google Drive and the like (which are not volumes at
  all, but directories under `~/Library/CloudStorage`). Volumes show free space,
  cloud drives the account they belong to. Mounting or unmounting updates the
  list on its own; a disk that is not the startup or an internal one offers
  Eject in its action menu. **iCloud Drive needs Full Disk Access**: it lives
  under `~/Library/Mobile Documents`, which macOS blocks outright — the row says
  so, and the pane offers the Settings pane where you can grant it. The
  permission is tied to Marina's code signature, which is stable, so it is
  granted once and survives rebuilds.
- **Fold-down terminal per tab** (⌘`) — a real shell (your login shell) under
  the file panes. ⌥⌘` gives the terminal the whole tab; the file manager folds
  away and comes back on the same key.
- **Bidirectional cwd sync** — `cd` in the shell and the file pane follows
  automatically. Navigate in the file pane and send the shell after you with ⌘J.
- **Finder interop** — ⌘C/⌘V file copy-paste and drag & drop in both
  directions between Marina, Finder, and the panes.
- **Form follows function** — system font, real file icons, hairline dividers,
  no decoration. Toolbar with back/forward/up, pane and terminal toggles, and a
  **?** button showing the keyboard cheat sheet.

## Install

Three ways in, in order of how much you want to do yourself.

### The installer (no developer tools needed)

Download the `.pkg` from the [latest release](https://github.com/fherwig/marina/releases/latest)
and open it. It installs into `~/Applications` — a per-user install, so it never
asks for an admin password and never touches another account. Installing over an
older version is fine; quit Marina first.

The installer is **not signed or notarised**, so macOS refuses it on the first
attempt. Right-click the `.pkg` ▸ **Open** ▸ **Open**, or allow it under System
Settings ▸ Privacy & Security after the first try. The app inside is signed with
a self-signed certificate, which is what lets macOS remember the folder
permissions you grant it.

On first use Marina asks for access to Desktop, Documents and Downloads. It is a
file manager; say yes, or it will show you empty folders.

### From a tagged release, built yourself

```sh
git clone https://github.com/fherwig/marina.git
cd marina
git checkout v0.2.0          # or whichever tag you want
make run                     # builds and launches
```

Each tag is the source the matching `.pkg` was built from.

### From the head of main

```sh
git clone https://github.com/fherwig/marina.git
cd marina
make run
```

`main` here **is the latest release**: this repository serves releases, and each
one lands as a single commit, so its head is never ahead of the newest tag.
Development happens in a separate repository with the full history, so there is
no "nightly" to track here. If you want what is being worked on rather than what
was released, open an issue and say so.

**Before the first build**, run `Support/make-signing-cert.sh` once per machine —
see below for why.

### Requirements

macOS 14 or later. Built and tested on Apple silicon; the Intel path is
untested. Building needs the Xcode Command Line Tools
(`xcode-select --install`) and nothing else — no Xcode, no package manager.

## Build & run

```sh
make run        # release build → build/Marina.app → launch
```
Run `Support/make-signing-cert.sh` once per machine. macOS ties file-access
permissions (Desktop, Documents, Downloads) to the code signature, and an
ad-hoc one changes with every build — so without a stable identity every
rebuild looked like a new app and asked for permission again. The script
creates a self-signed certificate; `make app` uses it if it is there and falls
back to ad-hoc if it is not.

Also: `make build` (debug), `make app` (bundle without launching),
`make pkg` (installer that puts Marina in `~/Applications`), `make clean`.

## Keyboard map

### Navigate
| Key | Action |
|---|---|
| ↑ / ↓ | Move selection |
| Click column header | Sort by Name / Size / Modified (click again to reverse; folders stay grouped first) |
| → | Descend into selected folder |
| ←, ⌫ | Go to enclosing folder |
| Return, ⌘O | Open (folder: navigate; file: default app) — double-click does the same |
| Space | Quick Look |
| ⌘[ / ⌘] | Back / Forward |
| ⇧⌘H | Home |
| ⇧⌘. | Show/hide hidden files |
| ⌃⌘H | Show/hide the keyboard cheat sheet |
| Double-click | Open |

### Moving between units (⌘ + arrow)

Plain arrows move *inside* whatever has the keyboard (a file list, the
favourites, the tab bar); the file tree lives on plain ← / →. Holding ⌘ moves
to the unit that is visually in that direction — what a mouse click would do.

| Key | Action |
|---|---|
| ⌘← / ⌘→ | Sidebar ↔ left pane ↔ right pane |
| ⌘↑ | File pane → tab bar (from the terminal: up to the file pane) |
| ⌘↓ | Tab bar → file pane → terminal |

### Panes
| Key | Action |
|---|---|
| ⌘2 | Second pane on the same folder, split in equal halves (again: back to halves) |
| Drag the divider | Resize the two panes |
| ⌘3 | Viewer beside the file list — images, video, audio, PDF, text (again closes it) |
| ⌘1 | Back to single pane (closes a second pane or the viewer) |
| ⇥ (Tab) | Switch pane |
| ⌘M | Move selection to the other pane (window minimize is ⌥⌘M) |

### Windows & Tabs
| Key | Action |
|---|---|
| ⌥⌘N | New Marina — a separate window with its own tabs, panes and shells |
| ⌘T | New tab (at current folder) |
| ⌘W | Close tab |
| ⌘↑ | Focus the tab bar (it appears even with a single tab) |
| ← / → (in the tab bar) | Move between tabs — the pane below follows |
| ↓, Return, Esc (in the tab bar) | Back down to the file pane |
| ⌃⌘→ / ⌃⌘← | Next / previous tab |
| ⌘Return | Open selected folder in new tab |

### Sidebar
| Key | Action |
|---|---|
| ⌘← (from left pane or tab bar), ⌘0 | Focus favourites sidebar (unfolds it if hidden) |
| ⌃⌘S | Fold/unfold the sidebar |
| ↑ / ↓ | Move between favourites — the pane follows immediately (file favourites just get selected) |
| Return or → | Open the selected favourite (folder: navigate + focus pane; file: default app) |
| ⌘→ | Back to the file pane *without* changing folder (undo an accidental ⌘←) |
| ← / → | Fold the section the selection is in / unfold a folded one |
| Type a letter | Jump to the next favourite starting with it; press again to cycle through the rest |
| Space (or right-click) | Action menu — on a favourite: remove, move to another section, and for folders open in terminal, second pane, new tab; on a section header: rename, delete, move, fold |
| ⇧⌥⌘N | New section (Actions ▸ New Sidebar Section…, or right-click the sidebar) |
| ⌥⌘← (in a pane) | Add the selection — files or folders — to the sidebar |
| Drag onto sidebar | Add dragged items (from a pane or Finder) at the spot you drop them |
| Drag a favourite | Reorder it, or move it into another section — a line shows where it lands |
| ⇧⌥⌘R | Rescan the Claude Sessions section (or press ⟳ in its header) |
| Space (on a volume) | Action menu — open, second pane, new tab, terminal, add to sidebar, and Eject where it applies (Go ▸ Refresh Volumes re-reads the list) |

### Terminal
| Key | Action |
|---|---|
| ⌘` | Toggle terminal: show + focus; hide when already focused. It is the key **left of "1"**, so on a German keyboard it is ⌘^ and on a US one ⌘` — the position is what is bound, not the character |
| ⌘↓ / ⌘↑ | Focus down into the terminal / climb back up to the file pane (⌘↑ again → tab bar) |
| ⌥⌘` | Terminal full height (file panes fold away) — press again to restore (same key as above) |
| ⌘J | `cd` the shell to the active pane's folder |
| Drag / double-click / triple-click | Select text, a word, a line |
| ⇧-drag | Select text **while a claude session (or any full-screen program) is running** — it has asked for the mouse, so a plain drag belongs to it and selects nothing. Shift takes the mouse back for one drag; Terminal → Mouse Reporting takes it back for good |
| ⌘C / ⌘V | Copy the selection / paste into the shell (⌘C with nothing selected leaves the clipboard alone) |
| Right-click | Copy, Paste, Select All |
| ⌘W on a busy tab | Asks first — "claude is still running in this tab's terminal" — with Cancel on Return. Closing the tab hangs the terminal up: the shell and what it started end with it, rather than living on unreachable |
| Terminal → Mouse Reporting | On (default): programs in the terminal get the mouse, and ⇧-drag selects. Off: a plain drag selects and those programs lose their mouse. The setting sticks |
| Terminal → Panes Follow Terminal | The panes follow the shell's cd (on by default) |
| Terminal → Terminal Follows Panes | The shell cds after the panes — but only while it sits idle at its prompt, so a running claude, editor or build is never interrupted, and a half-typed command is never wiped (on by default) |

Text is plain white on black in SF Mono medium — the system text colour SwiftTerm
uses by default is only ~85% white, which reads washed out. The font can be
changed without rebuilding (restart Marina after):

```sh
defaults write org.fherwig.marina marina.terminalFont Menlo-Bold   # heaviest
defaults write org.fherwig.marina marina.terminalFontSize 13
defaults delete org.fherwig.marina marina.terminalFont             # back to SF Mono
```

### File operations
| Key | Action |
|---|---|
| ⌘C / ⌘V | Copy / paste files, Finder-compatible (clipboard copy/paste inside the terminal and text fields) |
| ⌘X then ⌘V | Move: ⌘X marks the selection, ⌘V in the other pane (or any folder) moves it there. Nothing leaves disk until the paste |
| ⌘R | Rename |
| ⌘⌫ | Move to Trash |
| ⌘N | New markdown file here — name it, and it opens in your .md editor (Esc = never mind) |
| ⇧⌘N | New folder |
| ⌥⌘O | Open With — a menu of every app that claims the selection, default first (also right-click ▸ Open With) |
| ⌥⌘C | Copy path(s) to clipboard |
| Actions → Reveal in Finder | Hand off to Finder |

## Working with two panes

Copying between two folders is what the two panes are for. The whole move:

1. **⌘2** — the current folder opens beside itself, in equal halves. Both panes
   now show the same place.
2. **Send one of them somewhere else.** Either navigate in the pane itself
   (arrows, Return, ⌫ for the parent, a letter to jump), or use the sidebar:
   **⌘0** puts the keyboard in the sidebar without changing which pane is
   active, so the pane you came from is the one the sidebar steers. Arrow to a
   favourite, a volume or a Claude session and that pane follows.
3. **⇥** switches between the panes; the active one has the keyboard.
4. **⌘C** then **⌘V** copies into the other pane, **⌘X** then **⌘V** moves.
   Or drag the selection across. ⌘⌫ puts files in the Trash.
5. **⌘1** goes back to one pane.

⌘2 always reopens on the *current* folder — it is not "open what I selected".
To send a *named* folder to the other pane, right-click it ▸ Open Second Pane
Here, which is also how a sidebar favourite gets there.

Two things worth knowing about the sidebar: it drives whichever pane is active,
and ⌘← from the right pane steps to the left pane first (a second ⌘← reaches the
sidebar) — so from the right pane, use ⌘0 when you want the sidebar to keep
steering the right one.

## How cwd sync works

The embedded shell is launched with `TERM_PROGRAM=Apple_Terminal`, so the stock
macOS shell integration (`/etc/zshrc_Apple_Terminal`) emits an OSC 7 escape
sequence with the working directory at every prompt. SwiftTerm surfaces that,
and the active pane follows. This works out of the box with zsh and bash on
macOS with no shell configuration. If your zshrc overrides `precmd` wholesale,
the follow stops working — keep Apple's hook or emit OSC 7 yourself.

The reverse direction (⌘J) types `cd '<dir>'` into the shell (preceded by
Ctrl-U to clear any half-typed command), so it lands in your shell history like
anything else you typed.

## As a Claude session host

Marina was designed general-purpose, but the shape is deliberate: one tab per
Claude Code session, the terminal running `claude`, the file panes tracking
what the session touches (dual pane = home dir + work dir), and favourites as
the list of active session directories.

## Roadmap

- Typeahead selection in panes
- Session restore (tabs, panes, terminal cwds)
- Copy/move conflict resolution (currently refuses to overwrite)
- Per-tab terminal profiles (e.g. auto-run a command on open)
