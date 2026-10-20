import Foundation

/// The guide advances on product events, never on an elapsed timer or a Next button.
public struct GuideProgress: Equatable {
    public enum Step: String {
        case idle, search, result, contentOffer, contentSetup, contentSearch, success, finished, dismissed
        public var isActive: Bool { ![.idle, .finished, .dismissed].contains(self) }
        public var number: Int { self == .search ? 1 : self == .result ? 2 : 3 }
    }
    public enum Event { case start, replay, results, useResult, configureContent, searchContent, contentMatch, finish, dismiss }
    public private(set) var step: Step

    public init(saved: String?, returningUser: Bool) {
        // An upgrade is not a first launch. Unknown future versions also stay quiet.
        step = saved.flatMap(Step.init(rawValue:)) ?? (returningUser || saved != nil ? .dismissed : .idle)
    }
    public mutating func send(_ event: Event) {
        switch event {
        case .start: if step == .idle { step = .search }
        case .replay: step = .search
        case .results: if step == .search { step = .result }
        case .useResult: if step == .result { step = .contentOffer }
        case .configureContent: if step.isActive { step = .contentSetup }
        case .searchContent: if step == .contentSetup { step = .contentSearch }
        case .contentMatch: if step == .contentSearch { step = .success }
        case .finish: if step == .success { step = .finished }
        case .dismiss: if step.isActive || step == .idle { step = .dismissed }
        }
    }
}
