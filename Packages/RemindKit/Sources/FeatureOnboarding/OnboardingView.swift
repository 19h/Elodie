import DesignSystem
import SwiftUI

/// The steps of first run.
public enum OnboardingStep: String, Sendable {
    case welcome
    case howItWorks
    case permissions
}

/// First run: what Remind is, how it works, and the permissions it needs.
public struct OnboardingView: View {
    @Bindable private var permissions: PermissionMonitor
    @State private var step: OnboardingStep
    private let appIcon: NSImage?
    private let onStepChange: (OnboardingStep) -> Void
    private let onRelaunch: () -> Void
    private let onFinish: () -> Void

    public init(
        permissions: PermissionMonitor,
        step: OnboardingStep = .welcome,
        appIcon: NSImage?,
        onStepChange: @escaping (OnboardingStep) -> Void = { _ in },
        onRelaunch: @escaping () -> Void,
        onFinish: @escaping () -> Void
    ) {
        self.permissions = permissions
        _step = State(initialValue: step)
        self.appIcon = appIcon
        self.onStepChange = onStepChange
        self.onRelaunch = onRelaunch
        self.onFinish = onFinish
    }

    public var body: some View {
        ZStack {
            switch step {
            case .welcome: welcome
            case .howItWorks: howItWorks
            case .permissions: permissionsStep
            }
        }
        .frame(width: 800, height: 628)
        .tint(Palette.verdigris)
        .onChange(of: step) { _, new in onStepChange(new) }
        .onAppear { permissions.startWatching() }
        .onDisappear { permissions.stopWatching() }
    }

    private func go(to next: OnboardingStep) {
        withAnimation(.smooth(duration: 0.25)) { step = next }
    }

    // MARK: Welcome

    private var welcome: some View {
        VStack(spacing: 0) {
            Spacer()
            if let appIcon {
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: 160, height: 160)
                    .shadow(color: .black.opacity(0.25), radius: 24, y: 14)
            }
            Text("Remind")
                .font(.system(size: 34, weight: .bold))
                .padding(.top, 36)
            Text("Find anything you've seen on your screen.")
                .font(.system(size: 22, weight: .regular, design: .serif))
                .foregroundStyle(.secondary)
                .padding(.top, 8)
            Spacer()
            primaryButton("Get started") { go(to: .howItWorks) }
                .padding(.bottom, 74)
        }
    }

    // MARK: How it works

    private var howItWorks: some View {
        VStack(spacing: 0) {
            Spacer()
            Text("How it works")
                .font(.system(size: 26, weight: .bold))
                .padding(.bottom, 40)
            VStack(alignment: .leading, spacing: 32) {
                explanation(
                    symbol: "rectangle.dashed.badge.record",
                    text: "Remind records your screen in the background and reads the words on it."
                )
                explanation(
                    symbol: "lock.doc",
                    text: "Recordings are compressed and encrypted, and they stay on this Mac."
                )
                explanation(
                    symbol: "magnifyingglass",
                    text: "To find something, search for a word you remember seeing, or scroll back to that moment."
                )
            }
            .frame(width: 520)
            Spacer()
            primaryButton("Continue") { go(to: .permissions) }
                .padding(.bottom, 62)
        }
    }

    private func explanation(symbol: String, text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 24) {
            Image(systemName: symbol)
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
                .frame(width: 42)
            Text(text)
                .font(.system(size: 17))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Permissions

    private var permissionsStep: some View {
        VStack(spacing: 0) {
            Text("Remind needs your permission to work")
                .font(.system(size: 24, weight: .bold))
                .padding(.top, 44)
            Text("Recordings stay on this Mac, and nothing is uploaded.")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .padding(.top, 8)

            VStack(alignment: .leading, spacing: 26) {
                row(
                    .screenRecording,
                    symbol: "rectangle.dashed.badge.record",
                    title: "Screen Recording",
                    detail: "Takes a picture of your screen every few seconds, which is how Remind can search what you've seen."
                )
                row(
                    .accessibility,
                    symbol: "accessibility",
                    title: "Accessibility",
                    detail: "Reads the name of the front window and the current web address, and spots private browser windows."
                )
                row(
                    .microphone,
                    symbol: "mic",
                    title: "Microphone",
                    detail: "Records and transcribes meetings you choose to record."
                )
            }
            .padding(.top, 34)
            .padding(.horizontal, 56)

            Spacer()

            if permissions.needsRelaunch {
                relaunchNotice
            } else {
                Text("macOS asks you to confirm screen recording from time to time. If recording pauses, Remind tells you.")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 90)
            }

            primaryButton("Continue", isEnabled: permissions.allRequiredGranted, action: onFinish)
                .padding(.top, 18)
                .padding(.bottom, 44)
        }
    }

    private var relaunchNotice: some View {
        HStack(spacing: 12) {
            Text("Screen Recording is on. Remind needs to reopen to use it.")
                .font(.system(size: 13))
            Button("Reopen", action: onRelaunch)
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
        }
    }

    private func row(
        _ permission: Permission,
        symbol: String,
        title: LocalizedStringKey,
        detail: LocalizedStringKey
    ) -> some View {
        HStack(alignment: .top, spacing: 18) {
            Image(systemName: symbol)
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(title).font(.system(size: 17, weight: .semibold))
                    if !permission.isRequired {
                        Text("Optional")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(detail)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 24)
            if permissions.granted.contains(permission) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.green)
                    .frame(width: 96)
                    .transition(.scale.combined(with: .opacity))
            } else {
                Button("Allow") { permissions.request(permission) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(width: 96)
            }
        }
        .animation(.smooth(duration: 0.2), value: permissions.granted)
    }

    private func primaryButton(
        _ title: LocalizedStringKey,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 180, height: 44)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.extraLarge)
        .buttonBorderShape(.capsule)
        .disabled(!isEnabled)
        .keyboardShortcut(.defaultAction)
    }
}
