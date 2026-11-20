import Foundation
import CoreFoundation

enum UsageValidation {
    static func percent(_ value: Double?) -> Double? {
        guard let value, value.isFinite, (0...100).contains(value) else { return nil }
        return value
    }

    static func percent(json value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return percent(number.doubleValue)
    }

    static func display(_ value: Double?, rounded: Bool = false) -> String {
        percent(value).map { "\(Int(rounded ? $0.rounded() : $0))%" } ?? "—"
    }
}
