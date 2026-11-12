import Foundation
import Testing
@testable import DayZero

@Suite("Morse code")
struct MorseTests {
    @Test func encodesSOS() {
        #expect(MorseCode.encode("sos") == "... --- ...")
        #expect(MorseCode.encode("SOS help") == "... --- ... / .... . .-.. .--.")
    }

    // Spec acceptance: SOS flashes three short, three long, three short, then repeats.
    @Test func sosTimelineIsThreeShortThreeLongThreeShort() {
        let t = MorseCode.timeline("SOS")
        let expected: [MorseCode.Element] = [
            .on(1), .off(1), .on(1), .off(1), .on(1), .off(3),
            .on(3), .off(1), .on(3), .off(1), .on(3), .off(3),
            .on(1), .off(1), .on(1), .off(1), .on(1), .off(7),
        ]
        #expect(t == expected)
    }

    @Test func skipsUnknownCharactersAndExtraSpaces() {
        #expect(MorseCode.encode("  a ~ b  ") == ".- / -...")
        #expect(MorseCode.timeline("~~~").isEmpty)
    }

    @Test func wpmUnit() {
        #expect(abs(MorseCode.unitSeconds(wpm: 12) - 0.1) < 1e-9)
    }
}

@Suite("Sun times")
struct SunTimesTests {
    let pacific = TimeZone(identifier: "America/Los_Angeles")!

    func local(_ date: Date?) -> (Int, Int)? {
        guard let date else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = pacific
        let c = cal.dateComponents([.hour, .minute], from: date)
        return (c.hour!, c.minute!)
    }

    func minutes(_ hm: (Int, Int)?) -> Int { hm.map { $0.0 * 60 + $0.1 } ?? -1 }

    @Test func seattleWinterMatchesPublishedTimes() {
        // Seattle, Nov 11 2026. Reference from the full NOAA solar-position equations: 7:09 AM / 4:37 PM PST.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = pacific
        let date = cal.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 12))!
        let d = SunTimes.day(for: date, latitude: 47.6062, longitude: -122.3321, timeZone: pacific)
        #expect(abs(minutes(local(d.sunrise)) - (7 * 60 + 9)) <= 3)
        #expect(abs(minutes(local(d.sunset)) - (16 * 60 + 37)) <= 3)
        #expect(d.firstLight! < d.sunrise!)
        #expect(d.lastLight! > d.sunset!)
    }

    @Test func spokaneSummerUsesDaylightTime() {
        // Spokane, Jun 21 2026. NOAA reference: 4:52 AM / 8:51 PM PDT.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = pacific
        let date = cal.date(from: DateComponents(year: 2026, month: 6, day: 21, hour: 12))!
        let d = SunTimes.day(for: date, latitude: 47.6588, longitude: -117.4260, timeZone: pacific)
        #expect(abs(minutes(local(d.sunrise)) - (4 * 60 + 52)) <= 3)
        #expect(abs(minutes(local(d.sunset)) - (20 * 60 + 51)) <= 3)
    }

    @Test func polarNightHasNoSunrise() {
        let utc = TimeZone(identifier: "UTC")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        let date = cal.date(from: DateComponents(year: 2026, month: 12, day: 21, hour: 12))!
        let d = SunTimes.day(for: date, latitude: 78.2, longitude: 15.6, timeZone: utc) // Svalbard
        #expect(d.sunrise == nil)
        #expect(d.isPolarNight)
    }
}

@Suite("Calculator")
struct CalculatorTests {
    func run(_ keys: String) -> String {
        var c = CalculatorEngine()
        for k in keys.split(separator: " ") {
            switch k {
            case "+": c.operation(.add)
            case "-": c.operation(.subtract)
            case "*": c.operation(.multiply)
            case "/": c.operation(.divide)
            case "=": c.equals()
            case "%": c.percent()
            case "C": c.clear()
            case "±": c.toggleSign()
            default: k.forEach { c.digit(String($0)) }
            }
        }
        return c.display
    }

    @Test func basicArithmetic() {
        #expect(run("12 + 30 =") == "42")
        #expect(run("7 - 10 =") == "-3")
        #expect(run("6 * 7 =") == "42")
        #expect(run("1 / 4 =") == "0.25")
        #expect(run("1 / 3 =") == "0.3333333333")
    }

    @Test func chainsLeftToRight() {
        #expect(run("2 + 3 * 4 =") == "20")
    }

    @Test func percent() {
        #expect(run("200 + 10 % =") == "220")
        #expect(run("50 %") == "0.5")
        #expect(run("80 * 25 % =") == "20")
    }

    @Test func divideByZeroIsError() {
        #expect(run("5 / 0 =") == "Error")
        #expect(run("5 / 0 = 3") == "3")
    }

    @Test func repeatEquals() {
        #expect(run("2 + 3 = =") == "8")
    }

    @Test func decimalsAndSign() {
        #expect(run("1.5 + 1.25 =") == "2.75")
        #expect(run("4 ±") == "-4")
        #expect(run("0.1 + 0.2 =") == "0.3")
    }
}

@Suite("Tool grid")
struct ToolGridTests {
    @Test func stopwatchSlotsInAfterTimerForExistingUsers() {
        // A saved order from the previous version (every tool except Stopwatch), rearranged by the user.
        let saved = "sos,flashlight,timer,calculator,whistle,screenLight,converter,compass,coordinates,sunTimes,morse,phone,messages,settings"
        let order = ToolID.resolveOrder(saved)
        #expect(Array(order.prefix(5)) == [.sos, .flashlight, .timer, .stopwatch, .calculator])
        #expect(Set(order) == Set(ToolID.allCases))
        #expect(order.count == ToolID.allCases.count)
    }

    @Test func defaultOrderPutsFlashlightAndSOSFirst() {
        let order = ToolID.resolveOrder("")
        #expect(Array(order.prefix(2)) == [.flashlight, .sos])
        #expect(order.firstIndex(of: .stopwatch) == order.firstIndex(of: .timer)! + 1)
    }

    @Test func onlyPhoneNeedsService() {
        #expect(ToolID.allCases.filter { !$0.worksOffline } == [.phone])
    }
}
