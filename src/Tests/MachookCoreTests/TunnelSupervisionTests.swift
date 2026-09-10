import XCTest
@testable import MachookCore

/// Covers the decisions `TunnelManager` makes about a tunnel it cannot see
/// directly: is the published URL actually serving, is a line of child output
/// worth persisting, and which stray processes are ours to clean up.
final class TunnelSupervisionTests: XCTestCase {

    // MARK: - Probe classification

    func testProbeSuccessIsReachable() {
        XCTAssertEqual(
            TunnelManager.classifyProbe(statusCode: 200, error: nil),
            .reachable
        )
    }

    /// The failure that started all of this: cloudflared prints a hostname,
    /// Cloudflare never publishes the DNS record, and every other signal says
    /// the tunnel is healthy. The message has to name DNS, or the user has no
    /// way to tell it apart from a local problem.
    func testDNSFailureNamesDNS() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost)
        guard case .unreachable(let why) = TunnelManager.classifyProbe(statusCode: nil, error: error) else {
            return XCTFail("expected unreachable")
        }
        XCTAssertTrue(why.lowercased().contains("dns"), "expected DNS to be named, got: \(why)")
    }

    func testDNSLookupFailedAlsoNamesDNS() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorDNSLookupFailed)
        guard case .unreachable(let why) = TunnelManager.classifyProbe(statusCode: nil, error: error) else {
            return XCTFail("expected unreachable")
        }
        XCTAssertTrue(why.lowercased().contains("dns"))
    }

    /// 530 is what Cloudflare's edge serves for error 1033 — DNS resolved, but
    /// no connector is registered. That is a different fix from a missing DNS
    /// record, so it must read differently.
    func testEdgeWithNoConnectorIsDistinctFromDNS() {
        guard case .unreachable(let why) = TunnelManager.classifyProbe(statusCode: 530, error: nil) else {
            return XCTFail("expected unreachable")
        }
        XCTAssertTrue(why.contains("1033"))
        XCTAssertFalse(why.lowercased().contains("dns"))
    }

    /// A 502 means the tunnel works and our own listener didn't answer, which
    /// points at the local side rather than at Cloudflare.
    func testBadGatewayBlamesTheLocalSide() {
        guard case .unreachable(let why) = TunnelManager.classifyProbe(statusCode: 502, error: nil) else {
            return XCTFail("expected unreachable")
        }
        XCTAssertTrue(why.contains("locally"), "expected the local origin to be implicated, got: \(why)")
    }

    func testOfflineMachineIsReportedAsSuch() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        XCTAssertEqual(
            TunnelManager.classifyProbe(statusCode: nil, error: error),
            .unreachable("this Mac is offline")
        )
    }

    func testNoStatusAndNoErrorStillProducesAVerdict() {
        guard case .unreachable = TunnelManager.classifyProbe(statusCode: nil, error: nil) else {
            return XCTFail("a probe with no outcome must not read as reachable")
        }
    }

    func testUnexpectedStatusIsReportedVerbatim() {
        guard case .unreachable(let why) = TunnelManager.classifyProbe(statusCode: 418, error: nil) else {
            return XCTFail("expected unreachable")
        }
        XCTAssertTrue(why.contains("418"))
    }

    // MARK: - Telling the two DNS failures apart

    /// These two need opposite actions from the user and look identical from
    /// here: the record does not exist yet (wait, or restart the tunnel), or
    /// it exists and this Mac cannot see it — a stale negative entry in
    /// `mDNSResponder` after the early failures, or a filtering resolver.
    func testARecordFoundPubliclyBlamesTheLocalResolver() {
        guard case .unreachable(let why) = TunnelManager.dnsVerdict(publiclyResolves: true) else {
            return XCTFail("expected unreachable")
        }
        XCTAssertTrue(why.contains("this Mac"), why)
        XCTAssertFalse(why.lowercased().contains("cloudflare"), "must not blame Cloudflare: \(why)")
    }

    func testNoRecordAnywhereSaysItIsNotPublishedYet() {
        guard case .unreachable(let why) = TunnelManager.dnsVerdict(publiclyResolves: false) else {
            return XCTFail("expected unreachable")
        }
        XCTAssertTrue(why.contains("not published"), why)
    }

    /// Not being able to ask is not evidence either way, so the message must
    /// describe the symptom without naming a culprit.
    func testUnansweredCrossCheckClaimsNothing() {
        guard case .unreachable(let why) = TunnelManager.dnsVerdict(publiclyResolves: nil) else {
            return XCTFail("expected unreachable")
        }
        XCTAssertTrue(why.contains("does not resolve"), why)
        XCTAssertFalse(why.contains("not published"), "no verdict was available: \(why)")
    }

    func testDoHAnswerWithAnAddressRecordCountsAsResolving() {
        let json = #"{"Status":0,"Answer":[{"name":"x.trycloudflare.com","type":1,"TTL":300,"data":"104.16.231.132"}]}"#
        XCTAssertEqual(TunnelManager.parseDoHAnswer(Data(json.utf8)), true)
    }

    func testDoHCNAMEChainCountsAsResolving() {
        let json = #"{"Status":0,"Answer":[{"name":"hooks.example.com","type":5,"data":"tunnel.cfargotunnel.com."}]}"#
        XCTAssertEqual(TunnelManager.parseDoHAnswer(Data(json.utf8)), true)
    }

    func testDoHNXDOMAINIsAnAuthoritativeNo() {
        XCTAssertEqual(TunnelManager.parseDoHAnswer(Data(#"{"Status":3}"#.utf8)), false)
    }

    /// NOERROR with no address record is still "the name has nothing to
    /// connect to", which is a no.
    func testDoHNoErrorWithoutAnAddressIsANo() {
        let json = #"{"Status":0,"Answer":[{"name":"x.com","type":16,"data":"some txt"}]}"#
        XCTAssertEqual(TunnelManager.parseDoHAnswer(Data(json.utf8)), false)
    }

    /// SERVFAIL and friends are the resolver failing, not evidence about the
    /// record — reporting them as either answer would be a guess.
    func testDoHServerFailureYieldsNoVerdict() {
        XCTAssertNil(TunnelManager.parseDoHAnswer(Data(#"{"Status":2}"#.utf8)))
        XCTAssertNil(TunnelManager.parseDoHAnswer(Data("not json".utf8)))
        XCTAssertNil(TunnelManager.parseDoHAnswer(Data(#"{"Answer":[]}"#.utf8)))
    }

    /// Only a DNS-flavoured failure gets the cross-check; a 530 or a timeout
    /// already knows what it is and must pass through untouched.
    func testRefineLeavesNonDNSFailuresAlone() async {
        let edge = TunnelStatus.Reachability.unreachable("Cloudflare has no connector for this hostname (1033)")
        let refined = await TunnelManager.refine(edge, host: "example.trycloudflare.com")
        XCTAssertEqual(refined, edge)

        let reachable = await TunnelManager.refine(.reachable, host: "example.trycloudflare.com")
        XCTAssertEqual(reachable, .reachable)
    }

    func testRefineWithoutAHostCannotCrossCheck() async {
        let dns = TunnelStatus.Reachability.unreachable("DNS: hostname does not resolve from this Mac")
        let refined = await TunnelManager.refine(dns, host: nil)
        XCTAssertEqual(refined, dns)
    }

    // MARK: - Reachability presentation

    func testMenuNoteIsSilentWhenThereIsNothingToSay() {
        XCTAssertNil(TunnelStatus.Reachability.reachable.menuNote)
        XCTAssertNil(TunnelStatus.Reachability.unknown.menuNote)
    }

    func testMenuNoteExplainsCheckingAndFailure() {
        XCTAssertEqual(TunnelStatus.Reachability.checking.menuNote, "verifying…")
        XCTAssertEqual(TunnelStatus.Reachability.unreachable("nope").menuNote, "nope")
    }

    // MARK: - cloudflared output levels

    /// Debug-level records are dropped by a default `log show`, so anything
    /// describing a failure has to be promoted or it effectively vanishes.
    func testErrorLinesArePromoted() {
        XCTAssertEqual(
            TunnelManager.logLevel(forCloudflaredLine: "2026-09-10T12:46:08Z ERR Connection terminated connIndex=0"),
            .error
        )
        XCTAssertEqual(
            TunnelManager.logLevel(forCloudflaredLine: "Provided Tunnel token is not valid."),
            .error
        )
        XCTAssertEqual(
            TunnelManager.logLevel(forCloudflaredLine: "2026-09-10T12:46:08Z WRN retrying in 1s"),
            .notice
        )
    }

    func testRoutineChatterStaysAtDebug() {
        XCTAssertEqual(
            TunnelManager.logLevel(forCloudflaredLine: "2026-09-10T12:45:51Z INF Registered tunnel connection connIndex=0"),
            .debug
        )
        XCTAssertEqual(
            TunnelManager.logLevel(forCloudflaredLine: "2026-09-10T12:45:50Z INF GOOS: darwin, GOVersion: go1.26.2"),
            .debug
        )
    }

    func testConnectionLossIsAtLeastNoticed() {
        XCTAssertEqual(
            TunnelManager.logLevel(forCloudflaredLine: "INF Unregistered tunnel connection connIndex=1"),
            .notice
        )
    }

    // MARK: - Restart bookkeeping

    /// The live bug this guards against: Restart tunnel killed one cloudflared
    /// and started another, the dead child's termination handler landed after
    /// the replacement was up, and its unconditional cleanup set `isRunning`
    /// back to false. The probe loop checks `isRunning` before each attempt,
    /// so it silently abandoned a working tunnel and left "verifying…" in the
    /// menu forever.
    func testOnlyTheNewestSpawnCanTouchSharedState() {
        let manager = TunnelManager()
        let first = manager.nextGeneration()
        XCTAssertTrue(manager.isCurrent(first))

        let second = manager.nextGeneration()
        XCTAssertFalse(manager.isCurrent(first), "a superseded child must not be able to act")
        XCTAssertTrue(manager.isCurrent(second))
    }

    func testGenerationsNeverRepeat() {
        let manager = TunnelManager()
        let seen = (0..<50).map { _ in manager.nextGeneration() }
        XCTAssertEqual(Set(seen).count, seen.count)
    }

    // MARK: - Stray process reaping

    private let ours = "/Applications/Machook.app/Contents/Resources/cloudflared"

    func testFindsOurOrphanedChild() {
        let ps = """
        39346 \(ours) tunnel --no-autoupdate --url http://localhost:7876
        """
        XCTAssertEqual(
            TunnelManager.strayPIDs(psOutput: ps, executablePath: ours, excluding: []),
            [39346]
        )
    }

    /// The important negative case. A dev build resolves cloudflared from
    /// Homebrew, a path shared with every other tunnel on the machine —
    /// including the user's own unrelated ones. Reaping by a path we did not
    /// launch would kill somebody else's production tunnel.
    func testNeverTouchesOtherPeoplesTunnels() {
        let ps = """
        4832 /opt/homebrew/bin/cloudflared tunnel --config /Users/ran/.config/linger/tunnel-config.yml run
        15272 /Applications/iMessage Relay.app/Contents/Resources/cloudflared tunnel run --token abc
        39346 \(ours) tunnel --no-autoupdate --url http://localhost:7876
        """
        XCTAssertEqual(
            TunnelManager.strayPIDs(psOutput: ps, executablePath: ours, excluding: []),
            [39346]
        )
    }

    func testExcludesTheChildWeAreSupervising() {
        let ps = """
        39346 \(ours) tunnel --no-autoupdate --url http://localhost:7876
        86054 \(ours) tunnel --no-autoupdate --url http://localhost:7876
        """
        XCTAssertEqual(
            TunnelManager.strayPIDs(psOutput: ps, executablePath: ours, excluding: [86054]),
            [39346]
        )
    }

    /// A path we launch must not match a longer path that merely starts with
    /// it, e.g. a second bundle called `Machook.app.backup`.
    func testDoesNotMatchOnAPathPrefix() {
        let ps = """
        111 \(ours)-old tunnel --url http://localhost:7876
        222 \(ours)x tunnel --url http://localhost:7876
        """
        XCTAssertEqual(
            TunnelManager.strayPIDs(psOutput: ps, executablePath: ours, excluding: []),
            []
        )
    }

    func testToleratesPaddingAndJunkLines() {
        let ps = """
          39346   \(ours) tunnel --url http://localhost:7876

        not-a-pid \(ours) tunnel
        """
        XCTAssertEqual(
            TunnelManager.strayPIDs(psOutput: ps, executablePath: ours, excluding: []),
            [39346]
        )
    }

    /// The matcher compares absolute paths, so the path we launch has to be
    /// absolute no matter how the app itself was launched. A dev build started
    /// as `./Machook.app/…` otherwise spawns children `ps` reports relatively,
    /// and its own strays become unmatchable.
    func testRelativePathsAreResolvedBeforeLaunch() {
        let cwd = FileManager.default.currentDirectoryPath
        XCTAssertEqual(
            TunnelManager.absolutePath("./Machook.app/Contents/Resources/cloudflared"),
            cwd + "/Machook.app/Contents/Resources/cloudflared"
        )
    }

    func testAbsolutePathsAreLeftAloneApartFromTidying() {
        XCTAssertEqual(TunnelManager.absolutePath(ours), ours)
        XCTAssertEqual(
            TunnelManager.absolutePath("/Applications/./Machook.app/Contents/Resources/cloudflared"),
            "/Applications/Machook.app/Contents/Resources/cloudflared"
        )
    }

    func testBareInvocationWithNoArgumentsStillCounts() {
        XCTAssertEqual(
            TunnelManager.strayPIDs(psOutput: "500 \(ours)", executablePath: ours, excluding: []),
            [500]
        )
    }
}
