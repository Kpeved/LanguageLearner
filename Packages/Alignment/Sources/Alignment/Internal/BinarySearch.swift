import Foundation

enum BinarySearch {
    /// Find the largest index `i` in `0..<arr.count - 1` such that `arr[i] <= value`.
    /// `arr` must be sorted ascending. The result is clamped to `[0, arr.count - 2]`.
    /// Returns nil if `arr.count < 2`.
    static func bucket(value: Int, in arr: [Int]) -> Int? {
        guard arr.count >= 2 else { return nil }
        var lo = 0
        var hi = arr.count - 1
        while lo + 1 < hi {
            let mid = (lo + hi) / 2
            if arr[mid] <= value {
                lo = mid
            } else {
                hi = mid
            }
        }
        return lo
    }
}
