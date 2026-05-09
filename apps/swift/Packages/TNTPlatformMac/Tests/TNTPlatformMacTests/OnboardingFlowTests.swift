import XCTest
@testable import TNTPlatformMac

/// State machine for the first-run onboarding flow.
final class OnboardingFlowTests: XCTestCase {

    func testFlowStartsAtIntroducingPrivacy() {
        let flow = OnboardingFlow()
        XCTAssertEqual(flow.step, .introducingPrivacy)
    }

    func testContinueFromIntroAdvancesToMicrophone() {
        var flow = OnboardingFlow()
        XCTAssertEqual(flow.continueFromIntro(), .requestingMicrophone)
        XCTAssertEqual(flow.step, .requestingMicrophone)
    }

    func testMicrophoneGrantedAdvancesToInputMonitoring() {
        var flow = OnboardingFlow()
        _ = flow.continueFromIntro()
        XCTAssertEqual(flow.microphoneDecision(granted: true), .requestingInputMonitoring)
    }

    func testMicrophoneDeniedHaltsOnDenialBanner() {
        var flow = OnboardingFlow()
        _ = flow.continueFromIntro()
        XCTAssertEqual(flow.microphoneDecision(granted: false), .microphoneDenied)
    }

    func testRetryMicrophoneRequestsAgain() {
        var flow = OnboardingFlow()
        _ = flow.continueFromIntro()
        _ = flow.microphoneDecision(granted: false)
        XCTAssertEqual(flow.retryMicrophone(), .requestingMicrophone)
    }

    func testInputMonitoringGrantedCompletesFlow() {
        var flow = OnboardingFlow()
        _ = flow.continueFromIntro()
        _ = flow.microphoneDecision(granted: true)
        XCTAssertEqual(flow.inputMonitoringDecision(granted: true), .connectingOpenAI)
    }

    func testInputMonitoringDeniedHaltsOnDenialBanner() {
        var flow = OnboardingFlow()
        _ = flow.continueFromIntro()
        _ = flow.microphoneDecision(granted: true)
        XCTAssertEqual(flow.inputMonitoringDecision(granted: false), .inputMonitoringDenied)
    }

    func testRetryInputMonitoringRequestsAgain() {
        var flow = OnboardingFlow()
        _ = flow.continueFromIntro()
        _ = flow.microphoneDecision(granted: true)
        _ = flow.inputMonitoringDecision(granted: false)
        XCTAssertEqual(flow.retryInputMonitoring(), .requestingInputMonitoring)
    }

    func testRetryAfterMicrophoneDenialDoesNotSkipToInputMonitoring() {
        var flow = OnboardingFlow()
        _ = flow.continueFromIntro()
        _ = flow.microphoneDecision(granted: false)
        // Retry must re-request microphone, not silently advance.
        XCTAssertEqual(flow.retryMicrophone(), .requestingMicrophone)
        XCTAssertNotEqual(flow.step, .requestingInputMonitoring)
    }

    func testInputMonitoringGrantedAdvancesToConnectingOpenAI() {
        var flow = OnboardingFlow()
        _ = flow.continueFromIntro()
        _ = flow.microphoneDecision(granted: true)
        _ = flow.inputMonitoringDecision(granted: true)
        XCTAssertEqual(flow.step, .connectingOpenAI)
        XCTAssertFalse(flow.isComplete, "Connecting OpenAI is not yet complete — the BYOK key must be saved first.")
    }

    func testApiKeySavedReachesTerminalCompleted() {
        var flow = OnboardingFlow()
        _ = flow.continueFromIntro()
        _ = flow.microphoneDecision(granted: true)
        _ = flow.inputMonitoringDecision(granted: true)
        XCTAssertEqual(flow.apiKeySaved(), .completed)
        XCTAssertTrue(flow.isComplete)
    }
}
