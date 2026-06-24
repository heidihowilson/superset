import XCTest
@testable import Superset

/// Coverage for the create sheet's branch-slug default (issue #95). When the branch field is
/// left blank, `submit()` derives the branch from the workspace name via `branchSlug(from:)`:
/// lowercase, collapse runs of disallowed characters to a single hyphen, keep `. _ /`, and trim
/// leading/trailing separators. Its sibling `resolveSelection` is tested; the run-collapsing and
/// trim edges here were not.
final class WorkspaceCreateBranchSlugTests: XCTestCase {
    /// The canonical case: a spaced, mixed-case name becomes a lowercase hyphenated slug.
    func testSpacedNameLowercasesAndHyphenates() {
        XCTAssertEqual(WorkspaceCreateView.branchSlug(from: "My Feature"), "my-feature")
    }

    /// Runs of disallowed characters (repeated spaces and symbols) collapse to a single hyphen
    /// rather than producing empty `--` segments.
    func testDisallowedRunsCollapseToSingleHyphen() {
        XCTAssertEqual(WorkspaceCreateView.branchSlug(from: "a   b"), "a-b")
        XCTAssertEqual(WorkspaceCreateView.branchSlug(from: "a!@#b"), "a-b")
        XCTAssertEqual(WorkspaceCreateView.branchSlug(from: "My   Cool!!!Feature"), "my-cool-feature")
    }

    /// The git-safe characters `.`, `_`, and `/` are allowed and survive verbatim (not collapsed).
    func testPreservesAllowedPunctuation() {
        XCTAssertEqual(
            WorkspaceCreateView.branchSlug(from: "feature.foo_bar/baz"),
            "feature.foo_bar/baz"
        )
    }

    /// Leading/trailing separators are trimmed: disallowed-symbol edges never seed a dangling
    /// hyphen, and leading/trailing allowed separators (`. _ /`) are stripped.
    func testTrimsLeadingAndTrailingSeparators() {
        XCTAssertEqual(WorkspaceCreateView.branchSlug(from: "!!!start"), "start")
        XCTAssertEqual(WorkspaceCreateView.branchSlug(from: "end!!!"), "end")
        XCTAssertEqual(WorkspaceCreateView.branchSlug(from: "_private.path_"), "private.path")
        XCTAssertEqual(WorkspaceCreateView.branchSlug(from: "/leading.trailing/"), "leading.trailing")
    }

    /// An input with no allowed characters yields an empty slug, so `submit()` falls through to
    /// the Host's own branch default instead of dialing a hyphen-only branch.
    func testAllSeparatorInputYieldsEmpty() {
        XCTAssertEqual(WorkspaceCreateView.branchSlug(from: "!@#$%"), "")
        XCTAssertEqual(WorkspaceCreateView.branchSlug(from: "..."), "")
        XCTAssertEqual(WorkspaceCreateView.branchSlug(from: ""), "")
    }
}
