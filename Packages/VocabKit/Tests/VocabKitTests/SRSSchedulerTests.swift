import Testing
import Foundation
@testable import VocabKit

@Suite struct SRSSchedulerTests {

    @Test func goodProgressionFollowsOneThenSix() {
        let now = Date(timeIntervalSince1970: 0)
        let first = SRSScheduler.next(easeFactor: 2.5, intervalDays: 0, repetitions: 0, lapses: 0, grade: .good, now: now)
        #expect(first.intervalDays == 1)
        #expect(first.repetitions == 1)

        let second = SRSScheduler.next(easeFactor: 2.5, intervalDays: first.intervalDays, repetitions: first.repetitions, lapses: 0, grade: .good, now: now)
        #expect(second.intervalDays == 6)
        #expect(second.repetitions == 2)

        let third = SRSScheduler.next(easeFactor: 2.5, intervalDays: second.intervalDays, repetitions: second.repetitions, lapses: 0, grade: .good, now: now)
        // 6 * 2.5 = 15
        #expect(third.intervalDays == 15)
    }

    @Test func againResetsRepetitionsAndLowersEase() {
        let now = Date(timeIntervalSince1970: 0)
        let out = SRSScheduler.next(easeFactor: 2.5, intervalDays: 15, repetitions: 3, lapses: 0, grade: .again, now: now)
        #expect(out.repetitions == 0)
        #expect(out.lapses == 1)
        #expect(abs(out.easeFactor - 2.3) < 1e-9)
        // Due again very soon (same session), not days out.
        #expect(out.dueDate.timeIntervalSince(now) < 3600)
    }

    @Test func easeNeverDropsBelowFloor() {
        let now = Date(timeIntervalSince1970: 0)
        var ease = 1.4
        for _ in 0..<5 {
            ease = SRSScheduler.next(easeFactor: ease, intervalDays: 5, repetitions: 2, lapses: 0, grade: .again, now: now).easeFactor
        }
        #expect(ease == SRSScheduler.minimumEase)
    }

    @Test func easyGrowsFasterThanGoodAndRaisesEase() {
        let now = Date(timeIntervalSince1970: 0)
        let good = SRSScheduler.next(easeFactor: 2.5, intervalDays: 10, repetitions: 2, lapses: 0, grade: .good, now: now)
        let easy = SRSScheduler.next(easeFactor: 2.5, intervalDays: 10, repetitions: 2, lapses: 0, grade: .easy, now: now)
        #expect(easy.intervalDays > good.intervalDays)
        #expect(easy.easeFactor > 2.5)
    }
}
