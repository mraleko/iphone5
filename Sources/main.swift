import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class AppModel: ObservableObject {
    @Published var busy = false
    @Published var saving = false
    @Published var filename = ""
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
                try worker.convert(input: url, output: output)
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
        model.busy ? (model.saving ? "Saving…" : "Converting…") : "Ready"
    }

    private func field(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title + ":").foregroundStyle(Color(white: 0.30))
            Text(value)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 7).frame(height: 24)
                .background(Color(white: 0.98))
                .overlay(Rectangle().stroke(Color(white: 0.66), lineWidth: 0.5))
                .overlay(alignment: .top) { Color.black.opacity(0.06).frame(height: 2) }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 9) {
            Button(action: model.choose) {
                Label("Open…", systemImage: "folder")
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(model.busy)
            Button(action: model.cancel) {
                Label("Stop", systemImage: "stop.fill")
            }
            .disabled(!model.busy || model.saving)
            Rectangle().fill(rule).frame(width: 0.5, height: 25).padding(.horizontal, 5)
            Text("iPhone 5 Generator").font(.custom("Lucida Grande", size: 12).weight(.bold))
                .shadow(color: .white, radius: 0, y: 1)
            Spacer()
            Text("Version 1.0").foregroundStyle(.secondary).font(.custom("Lucida Grande", size: 10))
        }
        .buttonStyle(UtilityButtonStyle())
        .padding(.horizontal, 13).frame(height: 49)
        .background(LinearGradient(colors: [Color(white: 0.94), Color(white: 0.79)], startPoint: .top, endPoint: .bottom))
        .overlay(alignment: .top) { Color.white.frame(height: 1) }
        .overlay(alignment: .bottom) { rule.frame(height: 1) }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("OUTPUT PROFILE").font(.custom("Lucida Grande", size: 10).weight(.bold))
                .foregroundStyle(Color(white: 0.45)).shadow(color: .white, radius: 0, y: 1)
            field("Device", "Apple iPhone 5")
            field("Camera", "Rear camera · 2012")
            field("Video", "H.264 / 1080p")
            HStack(spacing: 9) {
                field("Frame rate", "30 fps")
                field("Colour", "SDR")
            }
            field("Audio", "AAC / Mono / 44.1 kHz")
            field("Save as", "QuickTime Movie (.mov)")
            Spacer(minLength: 12)
            // A small engraved-looking device emblem, like the artwork well in
            // classic tag editors. Profile values above are read-only labels.
            Image(systemName: "iphone.gen1")
                .font(.system(size: 65, weight: .ultraLight))
                .foregroundStyle(Color(white: 0.68))
                .shadow(color: .white, radius: 0, y: 1)
                .frame(maxWidth: .infinity).accessibilityHidden(true)
            Text("iPhone 5 camera approximation")
                .font(.custom("Lucida Grande", size: 9))
                .foregroundStyle(.secondary).frame(maxWidth: .infinity)
        }
        .padding(15).frame(width: 226)
        .background(LinearGradient(colors: [Color(white: 0.93), Color(white: 0.88)], startPoint: .top, endPoint: .bottom))
        .overlay(alignment: .trailing) { rule.frame(width: 1) }
    }

    private var columnHeaders: some View {
        HStack(spacing: 0) {
            Text("Filename").padding(.leading, 10).frame(maxWidth: .infinity, alignment: .leading)
            Rectangle().fill(rule).frame(width: 0.5, height: 16)
            Text("Format").padding(.leading, 8).frame(width: 82, alignment: .leading)
            Rectangle().fill(rule).frame(width: 0.5, height: 16)
            Text("Status").padding(.leading, 8).frame(width: 100, alignment: .leading)
        }
        .frame(height: 24)
        .background(LinearGradient(colors: [.white, Color(white: 0.88)], startPoint: .top, endPoint: .bottom))
        .overlay(alignment: .bottom) { rule.frame(height: 0.5) }
    }

    private var fileList: some View {
        VStack(spacing: 0) {
            columnHeaders
            ZStack {
                GeometryReader { geometry in
                    VStack(spacing: 0) {
                        ForEach(0..<Int(geometry.size.height / 23) + 1, id: \.self) { row in
                            (row.isMultiple(of: 2) ? Color.white : Color(red: 0.94, green: 0.955, blue: 0.975))
                                .frame(height: 23)
                        }
                    }
                }.clipped().accessibilityHidden(true)
                if model.busy {
                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            Label(model.filename, systemImage: "film")
                                .lineLimit(1).truncationMode(.middle).padding(.horizontal, 10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text("MOV").padding(.leading, 8).frame(width: 82, alignment: .leading)
                            Text(status).padding(.leading, 8).frame(width: 100, alignment: .leading)
                        }
                        .frame(height: 23).foregroundStyle(.white)
                        .background(LinearGradient(colors: [Color(red: 0.40, green: 0.59, blue: 0.82), Color(red: 0.24, green: 0.44, blue: 0.70)], startPoint: .top, endPoint: .bottom))
                        Spacer()
                    }
                }
                VStack(spacing: 13) {
                    if model.busy {
                        ProgressView().controlSize(.regular)
                        Text(model.saving ? "Saving video…" : "Converting video…").fontWeight(.bold)
                        Text(model.saving ? "Choose a location in the Save dialog." : "Please wait while the video is processed.")
                            .foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "film")
                            .font(.system(size: 35, weight: .regular)).foregroundStyle(Color(white: 0.58))
                            .shadow(color: .white, radius: 0, y: 1).accessibilityHidden(true)
                        Text(targeted ? "Drop video here to convert" : "Drag in your video")
                            .font(.custom("Lucida Grande", size: 15).weight(.bold))
                        Text("Drop a file from Finder, or click Open…")
                            .foregroundStyle(.secondary)
                        Button("Open…", action: model.choose).buttonStyle(UtilityButtonStyle())
                        Text("MOV, MP4 and other video files")
                            .font(.custom("Lucida Grande", size: 10)).foregroundStyle(.secondary)
                    }
                }
                .padding(24)
                .background(Color(white: 0.98).opacity(0.96))
                .overlay(Rectangle().stroke(Color(white: 0.76), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                .padding(20)
            }
        }
        .overlay {
            if targeted && !model.busy {
                Rectangle().strokeBorder(Color(red: 0.30, green: 0.49, blue: 0.75), lineWidth: 3)
                    .allowsHitTesting(false)
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            HStack(spacing: 0) {
                sidebar
                fileList
            }
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
            HStack(spacing: 10) {
                Text(status).frame(width: 75, alignment: .leading)
                Rectangle().fill(rule).frame(width: 0.5, height: 14)
                Text(model.busy ? "1 file" : "0 files")
                Spacer()
                Text("Original files are not modified.").foregroundStyle(.secondary)
            }
            .font(.custom("Lucida Grande", size: 10))
            .padding(.horizontal, 12).frame(height: 25)
            .background(LinearGradient(colors: [Color(white: 0.94), Color(white: 0.84)], startPoint: .top, endPoint: .bottom))
            .overlay(alignment: .top) { rule.frame(height: 0.5) }
        }
        .font(.custom("Lucida Grande", size: 11))
        .frame(minWidth: 760, idealWidth: 850, minHeight: 560, idealHeight: 590)
        .foregroundStyle(ink)
        .background(Color(white: 0.93))
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
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 590),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "iPhone 5 Generator"
        window.appearance = NSAppearance(named: .aqua)
        window.contentMinSize = NSSize(width: 760, height: 560)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ContentView(model: model))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { model.cancel(); model.reset() }
}

// Headless entry point exercises the exact same conversion path as the GUI.
if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--convert" {
    do {
        try Converter().convert(input: URL(fileURLWithPath: CommandLine.arguments[2]),
                                output: URL(fileURLWithPath: CommandLine.arguments[3]))
    } catch {
        FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
        exit(1)
    }
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
