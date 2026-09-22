import Foundation

protocol PlanProviding {
    func loadPlan() -> AppPlan
}

struct PublicFreePlanProvider: PlanProviding {
    func loadPlan() -> AppPlan {
        .free
    }
}

struct InternalTestPlanStore {
    static let key = "internal-test-selected-plan"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadPlan() -> AppPlan {
        guard
            let rawValue = defaults.object(forKey: Self.key) as? String,
            let plan = AppPlan(rawValue: rawValue)
        else {
            return .free
        }
        return plan
    }

    func savePlan(_ plan: AppPlan) {
        defaults.set(plan.rawValue, forKey: Self.key)
    }
}

struct InternalTestPlanProvider: PlanProviding {
    let store: InternalTestPlanStore

    func loadPlan() -> AppPlan {
        store.loadPlan()
    }
}
