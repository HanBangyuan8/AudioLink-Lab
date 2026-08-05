import AudioLinkCore
import AppKit
import SwiftUI

@MainActor
private enum AppRuntime {
    static var delegate: AppDelegate?
}

@main
enum AudioLinkLauncher {
    static func main() {
        let runtimePlan = RuntimeFeaturePlan.current
        if runtimePlan.usesSwiftUIAppLifecycle, #available(macOS 13.0, *) {
            NativeAudioLinkApp.main()
        } else {
            MainActor.assumeIsolated {
                let app = NSApplication.shared
                let delegate = AppDelegate()
                AppRuntime.delegate = delegate
                app.delegate = delegate
                app.setActivationPolicy(.regular)
                app.run()
            }
        }
    }
}

@available(macOS 13.0, *)
struct NativeAudioLinkApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            NativeModernContentView()
                .environmentObject(model)
        }
        .defaultSize(
            width: AudioLinkLayoutMetrics.defaultWindowWidth,
            height: AudioLinkLayoutMetrics.defaultWindowHeight
        )
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            MenuBarPanel()
                .environmentObject(model)
        } label: {
            Label(menuBarTitle, systemImage: "waveform.path.ecg")
        }

        Settings {
            NativeModernContentView()
                .environmentObject(model)
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About AudioLink Lab") {
                    AboutPanelPresenter.show()
                }
            }

            CommandGroup(replacing: .appSettings) {
                Button("Preferences...") {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }

    private var menuBarTitle: String {
        let latency = model.stats(for: model.monitoredAudioPathNames).lastLatency
        if let latency {
            return "AudioLink \(latency)ms"
        }
        return "AudioLink --"
    }
}

enum AboutPanelPresenter {
    @MainActor
    static func show() {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? AudioLinkReleaseMetadata.appVersion
        let build = info?["CFBundleVersion"] as? String ?? AudioLinkReleaseMetadata.buildVersion
        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .applicationName: "AudioLink Lab",
            .applicationVersion: version,
            .version: build,
            .credits: NSAttributedString(
                string: "Native audio-path measurement for Apple platforms.\nMeasure delay, jitter, clock drift, and correlation confidence.",
                attributes: [.font: NSFont.systemFont(ofSize: 12)]
            )
        ])
    }
}
