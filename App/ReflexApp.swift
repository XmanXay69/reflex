import AppKit
import ReflexCamera
import SwiftUI

@main
struct ReflexApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Reflex", id: "main") {
            ContentView(model: delegate.model)
                .frame(minWidth: 720, minHeight: 440)
        }
        .defaultSize(width: 1180, height: 720)
        .commands { ReflexCommands(model: delegate.model) }

        Window("Measure Latency", id: "latency") {
            LatencyTestView(model: delegate.model)
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView(model: delegate.model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Give the camera a moment to leave live view and get its original settings back.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = model
        Task {
            // Whichever finishes first: a clean camera shutdown, or a 3-second cap.
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await model.shutdown() }
                group.addTask { try? await Task.sleep(for: .seconds(3)) }
                await group.next()
                group.cancelAll()
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

struct ReflexCommands: Commands {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button(model.showPanel ? "Hide Controls" : "Show Controls") {
                withAnimation(.snappy(duration: 0.25)) { model.showPanel.toggle() }
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
        }
        CommandMenu("Camera") {
            Button(model.liveViewEnabled ? "Stop Live View" : "Start Live View") { model.toggleLiveView() }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(model.phase != .connected)
            Divider()
            Picker("Aspect Ratio", selection: $model.aspect) {
                ForEach(OutputAspect.allCases) { Text($0.label).tag($0) }
            }
            Picker("Live View Quality", selection: $model.quality) {
                ForEach(LiveViewQuality.allCases) { Text($0.label).tag($0) }
            }
            Button("Autofocus") { model.autofocus() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(!model.receivingFrames || model.isFocusing)
            Button("Quick Setup") { model.quickSetup() }
                .disabled(model.controls.isEmpty)
            Button("Save Frame") {
                if let url = model.saveFrame() { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(!model.receivingFrames)
            Divider()
            Button("Measure Latency…") { openWindow(id: "latency") }
                .keyboardShortcut("l", modifiers: [.command, .shift])
        }
    }
}
