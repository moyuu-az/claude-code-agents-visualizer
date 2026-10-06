import AgentsVisualizerCore
import AppKit
import SwiftUI

@main
enum Entry {
    static func main() {
        // Diagnostics for bug reports: prints exactly what the dashboard sees, then exits.
        if CommandLine.arguments.contains("--dump-json") {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            let data = (try? encoder.encode(SnapshotBuilder().build())) ?? Data()
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
            return
        }
        AgentsVisualizerApp.main()
    }
}

struct AgentsVisualizerApp: App {
    // The App value is created once per launch, so a plain stored reference is enough.
    private let model = DashboardModel()

    init() {
        // Polling starts at launch, not when the window appears, so the menu bar stays current with the window closed.
        model.start()
    }

    var body: some Scene {
        Window("Claude Code Agents", id: DashboardView.windowID) {
            DashboardView()
                .environment(model)
        }
        .defaultSize(width: 1200, height: 780)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Refresh") { model.refreshNow() }
                    .keyboardShortcut("r")
            }
        }

        MenuBarExtra {
            MenuBarPanel()
                .environment(model)
        } label: {
            MenuBarLabel(snapshot: model.snapshot)
        }
        .menuBarExtraStyle(.window)
    }
}
