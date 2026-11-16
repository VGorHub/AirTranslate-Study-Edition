import AppKit
import OSLog
import SwiftUI

@main
struct AirTranslateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var session = TranslationSessionStore()
    @State private var menuBarPanelController = MenuBarPanelController()

    init() {
        appDelegate.session = session
    }

    var body: some Scene {
        WindowGroup("AirTranslate", id: AirTranslateWindowID.main) {
            ContentView(session: session)
                .frame(
                    minWidth: AirTranslateDesign.mainWindowMinimumWidth,
                    minHeight: AirTranslateDesign.mainWindowMinimumHeight
                )
                .tint(AirTranslateDesign.Palette.accent)
                .background(MenuBarPanelInstaller(session: session, controller: menuBarPanelController))
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CaptureCommands(session: session)
            CaptionCommands(session: session)
        }

        Window(AppText.floatingCaptionModeChoiceTitle, id: AirTranslateWindowID.floatingCaptionModeChoice) {
            FloatingCaptionModeChoiceView(session: session)
                .windowMinimizeBehavior(.disabled)
        }
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)

        Settings {
            SettingsView(session: session)
                .tint(AirTranslateDesign.Palette.accent)
        }
    }
}

@MainActor
private struct CaptureCommands: Commands {
    @Bindable var session: TranslationSessionStore

    var body: some Commands {
        CommandMenu(AppText.capture) {
            Button(session.captureControlState.phase.actionTitle) {
                if session.isRunning || session.isStarting {
                    session.stop()
                } else {
                    session.start()
                }
            }
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(!session.captureControlState.canToggleCapture)

            Button(session.isPaused ? AppText.resume : AppText.pause) {
                session.isPaused ? session.resume() : session.pause()
            }
            .keyboardShortcut(.space, modifiers: [.command, .shift])
            .disabled(!session.captureControlState.canTogglePause)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var session: TranslationSessionStore?
    private var studyBackend: StudyBackend?
    private var studyServer: Task<Void, Never>?
    private var studyHeartbeat: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        startStudyServices()
        if let appIcon = NSImage(named: "AppIcon") {
            NSApp.applicationIconImage = appIcon
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        session?.prepareForTermination()
        guard let capture = session?.studyCapture else { return .terminateNow }
        studyHeartbeat?.cancel()
        studyServer?.cancel()
        Task { @MainActor in
            await capture.close()
            await studyBackend?.disconnectSubscribers()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    @MainActor
    private func startStudyServices() {
        guard let session else { return }
        let environment = ProcessInfo.processInfo.environment
        let support: URL
        if let directory = environment["AIRTRANSLATE_STUDY_DATA_DIRECTORY"], directory.hasPrefix("/") {
            support = URL(filePath: directory, directoryHint: .isDirectory)
        } else {
            support = URL.applicationSupportDirectory.appending(path: "AirTranslate/Study", directoryHint: .isDirectory)
        }
        let backend = StudyBackend(databaseURL: support.appending(path: "sessions.sqlite3"))
        self.studyBackend = backend
        session.studyCapture = StudyCapture(backend: backend)

        let configuredPort = environment["AIRTRANSLATE_STUDY_PORT"].flatMap(Int.init)
            ?? UserDefaults.standard.integer(forKey: "StudyPort")
        let port = (1...65535).contains(configuredPort) ? configuredPort : 8765
        let server = StudyHTTPServer(port: port, backend: backend) { [weak session] action in
            session?.handleStudyCaptureAction(action) ?? false
        }
        studyServer = Task {
            do {
                try await server.run()
            } catch {
                guard !Task.isCancelled else { return }
                Logger(subsystem: "dev.appcaster.AirTranslate", category: "StudyHTTP")
                    .error("Study server failed on loopback port \(port): \(String(describing: error), privacy: .private)")
            }
        }
        studyHeartbeat = Task {
            await backend.flush()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) }
                catch { break }
                await backend.tick()
            }
        }
    }
}
