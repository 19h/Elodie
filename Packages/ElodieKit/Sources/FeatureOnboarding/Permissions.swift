import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import Observation

/// A permission Elodie can ask for.
public enum Permission: String, CaseIterable, Identifiable, Sendable {
    case screenRecording
    case accessibility
    case microphone

    public var id: String { rawValue }

    public var isRequired: Bool {
        self != .microphone
    }

    /// The settings page, if someone has said no, since nothing else can change that.
    public var settingsURLIfDenied: URL? {
        guard self == .microphone, AVCaptureDevice.authorizationStatus(for: .audio) == .denied else { return nil }
        return settingsURL
    }

    /// The page for this in System Settings.
    public var settingsURL: URL {
        let anchor = switch self {
        case .screenRecording: "Privacy_ScreenCapture"
        case .accessibility: "Privacy_Accessibility"
        case .microphone: "Privacy_Microphone"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }
}

/// Tracks which permissions are granted, updating on its own while it's being watched.
@MainActor
@Observable
public final class PermissionMonitor {
    public private(set) var granted: Set<Permission> = []
    /// Screen Recording has been switched on, but this process can't use it until it
    /// restarts. macOS only applies that grant to new processes.
    public private(set) var needsRelaunch = false

    private var timer: Timer?
    private let checkScreenAccess: () async -> Bool
    private var isCheckingFreshProcess = false
    @ObservationIgnored nonisolated(unsafe) private let defaults: UserDefaults

    /// Remembered across launches, because the system's prompt only ever appears once.
    private var hasAskedForScreenRecording: Bool {
        get { defaults.bool(forKey: "hasAskedForScreenRecording") }
        set { defaults.set(newValue, forKey: "hasAskedForScreenRecording") }
    }

    private var hasAskedForAccessibility: Bool {
        get { defaults.bool(forKey: "hasAskedForAccessibility") }
        set { defaults.set(newValue, forKey: "hasAskedForAccessibility") }
    }

    /// - Parameter checkScreenAccess: replaces how a fresh process is asked, for tests.
    public init(defaults: UserDefaults = .standard, checkScreenAccess: (() async -> Bool)? = nil) {
        self.defaults = defaults
        self.checkScreenAccess = checkScreenAccess ?? Self.askFreshProcess
        refresh()
    }

    public var allRequiredGranted: Bool {
        Permission.allCases.filter(\.isRequired).allSatisfy(granted.contains)
    }

    public func startWatching() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    public func stopWatching() {
        timer?.invalidate()
        timer = nil
    }

    public func refresh() {
        var now = Set<Permission>()
        if CGPreflightScreenCaptureAccess() { now.insert(.screenRecording) }
        if AXIsProcessTrusted() { now.insert(.accessibility) }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized { now.insert(.microphone) }
        if now != granted { granted = now }

        // This process's own check can stay false after the grant, so ask a new one. That
        // starts a process, so it's only done after someone has been asked, and one at a time.
        if !now.contains(.screenRecording) {
            guard hasAskedForScreenRecording, !isCheckingFreshProcess else { return }
            isCheckingFreshProcess = true
            Task { [weak self] in
                guard let self else { return }
                let fresh = await self.checkScreenAccess()
                self.isCheckingFreshProcess = false
                if fresh != self.needsRelaunch { self.needsRelaunch = fresh }
            }
        } else if needsRelaunch {
            needsRelaunch = false
        }
    }

    /// Asks for a permission the way macOS expects for each.
    public func request(_ permission: Permission) {
        switch permission {
        case .screenRecording:
            // The first ask shows the system's prompt, which offers the settings page itself.
            // After that macOS stays silent, so the page has to be opened directly.
            if hasAskedForScreenRecording {
                NSWorkspace.shared.open(permission.settingsURL)
            } else {
                hasAskedForScreenRecording = true
                _ = CGRequestScreenCaptureAccess()
            }
        case .accessibility:
            if hasAskedForAccessibility {
                NSWorkspace.shared.open(permission.settingsURL)
            } else {
                hasAskedForAccessibility = true
                _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            }
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .audio) { _ in }
            default:
                NSWorkspace.shared.open(permission.settingsURL)
            }
        }
        refresh()
    }

    /// The flag a new process is launched with to report its Screen Recording access.
    public nonisolated static let checkArgument = "--check-screen-access"

    private static func askFreshProcess() async -> Bool {
        guard let executable = Bundle.main.executableURL else { return false }
        return await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = executable
            process.arguments = [checkArgument]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return false }
            process.waitUntilExit()
            return process.terminationStatus == 0
        }.value
    }
}
