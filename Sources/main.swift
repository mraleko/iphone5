import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class AppModel: ObservableObject {
    @Published var busy = false
    @Published var saving = false
    @Published var filename = ""
    @Published var fraction: Double?
    @Published var frames = 0
    @Published var finalizing = false
    @Published var error: String?
    private var converter: Converter?
    private var temporaryDirectory: URL?
    private var rendered: URL?
    private var source: URL?

    func choose() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { [weak self] response in
            if response == .OK, let url = panel.url { self?.start(url) }
        }
    }

    func start(_ url: URL) {
        guard !busy else { return }
        error = nil
        busy = true
        filename = url.lastPathComponent
        source = url
        let worker = Converter()
        converter = worker
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("iphone5-\(UUID().uuidString)")
        temporaryDirectory = directory
        let output = directory.appendingPathComponent("render.mov")
        let scoped = url.startAccessingSecurityScopedResource()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try worker.convert(input: url, output: output) { progress in
                    DispatchQueue.main.async {
                        switch progress {
                        case .rendering(let frames, let fraction):
                            self.frames = frames
                            self.fraction = fraction
                        case .finalizing:
                            self.finalizing = true
                            if self.fraction != nil { self.fraction = 0.99 }
                        case .finished:
                            self.fraction = 1
                        }
                    }
                }
            }
            if scoped { url.stopAccessingSecurityScopedResource() }
            DispatchQueue.main.async {
                self.converter = nil
                switch result {
                case .success:
                    self.rendered = output
                    self.saving = true
                    self.save()
                case .failure(let failure):
                    self.reset()
                    if !(failure is CancellationError) { self.error = failure.localizedDescription }
                }
            }
        }
    }

    func cancel() { converter?.cancel() }

    func save() {
        guard let rendered, let source else { return }
        let panel = NSSavePanel()
        panel.title = "Save your iPhone 5 video"
        panel.allowedContentTypes = [.quickTimeMovie]
        panel.nameFieldStringValue = source.deletingPathExtension().lastPathComponent + " - iPhone 5.mov"
        panel.canCreateDirectories = true
        panel.begin { [weak self] response in
            guard let self else { return }
            guard response == .OK, let destination = panel.url else { self.reset(); return }
            guard destination.resolvingSymlinksInPath().standardizedFileURL != source.resolvingSymlinksInPath().standardizedFileURL else {
                self.error = "Choose a different filename to keep your original video."
                return
            }
            // Copy off the UI thread. Stage beside the destination so replacement
            // is atomic and an interrupted copy cannot destroy an existing file.
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result {
                    let staged = destination.deletingLastPathComponent().appendingPathComponent(".iphone5-\(UUID().uuidString).mov")
                    defer { try? FileManager.default.removeItem(at: staged) }
                    try FileManager.default.copyItem(at: rendered, to: staged)
                    if FileManager.default.fileExists(atPath: destination.path) {
                        _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
                    } else {
                        try FileManager.default.moveItem(at: staged, to: destination)
                    }
                }
                DispatchQueue.main.async {
                    switch result {
                    case .success: self.reset()
                    case .failure(let failure):
                        self.error = "Couldn’t save the video. Choose another location.\n\n\(failure.localizedDescription)"
                    }
                }
            }
        }
    }

    func reset() {
        if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
        temporaryDirectory = nil
        rendered = nil
        source = nil
        busy = false
        saving = false
        filename = ""
        fraction = nil
        frames = 0
        finalizing = false
    }
}

struct UtilityButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.custom("Lucida Grande", size: 11))
            .padding(.horizontal, 12).frame(height: 25)
            .background(LinearGradient(colors: configuration.isPressed
                ? [Color(white: 0.76), Color(white: 0.88)]
                : [.white, Color(white: 0.87)], startPoint: .top, endPoint: .bottom))
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color(white: 0.59), lineWidth: 0.5))
            .shadow(color: .white.opacity(0.8), radius: 0, y: 1)
            .opacity(enabled ? 1 : 0.4)
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var targeted = false
    private let ink = Color(white: 0.19)
    private let rule = Color(white: 0.68)

    private var status: String {
        if !model.busy { return "Ready" }
        if model.saving { return "Saving…" }
        if model.finalizing { return "Finalizing…" }
        return model.fraction == nil && model.frames == 0 ? "Preparing…" : "Converting…"
    }

    private var dropArea: some View {
        VStack(spacing: 16) {
            if model.busy {
                if let fraction = model.fraction, !model.saving {
                    ProgressView(value: fraction, total: 1)
                        .progressViewStyle(.linear).tint(Color(red: 0.30, green: 0.49, blue: 0.75))
                        .frame(width: 260).accessibilityLabel("Rendering progress")
                } else {
                    ProgressView().controlSize(.regular).padding(.bottom, 5)
                }
                Text(status)
                    .font(.custom("Lucida Grande", size: 14).weight(.bold))
                if !model.saving && !model.finalizing {
                    if let fraction = model.fraction {
                        Text("\(Int(fraction * 100))% rendered").monospacedDigit()
                    } else if model.frames > 0 {
                        Text("\(model.frames) frames rendered").monospacedDigit()
                    }
                }
                Text(model.filename).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(.secondary).frame(maxWidth: 320)
                if !model.saving {
                    Button("Cancel", action: model.cancel).buttonStyle(UtilityButtonStyle())
                }
            } else {
                Image(systemName: "iphone.gen1")
                    .font(.system(size: 46, weight: .ultraLight))
                    .foregroundStyle(Color(white: 0.46))
                    .shadow(color: .white, radius: 0, y: 1).accessibilityHidden(true)
                Text(targeted ? "Drop your video here" : "Drag in your video")
                    .font(.custom("Lucida Grande", size: 16).weight(.bold))
                Button("Open…", action: model.choose)
                    .keyboardShortcut("o", modifiers: .command)
                    .buttonStyle(UtilityButtonStyle())
                Text("MOV, MP4 and other video files")
                    .font(.custom("Lucida Grande", size: 10)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LinearGradient(colors: [Color(white: 0.94), Color(white: 0.98)], startPoint: .top, endPoint: .bottom))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4)
            .strokeBorder(targeted && !model.busy ? Color(red: 0.30, green: 0.49, blue: 0.75) : rule,
                          lineWidth: targeted && !model.busy ? 2 : 0.5))
        .shadow(color: .white.opacity(0.8), radius: 0, y: 1)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("iPhone 5 Generator")
                .font(.custom("Lucida Grande", size: 19).weight(.bold))
                .shadow(color: .white, radius: 0, y: 1)
                .padding(.top, 24).padding(.bottom, 20)
            dropArea
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $targeted) { providers in
                guard !model.busy, let provider = providers.first else { return false }
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                    let url: URL?
                    if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                    else { url = item as? URL }
                    DispatchQueue.main.async {
                        if let url { model.start(url) }
                        else { model.error = error?.localizedDescription ?? "Drop a video file from Finder." }
                    }
                }
                return true
            }
            .padding(.horizontal, 24).padding(.bottom, 24)
            HStack {
                Text(status)
                Spacer()
                Text("Original files are not modified.").foregroundStyle(.secondary)
            }
            .font(.custom("Lucida Grande", size: 10))
            .padding(.horizontal, 12).frame(height: 25)
            .background(LinearGradient(colors: [Color(white: 0.94), Color(white: 0.84)], startPoint: .top, endPoint: .bottom))
            .overlay(alignment: .top) { rule.frame(height: 0.5) }
        }
        .font(.custom("Lucida Grande", size: 11))
        .frame(width: 460, height: 365)
        .foregroundStyle(ink)
        .background(LinearGradient(colors: [Color(white: 0.91), Color(white: 0.84)], startPoint: .top, endPoint: .bottom))
        .preferredColorScheme(.light)
        .alert("iPhone 5 generator", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            if model.saving {
                Button("Choose another location") { model.error = nil; model.save() }
                Button("Discard", role: .cancel) { model.reset(); model.error = nil }
            } else {
                Button("OK", role: .cancel) { model.error = nil }
            }
        } message: { Text(model.error ?? "") }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit iPhone 5 generator", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let item = NSMenuItem()
        item.submenu = appMenu
        menu.addItem(item)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let edit = NSMenuItem()
        edit.submenu = editMenu
        menu.addItem(edit)
        NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 365),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "iPhone 5 Generator"
        window.appearance = NSAppearance(named: .aqua)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ContentView(model: model))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { model.cancel(); model.reset() }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
