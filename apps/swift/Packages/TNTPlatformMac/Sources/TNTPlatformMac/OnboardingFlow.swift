// OnboardingFlow — pure state machine driving the first-run consent +
// TCC permission sequence. Lives outside `OnboardingHost` so the
// transitions can be exhaustively tested without instantiating an
// AVCaptureDevice request or an AppKit window.
//
// Sequence (per M0/S4 acceptance):
//   introducingPrivacy → requestingMicrophone → requestingInputMonitoring
//                        ↘ microphoneDenied        ↘ inputMonitoringDenied
//                                                  → readyForApiKey (terminal)
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
    case readyForApiKey
}

public struct OnboardingFlow: Sendable, Equatable {

    public private(set) var step: OnboardingStep

    public init(step: OnboardingStep = .introducingPrivacy) {
        self.step = step
    }

    public var isComplete: Bool { step == .readyForApiKey }

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
        step = granted ? .readyForApiKey : .inputMonitoringDenied
        return step
    }

    @discardableResult
    public mutating func retryInputMonitoring() -> OnboardingStep {
        step = .requestingInputMonitoring
        return step
    }
}
