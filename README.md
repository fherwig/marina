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
- **Second pane** (⌘2) — the Midnight Commander move: open a folder beside the
  current one, not in a tab. Tab switches panes; ⌘M moves the selection across.
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
Requires macOS 14+ and the Xcode Command Line Tools (`xcode-select --install`).

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
| ⌘2 | Open selected folder in second pane (current folder if none) |
| ⌘1 | Back to single pane |
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
| Space (or right-click) | Action menu — on a favourite: remove, move to another section, and for folders open in terminal, second pane, new tab; on a section header: rename, delete, move, fold |
| ⇧⌥⌘N | New section (Actions ▸ New Sidebar Section…, or right-click the sidebar) |
| ⌥⌘← (in a pane) | Add the selection — files or folders — to the sidebar |
| Drag onto sidebar | Add dragged items (from a pane or Finder) at the spot you drop them |
| Drag a favourite | Reorder it, or move it into another section — a line shows where it lands |
| ⇧⌥⌘R | Rescan the Claude Sessions section (or press ⟳ in its header) |

### Terminal
| Key | Action |
|---|---|
| ⌘` | Toggle terminal: show + focus; hide when already focused |
| ⌘↓ / ⌘↑ | Focus down into the terminal / climb back up to the file pane (⌘↑ again → tab bar) |
| ⌥⌘` | Terminal full height (file panes fold away) — press again to restore |
| ⌘J | `cd` the shell to the active pane's folder |
| Drag / double-click / triple-click | Select text, a word, a line |
| ⌘C / ⌘V | Copy the selection / paste into the shell (⌘C with nothing selected leaves the clipboard alone) |
| Right-click | Copy, Paste, Select All |
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
