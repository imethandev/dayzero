import Foundation

// MARK: - Morse code

enum MorseCode {
    static let table: [Character: String] = [
        "A": ".-", "B": "-...", "C": "-.-.", "D": "-..", "E": ".", "F": "..-.", "G": "--.", "H": "....",
        "I": "..", "J": ".---", "K": "-.-", "L": ".-..", "M": "--", "N": "-.", "O": "---", "P": ".--.",
        "Q": "--.-", "R": ".-.", "S": "...", "T": "-", "U": "..-", "V": "...-", "W": ".--", "X": "-..-",
        "Y": "-.--", "Z": "--..",
        "0": "-----", "1": ".----", "2": "..---", "3": "...--", "4": "....-", "5": ".....",
        "6": "-....", "7": "--...", "8": "---..", "9": "----.",
        ".": ".-.-.-", ",": "--..--", "?": "..--..", "'": ".----.", "!": "-.-.--", "/": "-..-.",
        "(": "-.--.", ")": "-.--.-", "&": ".-...", ":": "---...", ";": "-.-.-.", "=": "-...-",
        "+": ".-.-.", "-": "-....-", "\"": ".-..-.", "@": ".--.-.",
    ]

    /// Letters separated by spaces, words by " / ". Unknown characters are skipped.
    static func encode(_ text: String) -> String {
        words(text).map { $0.joined(separator: " ") }.joined(separator: " / ")
    }

    enum Element: Equatable {
        case on(Int)   // units of light/sound
        case off(Int)  // units of silence
    }

    /// Standard timing: dot 1, dash 3, gap 1 within a letter, 3 between letters, 7 between words.
    /// Ends with a 7-unit gap so a repeating signal (SOS) is spaced like separate words.
    static func timeline(_ text: String) -> [Element] {
        var out: [Element] = []
        for word in words(text) {
            for letter in word {
                for symbol in letter {
                    out.append(.on(symbol == "." ? 1 : 3))
                    out.append(.off(1))
                }
                out[out.count - 1] = .off(3)
            }
            out[out.count - 1] = .off(7)
        }
        return out
    }

    private static func words(_ text: String) -> [[String]] {
        text.uppercased()
            .split(whereSeparator: \.isWhitespace)
            .map { word in word.compactMap { table[$0] } }
            .filter { !$0.isEmpty }
    }

    /// Unit length for a speed in words per minute (PARIS standard: 50 units per word).
    static func unitSeconds(wpm: Double) -> Double { 1.2 / max(1, wpm) }
}

// MARK: - Sun times (NOAA sunrise equation, on device)

enum SunTimes {
    struct Day: Equatable {
        var sunrise: Date?
        var sunset: Date?
        var firstLight: Date? // civil dawn
        var lastLight: Date?  // civil dusk
        var isPolarDay = false
        var isPolarNight = false
    }

    static let officialZenith = 90.833
    static let civilZenith = 96.0

    static func day(for date: Date, latitude: Double, longitude: Double, timeZone: TimeZone = .current) -> Day {
        let rise = event(date: date, lat: latitude, lon: longitude, zenith: officialZenith, rising: true, tz: timeZone)
        let set = event(date: date, lat: latitude, lon: longitude, zenith: officialZenith, rising: false, tz: timeZone)
        var day = Day(
            sunrise: rise.date, sunset: set.date,
            firstLight: event(date: date, lat: latitude, lon: longitude, zenith: civilZenith, rising: true, tz: timeZone).date,
            lastLight: event(date: date, lat: latitude, lon: longitude, zenith: civilZenith, rising: false, tz: timeZone).date
        )
        day.isPolarDay = rise.alwaysUp
        day.isPolarNight = rise.alwaysDown
        return day
    }

    private struct Event { var date: Date?; var alwaysUp = false; var alwaysDown = false }

    private static func event(date: Date, lat: Double, lon: Double, zenith: Double, rising: Bool, tz: TimeZone) -> Event {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let rad = Double.pi / 180
        guard let n = cal.ordinality(of: .day, in: .year, for: date) else { return Event() }
        let lngHour = lon / 15
        let t = Double(n) + ((rising ? 6 : 18) - lngHour) / 24
        let m = 0.9856 * t - 3.289
        var l = m + 1.916 * sin(m * rad) + 0.020 * sin(2 * m * rad) + 282.634
        l = normalize(l, 360)
        var ra = atan(0.91764 * tan(l * rad)) / rad
        ra = normalize(ra, 360)
        ra += floor(l / 90) * 90 - floor(ra / 90) * 90
        ra /= 15
        let sinDec = 0.39782 * sin(l * rad)
        let cosDec = cos(asin(sinDec))
        let cosH = (cos(zenith * rad) - sinDec * sin(lat * rad)) / (cosDec * cos(lat * rad))
        if cosH > 1 { return Event(alwaysDown: true) }
        if cosH < -1 { return Event(alwaysUp: true) }
        var h = rising ? 360 - acos(cosH) / rad : acos(cosH) / rad
        h /= 15
        let localMeanTime = h + ra - 0.06571 * t - 6.622
        let ut = normalize(localMeanTime - lngHour, 24)
        // Convert to local clock hours for this date, then add to local midnight.
        let offsetHours = Double(tz.secondsFromGMT(for: date)) / 3600
        let local = normalize(ut + offsetHours, 24)
        let midnight = cal.startOfDay(for: date)
        return Event(date: midnight.addingTimeInterval(local * 3600))
    }

    private static func normalize(_ v: Double, _ m: Double) -> Double {
        let r = v.truncatingRemainder(dividingBy: m)
        return r < 0 ? r + m : r
    }
}

// MARK: - Calculator

/// A basic four-function calculator with percent, behaving like a pocket calculator.
struct CalculatorEngine: Equatable {
    enum Op: String { case add = "+", subtract = "−", multiply = "×", divide = "÷" }

    private(set) var display = "0"
    private var accumulator: Double?
    private var pending: Op?
    private var startNew = true
    private var lastOp: (Op, Double)?

    static func == (a: CalculatorEngine, b: CalculatorEngine) -> Bool { a.display == b.display }

    var value: Double { Double(display) ?? 0 }
    var pendingOp: Op? { pending }

    mutating func digit(_ d: String) {
        if display == "Error" { clear() }
        if startNew {
            display = d == "." ? "0." : d
            startNew = false
        } else {
            if d == "." && display.contains(".") { return }
            if display == "0" && d != "." { display = d } else if display.count < 16 { display += d }
        }
    }

    mutating func operation(_ op: Op) {
        if let pending, let acc = accumulator, !startNew {
            setResult(apply(pending, acc, value))
        }
        accumulator = value
        pending = op
        startNew = true
        lastOp = nil
    }

    mutating func equals() {
        if let op = pending, let acc = accumulator {
            let rhs = value
            setResult(apply(op, acc, rhs))
            lastOp = (op, rhs)
            pending = nil
            accumulator = nil
        } else if let (op, rhs) = lastOp {
            setResult(apply(op, value, rhs)) // repeat last operation, like a pocket calculator
        }
        startNew = true
    }

    /// With + or −, x% means x percent of the first number (200 + 10% = 220); otherwise x/100.
    mutating func percent() {
        if let acc = accumulator, let op = pending, op == .add || op == .subtract {
            setResult(acc * value / 100)
        } else {
            setResult(value / 100)
        }
        startNew = false
    }

    mutating func toggleSign() {
        guard display != "0", display != "Error" else { return }
        display = display.hasPrefix("-") ? String(display.dropFirst()) : "-" + display
    }

    mutating func clear() {
        display = "0"
        accumulator = nil
        pending = nil
        startNew = true
        lastOp = nil
    }

    mutating func backspace() {
        guard !startNew, display != "Error" else { return }
        display = display.count > 1 ? String(display.dropLast()) : "0"
        if display == "-" { display = "0" }
    }

    private func apply(_ op: Op, _ a: Double, _ b: Double) -> Double? {
        switch op {
        case .add: a + b
        case .subtract: a - b
        case .multiply: a * b
        case .divide: b == 0 ? nil : a / b
        }
    }

    private mutating func setResult(_ v: Double?) {
        guard let v, v.isFinite else {
            display = "Error"
            accumulator = nil
            pending = nil
            return
        }
        display = Self.format(v)
    }

    static func format(_ v: Double) -> String {
        if v == v.rounded(), abs(v) < 1e15 { return String(Int64(v)) }
        var s = String(format: "%.10g", v)
        if s.contains("e") { return s }
        while s.contains(".") && (s.hasSuffix("0") || s.hasSuffix(".")) { s.removeLast() }
        return s
    }
}
