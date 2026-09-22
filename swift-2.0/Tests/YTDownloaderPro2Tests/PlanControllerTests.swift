import Combine
import XCTest
@testable import YTDownloaderPro2

@MainActor
final class PlanControllerTests: XCTestCase {
    func testPublicProviderAlwaysProducesEnforcedFree() {
        let controller = PlanController(
            buildChannel: .publicRelease,
            provider: PublicFreePlanProvider()
        )

        XCTAssertEqual(controller.currentPlan, .free)
        XCTAssertEqual(controller.featurePolicyContext.plan, .free)
        XCTAssertTrue(controller.featurePolicyContext.isEnforced)
        XCTAssertFalse(controller.internalSwitchingAvailable)
    }

    func testPublicControllerIgnoresAnInjectedInternalPreference() throws {
        let suiteName = "PlanControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = InternalTestPlanStore(defaults: defaults)
        store.savePlan(.testPro)

        let controller = PlanController(
            buildChannel: .publicRelease,
            provider: InternalTestPlanProvider(store: store)
        )

        XCTAssertEqual(controller.currentPlan, .free)
        XCTAssertEqual(controller.featurePolicyContext.plan, .free)
    }

#if !YTDP_INTERNAL_TEST
    func testDefaultCompilationUsesThePublicBuildChannel() {
        XCTAssertEqual(AppBuildChannel.current, .publicRelease)
    }
#endif

    func testInternalStoreAcceptsOnlyExactKnownStrings() throws {
        let suiteName = "PlanControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = InternalTestPlanStore(defaults: defaults)

        let cases: [(stored: Any?, expected: AppPlan)] = [
            (nil, .free),
            ("free", .free),
            ("test-pro", .testPro),
            (" test-pro", .free),
            ("test-pro ", .free),
            ("TEST-PRO", .free),
            ("unknown", .free),
            (1, .free)
        ]

        for testCase in cases {
            defaults.removeObject(forKey: InternalTestPlanStore.key)
            if let stored = testCase.stored {
                defaults.set(stored, forKey: InternalTestPlanStore.key)
            }
            XCTAssertEqual(store.loadPlan(), testCase.expected, String(describing: testCase.stored))
        }
    }

    func testInternalProviderLoadsOnlyTheStoreResult() throws {
        let suiteName = "PlanControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = InternalTestPlanStore(defaults: defaults)
        let provider = InternalTestPlanProvider(store: store)

        XCTAssertEqual(provider.loadPlan(), .free)

        store.savePlan(.testPro)

        XCTAssertEqual(provider.loadPlan(), .testPro)
        XCTAssertEqual(defaults.object(forKey: InternalTestPlanStore.key) as? String, "test-pro")
    }

#if YTDP_INTERNAL_TEST
    func testInternalCompilationUsesTheInternalBuildChannel() {
        XCTAssertEqual(AppBuildChannel.current, .internalTest)
    }

    func testInternalSelectionPublishesAndPersistsImmediately() throws {
        let suiteName = "PlanControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = PlanController.live(defaults: defaults)
        var received: [AppPlan] = []
        let observation = controller.$currentPlan.sink { received.append($0) }
        defer { observation.cancel() }

        controller.selectInternalPlan(.testPro)

        XCTAssertEqual(controller.currentPlan, .testPro)
        XCTAssertEqual(controller.featurePolicyContext.plan, .pro)
        XCTAssertEqual(received, [.free, .testPro])
        XCTAssertEqual(defaults.object(forKey: InternalTestPlanStore.key) as? String, "test-pro")
    }

    func testResetInternalPlanReturnsToFreeAndPersistsIt() throws {
        let suiteName = "PlanControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = InternalTestPlanStore(defaults: defaults)
        store.savePlan(.testPro)
        let controller = PlanController(
            buildChannel: .internalTest,
            provider: InternalTestPlanProvider(store: store)
        )

        controller.resetInternalPlanToFree()

        XCTAssertEqual(controller.currentPlan, .free)
        XCTAssertEqual(controller.featurePolicyContext.plan, .free)
        XCTAssertEqual(defaults.object(forKey: InternalTestPlanStore.key) as? String, "free")
    }

    func testPublicControllerRefusesInternalMutation() throws {
        let suiteName = "PlanControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = InternalTestPlanStore(defaults: defaults)
        let controller = PlanController(
            buildChannel: .publicRelease,
            provider: PublicFreePlanProvider()
        )

        controller.selectInternalPlan(.testPro)

        XCTAssertEqual(controller.currentPlan, .free)
        XCTAssertNil(defaults.object(forKey: InternalTestPlanStore.key))
        XCTAssertEqual(store.loadPlan(), .free)
    }
#endif
}
