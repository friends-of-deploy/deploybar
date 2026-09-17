import XCTest
import SwiftUI
@testable import DeployBar

/// Reduce Motion support.
///
/// Nothing in the app consulted `accessibilityReduceMotion`: `StatusDot` ran an
/// indefinite `repeatForever` pulse for every building/queued row and
/// `HealthDot`'s ring spun continuously, regardless of the system setting.
/// The motion is now gated — colour and layout still convey the state, so
/// nothing is lost but the movement.
@MainActor
final class ReduceMotionTests: XCTestCase {

    /// The popover's shared timings resolve to no animation when the user has
    /// asked for reduced motion, and to a real one otherwise.
    func test_popoverMotionIsSuppressedUnderReduceMotion() {
        XCTAssertNil(PopoverMotion.tabSwitch(reduceMotion: true))
        XCTAssertNil(PopoverMotion.listUpdate(reduceMotion: true))

        XCTAssertNotNil(PopoverMotion.tabSwitch(reduceMotion: false))
        XCTAssertNotNil(PopoverMotion.listUpdate(reduceMotion: false))
    }

    /// The unreduced values stay the tuned ones, so gating didn't quietly
    /// change the normal-motion feel.
    func test_normalMotionKeepsTunedAnimations() {
        XCTAssertEqual(PopoverMotion.tabSwitch(reduceMotion: false), PopoverMotion.tabSwitch)
        XCTAssertEqual(PopoverMotion.listUpdate(reduceMotion: false), PopoverMotion.listUpdate)
    }

    /// `StatusDot` only pulses for in-flight states, and only when motion is
    /// allowed. The pulse is what Reduce Motion has to switch off; the colour
    /// that distinguishes the state is not.
    func test_statusDotPulsesOnlyForInFlightStatesWithMotionAllowed() {
        for state in [DeploymentState.building, .queued] {
            XCTAssertTrue(StatusDot.shouldPulse(state: state, reduceMotion: false),
                          "\(state) should pulse normally")
            XCTAssertFalse(StatusDot.shouldPulse(state: state, reduceMotion: true),
                           "\(state) must not pulse under Reduce Motion")
        }
        for state in [DeploymentState.ready, .error, .canceled, .unknown] {
            XCTAssertFalse(StatusDot.shouldPulse(state: state, reduceMotion: false),
                           "\(state) is settled and should never pulse")
        }
    }

    /// Reduce Motion must not change which colour a state gets — only whether
    /// it moves.
    func test_stateTintsAreUnaffected() {
        XCTAssertEqual(DeploymentState.ready.tint, .green)
        XCTAssertEqual(DeploymentState.building.tint, .orange)
        XCTAssertEqual(DeploymentState.error.tint, .red)
    }
}
