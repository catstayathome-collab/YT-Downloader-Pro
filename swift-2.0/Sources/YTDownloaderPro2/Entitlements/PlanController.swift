import Combine
import Foundation

@MainActor
final class PlanController: ObservableObject {
    @Published private(set) var currentPlan: AppPlan

    let buildChannel: AppBuildChannel
    private let internalStore: InternalTestPlanStore?

    var featurePolicyContext: FeaturePolicyContext {
        currentPlan.featurePolicyContext
    }

    var internalSwitchingAvailable: Bool {
        buildChannel == .internalTest
    }

    init(buildChannel: AppBuildChannel, provider: any PlanProviding) {
        self.buildChannel = buildChannel
        if buildChannel == .internalTest {
            internalStore = (provider as? InternalTestPlanProvider)?.store
            currentPlan = provider.loadPlan()
        } else {
            internalStore = nil
            currentPlan = .free
        }
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
        guard buildChannel == .internalTest, let internalStore else { return }
        internalStore.savePlan(plan)
        guard currentPlan != plan else { return }
        currentPlan = plan
    }

    func resetInternalPlanToFree() {
        selectInternalPlan(.free)
    }
#endif

#if DEBUG
    func setPlanForTesting(_ plan: AppPlan) {
        guard buildChannel == .internalTest else { return }
        currentPlan = plan
    }
#endif
}
