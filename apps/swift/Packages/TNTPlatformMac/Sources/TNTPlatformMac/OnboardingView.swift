// OnboardingView — first-run consent + TCC step UI. Reads its state from
// `OnboardingCoordinator`; visual layout intentionally short so the
// privacy posture reads in under a minute.
//
// Layout:
//   header → ConsentBody sections → step-specific footer (Continue or
//   denial banner with Open Settings + Retry).

import SwiftUI

public struct OnboardingView: View {

    @ObservedObject private var coordinator: OnboardingCoordinator

    public init(coordinator: OnboardingCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                VStack(alignment: .leading, spacing: 18) {
                    ForEach(coordinator.body.sections) { section in
                        sectionRow(section)
                    }
                }

                Divider()

                footer
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
        }
        .frame(width: 560, height: 720)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Welcome to TNT")
                .font(.largeTitle)
                .fontWeight(.semibold)
            Text("Voice-first Personal Master Agent for macOS")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Read the privacy posture below before granting permissions.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
    }

    @ViewBuilder
    private func sectionRow(_ section: ConsentBody.Section) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(section.title)
                .font(.headline)
            Text(section.english)
                .font(.body)
            if let zh = section.mandarin {
                Text(zh)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        switch coordinator.flow.step {
        case .introducingPrivacy:
            HStack {
                Spacer()
                Button("Continue") { coordinator.continueFromIntro() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
        case .requestingMicrophone:
            inFlight(message: "Requesting Microphone permission…")
        case .requestingInputMonitoring:
            inFlight(message: "Requesting Input Monitoring permission…")
        case .microphoneDenied:
            denialBanner(
                title: "Microphone permission required",
                onOpenSettings: coordinator.openMicrophoneSettings,
                onRetry: coordinator.retryMicrophone
            )
        case .inputMonitoringDenied:
            denialBanner(
                title: "Input Monitoring permission required",
                onOpenSettings: coordinator.openInputMonitoringSettings,
                onRetry: coordinator.retryInputMonitoring
            )
        case .readyForApiKey:
            VStack(alignment: .leading, spacing: 6) {
                Text("Next: add your OpenAI API key")
                    .font(.headline)
                Text("S5 will fill this in. The window closes momentarily.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func inFlight(message: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(message).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func denialBanner(
        title: String,
        onOpenSettings: @escaping () -> Void,
        onRetry: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.red)
            Text("TNT cannot continue until this permission is granted in System Settings.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Button("Open Settings", action: onOpenSettings)
                Button("Retry", action: onRetry)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
