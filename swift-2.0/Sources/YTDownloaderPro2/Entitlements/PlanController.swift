import Combine
import Foundation

@MainActor
final class PlanController: ObservableObject {
    @Published private(set) var currentPlan: AppPlan

    let buildChannel: AppBuildChannel
    private let internalStore: InternalTestPlanStore?
    private var internalOverride: AppPlan
    private var serverSnapshot: EntitlementSnapshot?

    var featurePolicyContext: FeaturePolicyContext {
        .enforced(FeaturePolicy(snapshot: effectiveState.snapshot))
    }

    var internalSwitchingAvailable: Bool {
        buildChannel == .internalTest
    }

    init(buildChannel: AppBuildChannel, provider: any PlanProviding) {
        self.buildChannel = buildChannel
        if buildChannel == .internalTest {
            internalStore = (provider as? InternalTestPlanProvider)?.store
            internalOverride = provider.loadPlan()
        } else {
            internalStore = nil
            internalOverride = .free
        }
        serverSnapshot = nil
        currentPlan = internalOverride == .testPro ? .testPro : .free
    }

    static func live(defaults: UserDefaults = .standard) -> PlanController {
#if YTDP_INTERNAL_TEST
        let store = InternalTestPlanStore(defaults: defaults)
        return PlanController(
            buildChannel: .internalTest,
            provider: InternalTestPlanProvider(store: store)
        )
#else
        return PlanController(
            buildChannel: .publicRelease,
            provider: PublicFreePlanProvider()
        )
#endif
    }

#if YTDP_INTERNAL_TEST
    func selectInternalPlan(_ plan: AppPlan) {
        guard buildChannel == .internalTest,
              plan == .free || plan == .testPro,
              let internalStore else { return }
        internalStore.savePlan(plan)
        internalOverride = plan
        publishEffectiveState()
    }

    func resetInternalPlanToFree() {
        selectInternalPlan(.free)
    }
#endif

#if DEBUG
    func setPlanForTesting(_ plan: AppPlan) {
        guard buildChannel == .internalTest else { return }
        switch plan {
        case .free:
            internalOverride = .free
            serverSnapshot = nil
        case .pro:
            internalOverride = .free
            serverSnapshot = .syntheticPro
        case .testPro:
            internalOverride = .testPro
        }
        publishEffectiveState()
    }
#endif

    func applyVerifiedEntitlement(_ entitlement: VerifiedEntitlement) {
        serverSnapshot = entitlement.snapshot
        publishEffectiveState()
    }

    func clearVerifiedEntitlement() {
        serverSnapshot = nil
        publishEffectiveState()
    }

    private var effectiveState: (plan: AppPlan, snapshot: EntitlementSnapshot) {
        if internalOverride == .testPro {
            return (.testPro, .syntheticPro)
        }
        if let serverSnapshot, serverSnapshot.plan == .pro {
            return (.pro, serverSnapshot)
        }
        return (.free, .syntheticFree)
    }

    private func publishEffectiveState() {
        let plan = effectiveState.plan
        guard currentPlan != plan else { return }
        currentPlan = plan
    }
}
