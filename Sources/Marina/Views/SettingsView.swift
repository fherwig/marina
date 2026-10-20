import SwiftUI
import AppKit

/// Marina ▸ Settings… (⌘,) — the choices where people genuinely differ, each
/// with what it does spelled out underneath, since a setting nobody can
/// predict the effect of is one nobody changes. Keys and readers: Preferences.
/// A change applies to everything open at once.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            PanesSettings()
                .tabItem { Label("Panes", systemImage: "rectangle.split.2x1") }
            TerminalSettings()
                .tabItem { Label("Terminal", systemImage: "terminal") }
            SidebarSettings()
                .tabItem { Label("Sidebar", systemImage: "sidebar.left") }
            VoiceSettings()
                .tabItem { Label("Voice", systemImage: "mic") }
        }
        .frame(width: 520)
    }
}

// MARK: - General

struct GeneralSettings: View {
    @AppStorage(UIZoom.key) private var zoom = 1.0
    @AppStorage(Preferences.startFolderKey) private var startFolder = ""
    @AppStorage(Preferences.showHiddenKey) private var showHidden = false

    /// Picker tag for "choose a folder", which never stays selected.
    private static let chooseTag = "\u{0}choose"

    var body: some View {
        Form {
            Section("Text") {
                Picker("Size", selection: Binding(
                    get: { UIZoom.nearestStep(to: zoom) },
                    set: { UIZoom.set($0) }
                )) {
                    ForEach(UIZoom.steps, id: \.self) { step in
                        Text(step == 1 ? "100 % (Actual Size)" : "\(Int((step * 100).rounded())) %")
                            .tag(step)
                    }
                }
                .accessibilityLabel("Text size")
                Explanation("""
                    One size for everything Marina draws itself: file lists, \
                    sidebar, tabs, the terminal and the viewer's text, in every \
                    window. ⌘+ and ⌘− step through the same sizes. Menus, the \
                    toolbar, PDFs and pictures keep their own size.
                    """)
            }
            Section("New windows") {
                Picker("Open in", selection: Binding(
                    get: { startFolder },
                    set: { tag in
                        if tag == Self.chooseTag {
                            // not from inside the picker's own update
                            DispatchQueue.main.async { chooseFolder() }
                        } else {
                            startFolder = tag
                        }
                    }
                )) {
                    Text("Home").tag("")
                    if !startFolder.isEmpty {
                        Text(FileManager.default.displayName(atPath: startFolder)).tag(startFolder)
                    }
                    Divider()
                    Text("Other Folder…").tag(Self.chooseTag)
                }
                .accessibilityLabel("New windows open in")
                Explanation("""
                    The folder a new window (⌥⌘N, or Marina starting up) shows. \
                    New tabs open in the folder you are in. A folder that is \
                    gone, or on a disk that is not connected, means home.
                    """)
            }
            Section("Files") {
                Toggle(isOn: $showHidden) {
                    Text("Show hidden files")
                    Explanation("""
                        Files and folders whose names start with a dot, such as \
                        .claude or .config, are listed in every pane. ⇧⌘. still \
                        shows or hides them in one pane. Changing this here \
                        applies to every open pane.
                        """)
                }
                .accessibilityLabel("Show hidden files")
                .onChange(of: showHidden) { _, _ in Preferences.applyShowHidden() }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "The folder new Marina windows open in"
        if !startFolder.isEmpty { panel.directoryURL = URL(fileURLWithPath: startFolder) }
        if panel.runModal() == .OK, let url = panel.url {
            startFolder = url.path
        }
    }
}

// MARK: - Panes

struct PanesSettings: View {
    @AppStorage(Preferences.terminalPerPaneKey) private var terminalPerPane = false
    @AppStorage(Preferences.panesFollowTerminalKey) private var panesFollowTerminal = true
    @AppStorage(Preferences.terminalFollowsPanesKey) private var terminalFollowsPanes = true

    var body: some View {
        Form {
            Section("Two file panes") {
                Toggle(isOn: $terminalPerPane) {
                    Text("Terminal per pane")
                    Explanation("""
                        With two file panes open (⌘2), each pane folds down a \
                        terminal of its own, whose shell follows that pane. ⌘`, \
                        ⌘↓, ⌥⌘` and ⌘J act on the active pane's terminal.
                        """)
                    Explanation("""
                        Off: one terminal per tab, across both panes or, with \
                        ⌥⌘J, under the left one. It follows whichever pane is \
                        active. Turning this off or closing the second pane \
                        hides the right-hand terminal; what runs in it keeps \
                        running.
                        """)
                }
                // the grouped form draws the label apart from the switch, and
                // VoiceOver found the switch unnamed (measured)
                .accessibilityLabel("Terminal per pane")
            }

            Section("Following") {
                Toggle(isOn: $panesFollowTerminal) {
                    Text("Panes follow the terminal")
                    Explanation("A cd in the shell takes the file pane to that folder.")
                }
                .accessibilityLabel("Panes follow the terminal")
                Toggle(isOn: $terminalFollowsPanes) {
                    Text("Terminal follows the panes")
                    Explanation("""
                        Going to another folder in the pane types the cd into \
                        the shell, but only while it sits idle at its prompt: \
                        a running claude, editor or build is never interrupted, \
                        and a half-typed command is never wiped.
                        """)
                }
                .accessibilityLabel("Terminal follows the panes")
                Explanation("""
                    These are how every tab starts, and changing them here \
                    applies to every open tab. Terminal ▸ Panes Follow Terminal \
                    and Terminal Follows Panes switch them for one tab.
                    """)
            }
            .onChange(of: panesFollowTerminal) { _, _ in Preferences.applyFollow() }
            .onChange(of: terminalFollowsPanes) { _, _ in Preferences.applyFollow() }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Terminal

struct TerminalSettings: View {
    @AppStorage(Preferences.terminalFontKey) private var fontName = ""
    @AppStorage(Preferences.terminalFontWeightKey) private var monoWeight = Preferences.MonoWeight.medium.rawValue
    @AppStorage(Preferences.terminalFontSizeKey) private var fontSize = Preferences.defaultTerminalFontSize
    @AppStorage(Preferences.terminalColoursKey) private var colours = Preferences.TerminalColours.dark.rawValue
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Form {
            Section("Font") {
                Picker("Font", selection: family) {
                    Text("SF Mono").tag("")
                    Divider()
                    ForEach(MonoFonts.families, id: \.self) { Text($0).tag($0) }
                }
                .accessibilityLabel("Terminal font")
                Picker("Style", selection: style) {
                    if fontName.isEmpty {
                        ForEach(Preferences.MonoWeight.allCases, id: \.self) { weight in
                            Text(weight == .medium ? "Medium (Marina's own)" : weight.name)
                                .tag(weight.rawValue)
                        }
                    } else {
                        ForEach(MonoFonts.styles(ofFamily: currentFamily), id: \.postScriptName) {
                            Text($0.name).tag($0.postScriptName)
                        }
                    }
                }
                .accessibilityLabel("Font style")
                LabeledContent("Size") {
                    HStack {
                        Text("\(fontSize.formatted(.number.precision(.fractionLength(0...1)))) pt")
                            .monospacedDigit()
                        Stepper("Size", value: $fontSize, in: 8...32, step: 0.5)
                            .labelsHidden()
                    }
                }
                preview
                Explanation("""
                    The size is the one at Actual Size: ⌘+ and ⌘− make it bigger \
                    and smaller with the rest of Marina. The list holds the \
                    fonts on this Mac whose letters are all one width.
                    """)
            }
            .onChange(of: fontName) { _, _ in Preferences.applyTerminalLook() }
            .onChange(of: monoWeight) { _, _ in Preferences.applyTerminalLook() }
            .onChange(of: fontSize) { _, _ in Preferences.applyTerminalLook() }

            Section("Colours") {
                Picker("Text and background", selection: $colours) {
                    Text("White on black").tag(Preferences.TerminalColours.dark.rawValue)
                    Text("Black on white").tag(Preferences.TerminalColours.light.rawValue)
                    Text("Like the Mac").tag(Preferences.TerminalColours.system.rawValue)
                }
                .pickerStyle(.radioGroup)
                Explanation("Like the Mac:", """
                    white on black while the Mac is in dark appearance, black on \
                    white while it is light, switching when it does.
                    """)
                Explanation("""
                    Programs that pick their own colours keep them. Claude Code \
                    has a light theme of its own: /theme in claude.
                    """)
            }
            .onChange(of: colours) { _, _ in Preferences.applyTerminalLook() }

        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// A few lines in the chosen font, size and colours.
    private var preview: some View {
        let light: Bool
        switch Preferences.TerminalColours(rawValue: colours) ?? .dark {
        case .dark: light = false
        case .light: light = true
        case .system: light = colorScheme == .light
        }
        // Actual Size, as the size above says
        let font = Preferences.terminalFont(zoom: 1)
        return Text(verbatim: "~/notes % ls\nletters  notes  todo.md\n~/notes % ")
            .font(Font(font))
            .foregroundStyle(light ? Color.black : Color.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(light ? Color.white : Color.black)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            // redrawn on every change of the four settings it shows
            .id("\(fontName)|\(monoWeight)|\(fontSize)|\(colours)")
            .accessibilityHidden(true)
    }

    private var currentFamily: String {
        NSFont(name: fontName, size: 12)?.familyName ?? ""
    }

    /// "" is SF Mono; any other family stores its regular face.
    private var family: Binding<String> {
        Binding(
            get: { fontName.isEmpty ? "" : currentFamily },
            set: { newFamily in
                fontName = newFamily.isEmpty ? "" : MonoFonts.regularFace(ofFamily: newFamily) ?? ""
            }
        )
    }

    /// SF Mono's styles are its weights; any other family's are its faces.
    private var style: Binding<String> {
        Binding(
            get: { fontName.isEmpty ? monoWeight : fontName },
            set: { if fontName.isEmpty { monoWeight = $0 } else { fontName = $0 } }
        )
    }
}

/// The fonts a terminal can use: every family on this Mac whose letters are
/// all one width. SF Mono is not among them by name — it is the system's, and
/// reached through `monospacedSystemFont`.
private enum MonoFonts {
    struct Face { let postScriptName: String; let name: String }

    static let families: [String] = {
        let manager = NSFontManager.shared
        return manager.availableFontFamilies.filter { family in
            guard !family.hasPrefix("."),
                  let name = manager.availableMembers(ofFontFamily: family)?.first?[0] as? String,
                  let font = NSFont(name: name, size: 12) else { return false }
            return font.isFixedPitch
        }
    }()

    /// The upright faces; a terminal draws italics itself when asked.
    static func styles(ofFamily family: String) -> [Face] {
        let members = NSFontManager.shared.availableMembers(ofFontFamily: family) ?? []
        return members.compactMap { member in
            guard let name = member[0] as? String, let style = member[1] as? String,
                  let traits = member[3] as? UInt,
                  !NSFontTraitMask(rawValue: traits).contains(.italicFontMask) else { return nil }
            return Face(postScriptName: name, name: style)
        }
    }

    static func regularFace(ofFamily family: String) -> String? {
        let faces = styles(ofFamily: family)
        return (faces.first { $0.name == "Regular" } ?? faces.first)?.postScriptName
    }
}

// MARK: - Sidebar

struct SidebarSettings: View {
    @AppStorage(Preferences.showVolumesKey) private var showVolumes = true
    @AppStorage(Preferences.showClaudeSessionsKey) private var showClaudeSessions = true
    @AppStorage(Preferences.sessionClickKey) private var sessionClick = Preferences.SessionClick.openFolder.rawValue

    var body: some View {
        Form {
            Section("Sections") {
                Toggle(isOn: $showVolumes) {
                    Text("Volumes")
                    Explanation("Every mounted disk and cloud drive, with its free space.")
                }
                .accessibilityLabel("Volumes")
                Toggle(isOn: $showClaudeSessions) {
                    Text("Claude Sessions")
                    Explanation("Every Claude Code session running on this Mac, by its folder.")
                }
                .accessibilityLabel("Claude Sessions")
                Explanation("""
                    A section turned off here is gone from the sidebar, and the \
                    arrow keys pass it by. Folding a section (← or its triangle) \
                    only closes it.
                    """)
            }
            Section("Claude Sessions") {
                Picker("Clicking a session", selection: $sessionClick) {
                    Text("Shows its folder").tag(Preferences.SessionClick.openFolder.rawValue)
                    Text("Goes to the session").tag(Preferences.SessionClick.goToSession.rawValue)
                }
                .pickerStyle(.radioGroup)
                Explanation("Shows its folder:", """
                    the pane opens the folder the session works in, and nothing \
                    else happens.
                    """)
                Explanation("Goes to the session:", """
                    a Marina tab that already shows the session comes to the \
                    front, with its terminal focused. A session running in tmux \
                    is attached in this tab's terminal, on its own pane — only \
                    if that terminal is idle at its prompt, never over a program \
                    running there. Clicking a folder in the sidebar afterwards \
                    detaches again; the session keeps running in tmux. A session \
                    started in another terminal app brings that app to the front.
                    """)
                Explanation("""
                    Return does the same as a click. Right-click a session for \
                    Go to Session or Open Folder, whatever is chosen here.
                    """)
            }
            .disabled(!showClaudeSessions)
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Voice

struct VoiceSettings: View {
    @AppStorage(Preferences.voiceInputKey) private var input = Preferences.VoiceInput.claude.rawValue
    @AppStorage(Preferences.dictationPythonKey) private var python = ""
    @AppStorage(Preferences.dictationModelKey) private var model = "small"
    @AppStorage(Preferences.dictationWordsKey) private var words = ""
    @AppStorage(Preferences.dictationUnloadKey) private var unloadMinutes = 20
    @State private var checking = false
    @State private var checkResult: Result<String, DictationError>?
    @ObservedObject private var speech = SpeechService.shared

    private var whisper: Bool { input == Preferences.VoiceInput.whisper.rawValue }

    var body: some View {
        Form {
            Section("Hold Space to talk") {
                Picker("Voice input", selection: $input) {
                    Text("Claude Code's /voice").tag(Preferences.VoiceInput.claude.rawValue)
                    Text("Whisper, through Marina").tag(Preferences.VoiceInput.whisper.rawValue)
                }
                .pickerStyle(.radioGroup)
                Explanation("Claude Code's /voice:", """
                    Marina leaves Space alone. In Claude Code, /voice turns on \
                    its own hold-Space dictation; macOS asks once whether \
                    Marina may use the microphone. Marina's name fields have \
                    no voice input then.
                    """)
                Explanation("Whisper:", """
                    Marina takes the held Space, in every terminal, whatever \
                    runs in it, and in its name fields: renaming a file, \
                    naming a new Markdown file or a favourites section. \
                    Speak; let go, and the words appear where the cursor is, \
                    with no Return added. A quick tap still types a space; in \
                    a terminal it goes out as the key comes up. Esc while \
                    listening cancels. Claude Code's /voice no longer gets \
                    Space.
                    """)
            }
            Section("Whisper, on this Mac") {
                if speech.phase != .absent {
                    LabeledContent("Shared speech service") {
                        Text(verbatim: [speech.model, speech.engine.map { "(\($0))" }]
                            .compactMap { $0 }.joined(separator: " "))
                    }
                    Explanation("""
                        The session dashboard's, running on this Mac. While it \
                        runs Marina dictates with its model and loads none of \
                        its own; the dashboard chooses the model. The Python and \
                        model below are for when it is not running.
                        """)
                }
                LabeledContent("Python") {
                    HStack {
                        TextField("Python", text: $python,
                                  prompt: Text(verbatim: (Preferences.defaultPython.path as NSString)
                                      .abbreviatingWithTildeInPath))
                            .labelsHidden()
                        Button("Choose…") { choosePython() }
                    }
                }
                Picker("Model", selection: $model) {
                    ForEach(Preferences.dictationModels, id: \.self) { Text($0).tag($0) }
                }
                .accessibilityLabel("Whisper model")
                LabeledContent("Words to expect") {
                    TextField("Words to expect", text: $words, prompt: Text("Names, separated by commas"), axis: .vertical)
                        .labelsHidden()
                        .lineLimit(1...4)
                }
                Picker("Unload after", selection: $unloadMinutes) {
                    ForEach([5, 10, 20, 60], id: \.self) { Text("\($0) minutes unused").tag($0) }
                }
                .accessibilityLabel("Unload the model after")
                HStack {
                    Button("Check") { check() }
                        .disabled(checking)
                    if checking {
                        ProgressView().controlSize(.small)
                        Text("Loading Whisper \(model)…").foregroundStyle(.secondary)
                    } else if let checkResult {
                        switch checkResult {
                        case .success(let text):
                            Label(text, systemImage: "checkmark.circle").foregroundStyle(.green)
                        case .failure(let error):
                            Label(error.message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                        }
                    }
                }
                .font(.callout)
                Explanation("""
                    Dictation runs openai-whisper in Python on this Mac; nothing \
                    leaves it. That Python needs it installed (pip install \
                    openai-whisper), and ffmpeg, which Whisper reads sound with. \
                    Left empty, the field means the Python shown in grey: the \
                    first Marina found with Whisper, looking in conda \
                    environments first. Check loads the model the way \
                    dictation will.
                    """)
                Explanation("""
                    Which model depends on the Mac. Whisper runs on its \
                    processor, and further down the list a model hears better \
                    and needs more memory and, mostly, more time. On an Apple \
                    M2 with 16 GB, small is the largest that keeps up: a \
                    sentence takes 2 to 3 seconds, and the model holds 1.5 GB \
                    while loaded. medium was too slow there. tiny and base \
                    suit a slower Mac or one short of memory; medium, turbo \
                    and large-v3 a faster one with memory to spare. Try a \
                    model with Check and a few sentences.
                    """)
                Explanation("""
                    The first dictation after a while loads the model, while \
                    you are still talking: up to 10 seconds for small. Each \
                    recording is deleted once it has been turned into text.
                    """)
                Explanation("""
                    Whisper does not learn. It takes the words to expect as a \
                    hint, with the folder names of your Claude sessions and \
                    favourites after them: a name it keeps getting wrong goes \
                    in the list.
                    """)
            }
            .disabled(!whisper)
            .onAppear { if whisper { speech.connect() } }
            .onChange(of: input) { _, _ in if whisper { speech.connect() } }
            .onChange(of: python) { _, _ in DictationWorker.shared.stop(); checkResult = nil }
            .onChange(of: model) { _, _ in DictationWorker.shared.stop(); checkResult = nil }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func check() {
        checking = true
        checkResult = nil
        Transcription.shared.check { result in
            checking = false
            checkResult = result
        }
    }

    private func choosePython() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = true
        panel.showsHiddenFiles = true
        panel.message = "The Python that has openai-whisper, such as an environment's bin/python"
        panel.prompt = "Choose"
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        if panel.runModal() == .OK, let url = panel.url { python = url.path }
    }
}

// MARK: -

/// What a setting does, under it in small grey type. Verbatim, not Markdown:
/// the backquote of ⌘` would start a code span.
struct Explanation: View {
    private let option: String?
    private let text: String

    init(_ text: String) {
        option = nil
        self.text = text
    }

    /// An option's name in bold, then what it does.
    init(_ option: String, _ text: String) {
        self.option = option
        self.text = text
    }

    var body: some View {
        Group {
            if let option {
                Text("\(Text(verbatim: option).bold()) \(Text(verbatim: text))")
            } else {
                Text(verbatim: text)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}
