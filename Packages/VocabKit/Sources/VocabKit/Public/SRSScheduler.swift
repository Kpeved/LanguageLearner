import Foundation

/// SM-2 lite spaced-repetition scheduling. Pure functions over the scheduling state,
/// kept free of SwiftData so the interval math is unit-testable in isolation.
///
/// The model: each card carries an `easeFactor` (how fast its interval grows), an
/// `intervalDays` (current spacing), a `repetitions` count of consecutive successful
/// reviews, and a `lapses` count. Grading produces the next state.
public enum SRSScheduler {

    /// Resulting scheduling state after a review.
    public struct Outcome: Sendable, Equatable {
        public let easeFactor: Double
        public let intervalDays: Double
        public let repetitions: Int
        public let lapses: Int
        public let dueDate: Date
    }

    /// Lower bound on the ease factor, matching Anki's SM-2 floor. Below this an item
    /// would grow too slowly to ever leave the daily queue.
    public static let minimumEase: Double = 1.3

    /// Interval (in days) a lapsed card is re-shown at: same session, ~10 minutes out.
    private static let relearnIntervalDays: Double = 10.0 / (24 * 60)

    public static func next(
        easeFactor: Double,
        intervalDays: Double,
        repetitions: Int,
        lapses: Int,
        grade: ReviewGrade,
        now: Date = .now
    ) -> Outcome {
        switch grade {
        case .again:
            let ease = max(minimumEase, easeFactor - 0.2)
            return Outcome(
                easeFactor: ease,
                intervalDays: relearnIntervalDays,
                repetitions: 0,
                lapses: lapses + 1,
                dueDate: now.addingTimeInterval(relearnIntervalDays * 86_400)
            )

        case .good:
            let newInterval: Double
            switch repetitions {
            case 0: newInterval = 1
            case 1: newInterval = 6
            default: newInterval = (intervalDays * easeFactor).rounded()
            }
            return Outcome(
                easeFactor: easeFactor,
                intervalDays: newInterval,
                repetitions: repetitions + 1,
                lapses: lapses,
                dueDate: now.addingTimeInterval(newInterval * 86_400)
            )

        case .easy:
            let ease = easeFactor + 0.15
            let base: Double
            switch repetitions {
            case 0: base = 1
            case 1: base = 6
            default: base = intervalDays * ease
            }
            let newInterval = (base * 1.3).rounded()
            return Outcome(
                easeFactor: ease,
                intervalDays: newInterval,
                repetitions: repetitions + 1,
                lapses: lapses,
                dueDate: now.addingTimeInterval(newInterval * 86_400)
            )
        }
    }
}
