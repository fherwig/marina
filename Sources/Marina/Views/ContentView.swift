import SwiftUI

struct ContentView: View {
    @EnvironmentObject var app: AppState
    @FocusState private var focus: FocusTarget?

    var body: some View {
        NavigationSplitView(columnVisibility: Binding(
            get: { app.sidebarVisible ? .all : .detailOnly },
            set: { app.sidebarVisible = ($0 != .detailOnly) }
        )) {
            SidebarView(focus: $focus)
                .navigationSplitViewColumnWidth(min: 150, ideal: 190, max: 300)
        } detail: {
            VStack(spacing: 0) {
                if app.tabBarVisible {
                    TabBarView(focus: $focus)
                    Divider()
                }
                if let tab = app.activeTab {
                    SessionView(tab: tab, focus: $focus)
                        .id(tab.id)
                } else {
                    Color.clear
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .navigation) {
                    Button { app.goBack() } label: { Image(systemName: "chevron.backward") }
                        .help("Back (⌘[)")
                    Button { app.goForward() } label: { Image(systemName: "chevron.forward") }
                        .help("Forward (⌘])")
                    Button { app.goUp() } label: { Image(systemName: "arrow.up") }
                        .help("Enclosing Folder (← / ⌫)")
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        if app.activeTab?.isDual == true {
                            app.singlePane()
                        } else {
                            app.openInSecondPane()
                        }
                    } label: { Image(systemName: "rectangle.split.2x1") }
                        .help("Second Pane on/off (⌘2 / ⌘1)")
                        .accessibilityLabel("Second Pane")
                    Button { app.toggleTerminal() } label: { Image(systemName: "terminal") }
                        .help("Terminal (⌘`)")
                        .accessibilityLabel("Terminal")
                    Button { app.helpVisible.toggle() } label: { Image(systemName: "questionmark.circle") }
                        .help("Keyboard Help (⌃⌘H)")
                        .accessibilityLabel("Keyboard Help")
                        .popover(isPresented: $app.helpVisible, arrowEdge: .bottom) {
                            HelpView()
                        }
                }
            }
        }
        .onAppear {
            app.bootstrap()
        }
        .onChange(of: app.focusRequest) { _, request in
            guard let request else { return }
            // defer past the current key-event cycle; a synchronous focus move
            // from inside another view's key handler is silently dropped
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                focus = request.target
            }
        }
        // ⌘-arrow moves are decided against where the keyboard actually is
        .onChange(of: focus) { _, target in
            app.focusedTarget = target
        }
        .sheet(item: $app.renameTarget) { request in
            RenameSheet(request: request)
                .environmentObject(app)
        }
        .sheet(item: $app.sectionPrompt) { prompt in
            SectionNameSheet(prompt: prompt)
                .environmentObject(app)
        }
        .alert("Marina", isPresented: Binding(
            get: { app.errorMessage != nil },
            set: { if !$0 { app.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(app.errorMessage ?? "")
        }
    }
}

struct RenameSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    let request: RenameRequest
    @State private var name: String
    @State private var committed = false

    init(request: RenameRequest) {
        self.request = request
        _name = State(initialValue: request.currentName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(request.headline)
                .font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit { commit() }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(request.confirmTitle) { commit() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        // Esc dismisses the sheet without running the Cancel button's action,
        // so the "never mind" cleanup has to hang off the sheet going away
        .onDisappear { if !committed { app.cancelRename(request) } }
    }

    private func commit() {
        committed = true
        app.performRename(request, to: name)
        dismiss()
    }
}

/// Name a new favourites section, or rename an existing one.
struct SectionNameSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    let prompt: SectionPrompt
    @State private var name: String

    init(prompt: SectionPrompt) {
        self.prompt = prompt
        _name = State(initialValue: prompt.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(prompt.headline)
                .font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .onSubmit { commit() }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(prompt.confirmTitle) { commit() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        // a dismissed sheet leaves the keyboard nowhere; put it back where it was
        .onDisappear { if let target = prompt.returnTo { app.requestFocus(target) } }
    }

    private func commit() {
        app.commitSectionPrompt(prompt, name: name)
        dismiss()
    }
}
