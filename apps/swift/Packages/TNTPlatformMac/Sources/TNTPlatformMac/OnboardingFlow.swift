// OnboardingFlow — pure state machine driving the first-run consent +
// TCC permission + BYOK key sequence. Lives outside `OnboardingHost` so
// the transitions can be exhaustively tested without instantiating an
// `AVCaptureDevice` request, an `NSWindow`, or a network call to OpenAI.
//
// Sequence (per M0/S4 + M0/S5 acceptance):
//   introducingPrivacy → requestingMicrophone → requestingInputMonitoring
//                        ↘ microphoneDenied        ↘ inputMonitoringDenied
//                                                  → connectingOpenAI
//                                                  → completed (terminal)
//
// Retry from a denial step always returns to the corresponding *request*
// step — never silently skips ahead.

import Foundation

public enum OnboardingStep: Sendable, Equatable {
    case introducingPrivacy
    case requestingMicrophone
    case microphoneDenied
    case requestingInputMonitoring
    case inputMonitoringDenied
    /// User has granted both TCC permissions and is now entering /
    /// testing their OpenAI BYOK key.
    case connectingOpenAI
    /// Terminal — onboarding closes, runtime starts.
    case completed
}

public struct OnboardingFlow: Sendable, Equatable {

    public private(set) var step: OnboardingStep

    public init(step: OnboardingStep = .introducingPrivacy) {
        self.step = step
    }

    public var isComplete: Bool { step == .completed }

    @discardableResult
    public mutating func continueFromIntro() -> OnboardingStep {
        step = .requestingMicrophone
        return step
    }

    @discardableResult
    public mutating func microphoneDecision(granted: Bool) -> OnboardingStep {
        step = granted ? .requestingInputMonitoring : .microphoneDenied
        return step
    }

    @discardableResult
    public mutating func retryMicrophone() -> OnboardingStep {
        step = .requestingMicrophone
        return step
    }

    @discardableResult
    public mutating func inputMonitoringDecision(granted: Bool) -> OnboardingStep {
        step = granted ? .connectingOpenAI : .inputMonitoringDenied
        return step
    }

    @discardableResult
    public mutating func retryInputMonitoring() -> OnboardingStep {
        step = .requestingInputMonitoring
        return step
    }

    /// Called once the BYOK key is saved successfully to the Keychain.
    @discardableResult
    public mutating func apiKeySaved() -> OnboardingStep {
        step = .completed
        return step
    }
}
