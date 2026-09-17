import XCTest
@testable import DeployBar

/// The scope menu's account/team nesting.
final class ScopeMenuLabelTests: XCTestCase {

    /// Teams are sub-accounts of the Vercel account listed above them, and the
    /// flat menu read as though they were siblings of it.
    func test_indentsTeamsUnderTheirAccount() {
        XCTAssertEqual(ScopeMenuLabel.text("Vercel CLI", isTeam: false), "Vercel CLI")
        XCTAssertEqual(ScopeMenuLabel.text("flipmiles", isTeam: true), "    flipmiles")
        XCTAssertEqual(ScopeMenuLabel.text("8lines", isTeam: true), "    8lines")
    }

    /// The personal scope is the account itself, so it is never indented — it's
    /// the row every team hangs off.
    func test_personalScopeStaysFlush() {
        let personal = ScopeMenuLabel.text("Vercel CLI", isTeam: false)
        XCTAssertFalse(personal.hasPrefix(" "), "The account row anchors the group")
    }

    func test_indentIsStableWidth() {
        XCTAssertEqual(ScopeMenuLabel.indent.count, 4)
        XCTAssertFalse(ScopeMenuLabel.indent.contains("\t"),
                       "A tab's rendered width is unspecified in a proportional menu font")
    }
}

/// The status tooltip's content.
final class TooltipContentTests: XCTestCase {

    /// The card used to repeat the branch, sha, author and timing that are all
    /// already printed on the row. It now shows only the state's name.
    func test_statusTooltipIsJustTheStateName() {
        XCTAssertEqual(TooltipContent.status(.ready).accessibilityText, DeploymentState.ready.label)
        XCTAssertEqual(TooltipContent.status(.error).accessibilityText, DeploymentState.error.label)
        XCTAssertEqual(TooltipContent.status(.building).accessibilityText, DeploymentState.building.label)
    }

    func test_contentEquatabilityDrivesTheAnimation() {
        // The host animates on `request` changing; identical content must
        // compare equal or every layout pass would re-run the transition.
        XCTAssertEqual(TooltipContent.status(.ready), .status(.ready))
        XCTAssertNotEqual(TooltipContent.status(.ready), .status(.error))
        XCTAssertEqual(TooltipContent.text("Open"), .text("Open"))
        XCTAssertNotEqual(TooltipContent.text("Open"), .text("Close"))
    }

    func test_plainTooltipExposesItsMessage() {
        XCTAssertEqual(TooltipContent.text("Open build logs").accessibilityText, "Open build logs")
    }

    /// Far below AppKit's multi-second dwell, which is what made the system
    /// tooltips impractical in this popover.
    func test_dwellIsShorterThanTheSystemTooltip() {
        XCTAssertLessThan(TooltipMetrics.dwell, 300)
        XCTAssertGreaterThan(TooltipMetrics.dwell, 50,
                             "Too short and sweeping across the icon cluster flashes a bubble per icon")
    }
}

/// Where the bubble lands. The popover is only 380pt wide and its rows sit
/// right up against the edges, so clamping and flipping are the common cases,
/// not the corner cases.
final class TooltipPlacementTests: XCTestCase {

    func test_centersOnItsTarget() {
        let x = TooltipPlacementMath.x(targetMidX: 190, bubbleWidth: 100, containerWidth: 380)
        XCTAssertEqual(x, 140, "A bubble in open space is centered under the target")
    }

    /// The action icons sit at the row's trailing edge, so their tooltips would
    /// hang off the panel without clamping.
    func test_clampsToTheTrailingEdge() {
        let x = TooltipPlacementMath.x(targetMidX: 370, bubbleWidth: 160, containerWidth: 380)
        XCTAssertLessThanOrEqual(x + 160, 380 - TooltipMetrics.margin + 0.001,
                                 "The bubble must stay inside the popover")
        XCTAssertGreaterThanOrEqual(x, TooltipMetrics.margin)
    }

    /// The status badge sits at the row's leading edge — the mirror case.
    func test_clampsToTheLeadingEdge() {
        let x = TooltipPlacementMath.x(targetMidX: 14, bubbleWidth: 160, containerWidth: 380)
        XCTAssertEqual(x, TooltipMetrics.margin)
    }

    /// A bubble wider than the popover can't satisfy both margins; it must still
    /// start on-screen rather than at a negative offset.
    func test_oversizedBubbleStaysOnScreen() {
        let x = TooltipPlacementMath.x(targetMidX: 190, bubbleWidth: 500, containerWidth: 380)
        XCTAssertEqual(x, TooltipMetrics.margin)
    }

    func test_prefersAboveTheTarget() {
        let y = TooltipPlacementMath.y(targetMinY: 200, targetMaxY: 240, bubbleHeight: 60)
        XCTAssertEqual(y, 200 - 60 - TooltipMetrics.gap)
    }

    /// The first row sits directly under the tab bar, leaving no room above.
    func test_flipsBelowWhenItWouldClipTheTop() {
        let y = TooltipPlacementMath.y(targetMinY: 20, targetMaxY: 60, bubbleHeight: 80)
        XCTAssertEqual(y, 60 + TooltipMetrics.gap, "Falls below the target instead of off the top")
        XCTAssertGreaterThan(y, 60)
    }

    func test_neverOverlapsItsTarget() {
        for targetMinY in stride(from: 0.0, through: 400.0, by: 25.0) {
            let maxY = targetMinY + 40
            let y = TooltipPlacementMath.y(targetMinY: targetMinY, targetMaxY: maxY, bubbleHeight: 70)
            let overlapsAbove = y + 70 > targetMinY && y < targetMinY
            XCTAssertFalse(overlapsAbove, "Bubble covered its own target at \(targetMinY)")
        }
    }
}

/// The project title's `owner/project` composition.
///
/// The two providers disagree on what `Project.name` holds, so these rules have
/// to produce one title shape from either without doubling the owner up.
final class ProjectTitleTests: XCTestCase {

    /// Vercel projects carry a bare name; the owner comes from the scope.
    func test_prefixesVercelProjectWithItsScope() {
        XCTAssertEqual(ProjectTitle.owner(scopeLabel: "foka-ventures", project: "reprover"),
                       "foka-ventures")
        XCTAssertEqual(ProjectTitle.leaf("reprover"), "reprover")
    }

    /// GitHub repos already arrive as "owner/repo" — using the scope as well
    /// would render "GitHub CLI/octocat/hello".
    func test_doesNotDoubleUpAnEmbeddedOwner() {
        XCTAssertEqual(ProjectTitle.owner(scopeLabel: "GitHub CLI", project: "octocat/hello"),
                       "octocat", "The name's own owner wins over the scope")
        XCTAssertEqual(ProjectTitle.leaf("octocat/hello"), "hello")
    }

    /// Without a scope there is simply no prefix to draw.
    func test_noOwnerWithoutAScope() {
        XCTAssertNil(ProjectTitle.owner(scopeLabel: nil, project: "reprover"))
        XCTAssertNil(ProjectTitle.owner(scopeLabel: "", project: "reprover"))
        XCTAssertNil(ProjectTitle.owner(scopeLabel: "   ", project: "reprover"))
    }

    /// A team name may still be loading; a blank scope must not render "/name".
    func test_blankScopeNeverRendersABareSlash() {
        let owner = ProjectTitle.owner(scopeLabel: "  ", project: "reprover")
        XCTAssertNil(owner, "A bare '/reprover' would look like a broken path")
    }

    func test_leafStripsOnlyTheFirstSegment() {
        XCTAssertEqual(ProjectTitle.leaf("org/team/project"), "team/project")
        XCTAssertEqual(ProjectTitle.leaf("plain"), "plain")
    }

    /// Degenerate names shouldn't crash or produce an empty title.
    func test_handlesLeadingSlash() {
        XCTAssertNil(ProjectTitle.owner(scopeLabel: nil, project: "/orphan"),
                     "An empty owner segment is not an owner")
        XCTAssertEqual(ProjectTitle.leaf("/orphan"), "orphan")
    }

    /// The scope still wins for a Vercel project whose name merely contains a
    /// slash-free string — the common case must stay stable.
    func test_scopeAppliesToEveryUnqualifiedName() {
        for name in ["reprover", "apollomusic", "social"] {
            XCTAssertEqual(ProjectTitle.owner(scopeLabel: "8lines", project: name), "8lines")
            XCTAssertEqual(ProjectTitle.leaf(name), name)
        }
    }
}
