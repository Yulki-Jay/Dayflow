//
//  StorageManager.swift
//  Dayflow
//

import Foundation
import GRDB
import Sentry

extension DateFormatter {
  static let yyyyMMdd: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.timeZone = Calendar.current.timeZone
    return formatter
  }()
}

extension Date {
  /// Calculates the "day" based on a 4 AM start time.
  /// Returns the date string (YYYY-MM-DD) and the Date objects for the start and end of that day.
  func getDayInfoFor4AMBoundary(calendar: Calendar = .current) -> (dayString: String, startOfDay: Date, endOfDay: Date) {
    func dayString(_ date: Date) -> String {
      let parts = calendar.dateComponents([.year, .month, .day], from: date)
      return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
    guard let fourAMToday = calendar.date(bySettingHour: 4, minute: 0, second: 0, of: self) else {
      print("Error: Could not calculate 4 AM for date \(self). Falling back to standard day.")
      let start = calendar.startOfDay(for: self)
      let end = calendar.date(byAdding: .day, value: 1, to: start)!
      return (dayString(start), start, end)
    }

    let startOfDay: Date
    if self < fourAMToday {
      startOfDay = calendar.date(byAdding: .day, value: -1, to: fourAMToday)!
    } else {
      startOfDay = fourAMToday
    }
    let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!
    return (dayString(startOfDay), startOfDay, endOfDay)
  }
}
