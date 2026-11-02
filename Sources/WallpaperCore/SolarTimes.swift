import Foundation

public struct SolarLocation: Codable, Equatable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public init(latitude: Double, longitude: Double) { self.latitude = latitude; self.longitude = longitude }
    public var isValid: Bool { latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude) }
}

public enum SolarPhase: String, CaseIterable, Codable, Identifiable, Sendable {
    case deepNight, dawn, morning, afternoon, evening, sunset, dusk, night
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .deepNight: "Deep Night"
        case .dawn: "Dawn"
        case .morning: "Morning"
        case .afternoon: "Afternoon"
        case .evening: "Evening"
        case .sunset: "Sunset"
        case .dusk: "Dusk"
        case .night: "Night"
        }
    }
    public var explanation: String {
        switch self {
        case .deepNight: "Solar midnight, when the sun is lowest."
        case .dawn: "First light: the sun rises to 6° below the horizon."
        case .morning: "Sunrise, when the sun appears above the horizon."
        case .afternoon: "Solar noon, when the sun is highest."
        case .evening: "One hour before sunset."
        case .sunset: "The sun disappears below the horizon."
        case .dusk: "End of civil twilight: the sun falls 6° below the horizon."
        case .night: "Full darkness: the sun falls 18° below the horizon."
        }
    }
}

/// Approximate solar times using NOAA's published fractional-year equations.
/// https://gml.noaa.gov/grad/solcalc/solareqns.PDF
/// Computes locally. Atmospheric conditions and terrain can shift observed times.
public enum SolarTimes {
    public static func time(for phase: SolarPhase, on day: Date, at location: SolarLocation,
                            calendar: Calendar = .autoupdatingCurrent) -> Date? {
        guard location.isValid else { return nil }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        var local = Calendar(identifier: .gregorian)
        local.timeZone = calendar.timeZone
        let parts = local.dateComponents([.year, .month, .day], from: day)
        guard let nominal = utc.date(from: parts) else { return nil }
        // Longitude and civil time zone need not agree near the date line.
        // Keep the event that actually falls on the requested local calendar date.
        for offset in -2...2 {
            guard let base = utc.date(byAdding: .day, value: offset, to: nominal),
                  let event = event(phase, base: base, location: location, utc: utc),
                  local.isDate(event, inSameDayAs: day) else { continue }
            return event
        }
        // At high latitudes some twilight/sunrise events do not happen that day.
        return nil
    }

    private static func event(_ phase: SolarPhase, base: Date, location: SolarLocation, utc: Calendar) -> Date? {
        var minutes = 720 - 4 * location.longitude
        let latitude = location.latitude * .pi / 180
        let isRising = phase == .dawn || phase == .morning
        for _ in 0..<3 {
            let estimate = base.addingTimeInterval(minutes * 60)
            guard let ordinal = utc.ordinality(of: .day, in: .year, for: estimate),
                  let yearDays = utc.range(of: .day, in: .year, for: estimate)?.count else { return nil }
            let hour = Double(utc.component(.hour, from: estimate)) + Double(utc.component(.minute, from: estimate)) / 60
            let gamma = 2 * Double.pi / Double(yearDays) * (Double(ordinal) - 1 + (hour - 12) / 24)
            let equation = 229.18 * (0.000075 + 0.001868 * cos(gamma) - 0.032077 * sin(gamma)
                                   - 0.014615 * cos(2 * gamma) - 0.040849 * sin(2 * gamma))
            let declination = 0.006918 - 0.399912 * cos(gamma) + 0.070257 * sin(gamma)
                - 0.006758 * cos(2 * gamma) + 0.000907 * sin(2 * gamma)
                - 0.002697 * cos(3 * gamma) + 0.00148 * sin(3 * gamma)
            let noon = 720 - 4 * location.longitude - equation
            switch phase {
            case .afternoon: minutes = noon
            case .deepNight: minutes = noon - 720
            default:
                let zenith: Double = switch phase {
                case .dawn, .dusk: 96
                case .night: 108
                default: 90.833
                }
                let cosine = (cos(zenith * .pi / 180) - sin(latitude) * sin(declination)) / (cos(latitude) * cos(declination))
                guard cosine.isFinite, (-1...1).contains(cosine) else { return nil }
                let angle = acos(cosine) * 180 / .pi
                minutes = noon + (isRising ? -4 : 4) * angle
                if phase == .evening { minutes -= 60 }
            }
        }
        return base.addingTimeInterval((minutes * 60).rounded())
    }
}
