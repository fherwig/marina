import AppKit

/// The choices in Marina ▸ Settings… (⌘,), by their defaults keys. Views bind
/// them with @AppStorage under the same key; the rest of the app reads them
/// here, at the moment it acts. A change in Settings applies to everything
/// open straight away: SettingsView calls the matching `apply` below.
enum Preferences {
    private static var defaults: UserDefaults { .standard }

    /// An on/off setting that is on until someone turns it off.
    private static func bool(_ key: String, default value: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? value
    }

    // MARK: - General

    /// The folder a new window opens in; absent, home. New tabs open in the
    /// folder you are in.
    static let startFolderKey = "marina.startFolder"
    static var startFolder: URL {
        if let path = defaults.string(forKey: startFolderKey) {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                return URL(fileURLWithPath: path)
            }
        }
        // a folder since deleted, or a disk not mounted: home, as before
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// Every pane starts with hidden files shown; ⇧⌘. still switches one pane.
    static let showHiddenKey = "marina.showHiddenFiles"
    static var showHidden: Bool { defaults.bool(forKey: showHiddenKey) }

    // MARK: - Tiles

    /// Folders shown as tiles rather than a list (View ▸ Toggle Tiles, ⌘4).
    /// Each folder remembers, as in Finder: pictures stay tiles, code stays a
    /// list. A folder not named here is a list.
    static let tileFoldersKey = "marina.tileFolders"
    static func showsTiles(_ folder: URL) -> Bool {
        (defaults.stringArray(forKey: tileFoldersKey) ?? []).contains(folder.path)
    }
    static func setShowsTiles(_ on: Bool, for folder: URL) {
        var folders = defaults.stringArray(forKey: tileFoldersKey) ?? []
        folders.removeAll { $0 == folder.path }
        if on { folders.append(folder.path) }
        defaults.set(folders, forKey: tileFoldersKey)
    }

    /// A tile's width in points, one for every pane: the slider in the path
    /// bar, ⌥⌘+ and ⌥⌘−. From many small tiles across to three or four large
    /// ones down a big screen.
    static let tileSizeKey = "marina.tileSize"
    static let tileSizes: ClosedRange<Double> = 64...640
    static let defaultTileSize = 160.0
    static var tileSize: Double {
        let stored = defaults.double(forKey: tileSizeKey)
        return stored > 0 ? min(max(stored, tileSizes.lowerBound), tileSizes.upperBound) : defaultTileSize
    }
    /// ⌥⌘+ / ⌥⌘−: a fifth bigger or smaller, so a few presses go from one
    /// end to the other.
    static func stepTileSize(bigger: Bool) {
        let next = bigger ? tileSize * 1.25 : tileSize / 1.25
        defaults.set(min(max(next.rounded(), tileSizes.lowerBound), tileSizes.upperBound), forKey: tileSizeKey)
    }

    // MARK: - Terminal

    /// With two file panes, each folds down its own terminal. Off (the
    /// default): one terminal per tab, across both panes or — ⌥⌘J — under the
    /// left one.
    static let terminalPerPaneKey = "marina.terminalPerPane"
    static var terminalPerPane: Bool { defaults.bool(forKey: terminalPerPaneKey) }

    /// The terminal font's PostScript name; absent, SF Mono, which has no
    /// public name and is chosen by weight instead.
    static let terminalFontKey = "marina.terminalFont"
    static let terminalFontWeightKey = "marina.terminalFontWeight"
    static let terminalFontSizeKey = "marina.terminalFontSize"
    static let defaultTerminalFontSize = 12.5

    /// SF Mono's weights. Medium is the default: thicker stems than regular,
    /// which is what carries contrast on black.
    enum MonoWeight: String, CaseIterable {
        case regular, medium, semibold, bold
        var nsWeight: NSFont.Weight {
            switch self {
            case .regular: return .regular
            case .medium: return .medium
            case .semibold: return .semibold
            case .bold: return .bold
            }
        }
        var name: String { rawValue.capitalized }
    }

    /// At Actual Size; ⌘+ / ⌘− scale it with everything else.
    static var terminalFontSize: Double {
        let stored = defaults.double(forKey: terminalFontSizeKey)
        return stored > 0 ? stored : defaultTerminalFontSize
    }

    static func terminalFont(zoom: CGFloat = UIZoom.factor) -> NSFont {
        let size = CGFloat(terminalFontSize) * zoom
        if let name = defaults.string(forKey: terminalFontKey),
           let font = NSFont(name: name, size: size) {
            return font
        }
        let weight = defaults.string(forKey: terminalFontWeightKey).flatMap(MonoWeight.init) ?? .medium
        return NSFont.monospacedSystemFont(ofSize: size, weight: weight.nsWeight)
    }

    static let terminalColoursKey = "marina.terminalColours"
    enum TerminalColours: String {
        /// plain white on black — the default
        case dark
        /// black on white
        case light
        /// dark or light with the Mac's appearance
        case system
    }
    static var terminalColours: TerminalColours {
        defaults.string(forKey: terminalColoursKey).flatMap(TerminalColours.init) ?? .dark
    }

    /// Font, size or colours changed: every terminal redraws in them.
    static let terminalLookChanged = Notification.Name("MarinaTerminalLookChanged")

    /// Where each new tab's two follow switches start (Terminal menu).
    static let panesFollowTerminalKey = "marina.panesFollowTerminal"
    static var panesFollowTerminal: Bool { bool(panesFollowTerminalKey, default: true) }
    static let terminalFollowsPanesKey = "marina.terminalFollowsPanes"
    static var terminalFollowsPanes: Bool { bool(terminalFollowsPanesKey, default: true) }

    // MARK: - Sidebar

    static let showVolumesKey = "marina.showVolumes"
    static let showClaudeSessionsKey = "marina.showClaudeSessions"

    /// What a click (or Return) on a Claude Sessions row does.
    static let sessionClickKey = "marina.claudeSessionClick"
    enum SessionClick: String {
        /// Show the session's folder in the pane — the default.
        case openFolder
        /// Bring up the session itself; see AppState.goToSession.
        case goToSession
    }
    static var sessionClick: SessionClick {
        defaults.string(forKey: sessionClickKey).flatMap(SessionClick.init) ?? .openFolder
    }

    // MARK: - Voice

    /// Who answers a held Space: the program in the terminal, which is how
    /// Claude Code's /voice works, or Marina with Whisper. Both at once
    /// cannot be: whoever gets the Space first keeps it.
    static let voiceInputKey = "marina.voiceInput"
    enum VoiceInput: String {
        /// Marina leaves Space alone everywhere — the default
        case claude
        /// hold Space in any terminal or Marina text field
        case whisper
    }
    static var voiceInput: VoiceInput {
        defaults.string(forKey: voiceInputKey).flatMap(VoiceInput.init) ?? .claude
    }

    /// The Python with openai-whisper; absent, the one found with it.
    static let dictationPythonKey = "marina.dictationPython"
    static var dictationPython: URL {
        if let path = defaults.string(forKey: dictationPythonKey), !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return defaultPython
    }

    /// The first Python that has openai-whisper installed: a conda
    /// environment (one called whisper first), pipx's, then the usual
    /// python3s; failing all, the first python3 there is. Homebrew's python3
    /// came first before, and has no Whisper on Falk's Mac: Check failed with
    /// "No module named 'whisper'" while his conda environment had it.
    static let defaultPython: URL = {
        let files = FileManager.default
        let home = files.homeDirectoryForCurrentUser.path
        var candidates: [String] = []
        let condas = ["miniforge3", "mambaforge", "miniconda3", "anaconda3"].map { "\(home)/\($0)" }
            + ["/opt/homebrew/Caskroom/miniforge/base", "/opt/miniconda3", "/opt/anaconda3"]
        for base in condas {
            let envs = ((try? files.contentsOfDirectory(atPath: base + "/envs")) ?? [])
                .sorted { ($0 == "whisper" ? 0 : 1, $0) < ($1 == "whisper" ? 0 : 1, $1) }
            candidates += envs.map { "\(base)/envs/\($0)/bin/python" } + ["\(base)/bin/python"]
        }
        candidates += ["\(home)/.local/pipx/venvs/openai-whisper/bin/python",
                       "/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
        let usable = candidates.filter { files.isExecutableFile(atPath: $0) }
        let found = usable.first(where: hasWhisper) ?? usable.first
        return URL(fileURLWithPath: found ?? "/usr/bin/python3")
    }()

    /// Whether whisper sits in this Python's site-packages: …/bin/python
    /// beside …/lib/python3.x/site-packages, as in conda, a venv and
    /// Homebrew. Looked up, not run: starting Python takes a second.
    static func hasWhisper(_ python: String) -> Bool {
        let lib = ((python as NSString).deletingLastPathComponent as NSString)
            .deletingLastPathComponent + "/lib"
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: lib)) ?? []
        return versions.contains { version in
            version.hasPrefix("python3")
                && FileManager.default.fileExists(atPath: "\(lib)/\(version)/site-packages/whisper/__init__.py")
        }
    }

    static let dictationModelKey = "marina.dictationModel"
    static let dictationModels = ["tiny", "base", "small", "medium", "turbo", "large-v3"]
    /// small: what Falk chose against base on his own voice
    static var dictationModel: String {
        defaults.string(forKey: dictationModelKey).flatMap { dictationModels.contains($0) ? $0 : nil } ?? "small"
    }

    /// Names and terms to expect, separated by commas or lines.
    static let dictationWordsKey = "marina.dictationWords"
    static var dictationWords: String { defaults.string(forKey: dictationWordsKey) ?? "" }

    /// Minutes unused before the model is unloaded: small holds 1.5 GB (measured), larger ones more.
    static let dictationUnloadKey = "marina.dictationUnloadMinutes"
    static var dictationUnloadMinutes: Int {
        let stored = defaults.integer(forKey: dictationUnloadKey)
        return stored > 0 ? stored : 20
    }

    /// Testing only: a speech.json in place of the session dashboard's, so a
    /// test copy can be pointed at a stand-in service, or at none.
    static var debugSpeechConfig: String? {
        defaults.string(forKey: "marina.debugSpeechConfig")
    }

    /// Testing only: an audio file that stands in for the microphone.
    static var debugDictationClip: URL? {
        defaults.string(forKey: "marina.debugDictationClip").map { URL(fileURLWithPath: $0) }
    }

    // MARK: - Applying a change to what is open

    @MainActor private static var allTabs: [TabState] {
        MarinaWindows.shared.all.flatMap(\.tabs)
    }

    @MainActor static func applyShowHidden() {
        let show = showHidden
        for pane in allTabs.flatMap(\.panes) where pane.showHidden != show {
            pane.showHidden = show
        }
    }

    @MainActor static func applyFollow() {
        for tab in allTabs {
            tab.followTerminal = panesFollowTerminal
            tab.followPanes = terminalFollowsPanes
        }
    }

    static func applyTerminalLook() {
        NotificationCenter.default.post(name: terminalLookChanged, object: nil)
    }
}
