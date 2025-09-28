//
//  TimeUtils.swift
//  ios-wallet
//
//  Shared time formatting helpers
//

import Foundation

public enum TimeUtils {
    /// Returns a compact relative time string like 15s, 1m, 2h, 3d, 4w, 5mo, 1y.
    /// - Parameters:
    ///   - date: The past date to compare against the reference date (defaults to now).
    ///   - referenceDate: The date considered as "now" (defaults to Date()).
    ///   - maximumUnitCount: Maximum number of units to include (defaults to 1 for compactness).
    /// - Returns: An abbreviated string without the word "ago".
    public static func abbreviatedRelative(from date: Date, to referenceDate: Date = Date(), maximumUnitCount: Int = 1) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = maximumUnitCount
        formatter.allowedUnits = [.year, .month, .weekOfMonth, .day, .hour, .minute, .second]
        formatter.zeroFormattingBehavior = .dropAll
        let interval = max(0, referenceDate.timeIntervalSince(date))
        return formatter.string(from: interval) ?? "0s"
    }
}


