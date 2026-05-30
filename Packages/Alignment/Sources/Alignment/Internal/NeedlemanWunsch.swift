import Foundation

/// Monotone sequence alignment between two paragraph sequences using a Needleman-Wunsch
/// variant that supports 1:1, 1:N, N:1 mappings.
///
/// The output is an array indexed by source paragraph index; each entry is the inclusive
/// range of target paragraph indices that the source paragraph aligns to.
/// A `nil` entry means the source paragraph was treated as a gap (no good target match).
enum NeedlemanWunsch {

    /// - Parameters:
    ///   - similarity: `similarity[i][j]` is the cosine similarity in [-1, 1] between
    ///     source paragraph `i` and target paragraph `j`.
    ///   - gapPenalty: subtracted from the score when a paragraph on either side is
    ///     skipped (no match). Typical 0.2-0.4.
    ///   - mergeBonus: optional reward per extra merged paragraph. Defaults to 0: merges
    ///     are scored by mean similarity, so grouping is only chosen when every merged
    ///     paragraph genuinely matches. Raise it slightly to bias toward grouping.
    ///   - maxMerge: cap on consecutive merge moves on either side. Prevents pathological
    ///     N:1 groupings when the books drift apart.
    static func align(
        similarity: [[Float]],
        gapPenalty: Float = 0.3,
        mergeBonus: Float = 0.0,
        maxMerge: Int = 6
    ) -> [ClosedRange<Int>?] {
        let n = similarity.count
        let m = similarity.first?.count ?? 0
        guard n > 0, m > 0 else { return Array(repeating: nil, count: n) }

        // Sentinel for unreachable
        let negInf: Float = -1e9

        // dp[i][j] = best score aligning first i source paragraphs to first j target paragraphs
        var dp = Array(repeating: Array(repeating: negInf, count: m + 1), count: n + 1)
        // back[i][j] = (di, dj, op) telling us how we arrived
        //   di == 0 && dj > 0 -> skip target (gap on source)
        //   di > 0 && dj == 0 -> skip source (gap on target)
        //   di > 0 && dj > 0  -> match a block of `di` source paragraphs to `dj` target paragraphs
        var back = Array(repeating: Array(repeating: (di: 0, dj: 0), count: m + 1), count: n + 1)

        dp[0][0] = 0
        for j in 1...m {
            dp[0][j] = dp[0][j - 1] - gapPenalty
            back[0][j] = (0, 1)
        }
        for i in 1...n {
            dp[i][0] = dp[i - 1][0] - gapPenalty
            back[i][0] = (1, 0)
        }

        for i in 1...n {
            for j in 1...m {
                // Try 1:1
                var bestScore = dp[i - 1][j - 1] + similarity[i - 1][j - 1]
                var bestDi = 1
                var bestDj = 1

                // Skip source (gap on target)
                let skipSourceScore = dp[i - 1][j] - gapPenalty
                if skipSourceScore > bestScore {
                    bestScore = skipSourceScore
                    bestDi = 1
                    bestDj = 0
                }
                // Skip target (gap on source)
                let skipTargetScore = dp[i][j - 1] - gapPenalty
                if skipTargetScore > bestScore {
                    bestScore = skipTargetScore
                    bestDi = 0
                    bestDj = 1
                }

                // 1:N (one source paragraph -> N consecutive targets).
                // Score by the MEAN similarity across the merged targets, not the max:
                // a merge only pays off when every absorbed target genuinely matches the
                // source. Using max let a single strong line drag in unrelated neighbours,
                // which caused over-selection (and downstream skips) on short lines.
                let maxN = min(maxMerge, j)
                if maxN >= 2 {
                    for k in 2...maxN {
                        var sumSim: Float = 0
                        for jj in (j - k)..<j { sumSim += similarity[i - 1][jj] }
                        let meanSim = sumSim / Float(k)
                        let score = dp[i - 1][j - k] + meanSim + mergeBonus * Float(k - 1)
                        if score > bestScore {
                            bestScore = score
                            bestDi = 1
                            bestDj = k
                        }
                    }
                }

                // N:1 (N consecutive sources -> one target), same mean-similarity rule.
                let maxNSrc = min(maxMerge, i)
                if maxNSrc >= 2 {
                    for k in 2...maxNSrc {
                        var sumSim: Float = 0
                        for ii in (i - k)..<i { sumSim += similarity[ii][j - 1] }
                        let meanSim = sumSim / Float(k)
                        let score = dp[i - k][j - 1] + meanSim + mergeBonus * Float(k - 1)
                        if score > bestScore {
                            bestScore = score
                            bestDi = k
                            bestDj = 1
                        }
                    }
                }

                dp[i][j] = bestScore
                back[i][j] = (bestDi, bestDj)
            }
        }

        // Backtrack to fill out the mapping array.
        var mapping = [ClosedRange<Int>?](repeating: nil, count: n)
        var i = n
        var j = m
        while i > 0 || j > 0 {
            let (di, dj) = back[i][j]
            if di > 0 && dj > 0 {
                let sStart = i - di
                let tStart = j - dj
                let targetRange = tStart...(j - 1)
                for ii in sStart..<i {
                    mapping[ii] = targetRange
                }
                i = sStart
                j = tStart
            } else if di > 0 {
                // Skip source (gap on target); leave mapping[i-1] = nil
                i -= 1
            } else if dj > 0 {
                // Skip target; nothing to record on source side
                j -= 1
            } else {
                break
            }
        }
        return mapping
    }

    /// Cosine similarity in [-1, 1] between two equal-length vectors.
    /// Returns 0 if either vector has zero magnitude.
    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        precondition(a.count == b.count, "Vectors must have the same dimension")
        var dot: Float = 0
        var na: Float = 0
        var nb: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let denom = (na.squareRoot() * nb.squareRoot())
        return denom > 0 ? dot / denom : 0
    }
}
