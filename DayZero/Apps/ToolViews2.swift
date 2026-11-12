import CoreLocation
import SwiftUI
import UIKit

// MARK: - Calculator

struct CalculatorView: View {
    @State private var calc = CalculatorEngine()

    private let rows: [[String]] = [
        ["C", "±", "%", "÷"],
        ["7", "8", "9", "×"],
        ["4", "5", "6", "−"],
        ["1", "2", "3", "+"],
        ["0", ".", "⌫", "="],
    ]

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Text(calc.display)
                .font(.system(size: 64, weight: .light, design: .rounded).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.4)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal)
                .textSelection(.enabled)
                .accessibilityLabel("Result \(calc.display)")
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 12) {
                    ForEach(row, id: \.self) { key in
                        Button { press(key) } label: {
                            Text(key)
                                .font(.title.weight(.medium))
                                .frame(maxWidth: .infinity, minHeight: 64)
                                .background(color(key), in: RoundedRectangle(cornerRadius: 18))
                                .foregroundStyle(isOp(key) ? .white : .primary)
                        }
                        .accessibilityLabel(spoken(key))
                    }
                }
            }
        }
        .padding()
        .navigationTitle("Calculator")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func isOp(_ k: String) -> Bool { ["÷", "×", "−", "+", "="].contains(k) }

    private func color(_ k: String) -> Color {
        if isOp(k) {
            return calc.pendingOp?.rawValue == k ? Color.orange.opacity(0.6) : .orange
        }
        return ["C", "±", "%", "⌫"].contains(k) ? Color.secondary.opacity(0.3) : Color.secondary.opacity(0.15)
    }

    private func spoken(_ k: String) -> String {
        switch k {
        case "C": "Clear"
        case "±": "Change sign"
        case "%": "Percent"
        case "÷": "Divide"
        case "×": "Multiply"
        case "−": "Subtract"
        case "+": "Add"
        case "=": "Equals"
        case "⌫": "Delete"
        case ".": "Decimal point"
        default: k
        }
    }

    private func press(_ k: String) {
        switch k {
        case "C": calc.clear()
        case "±": calc.toggleSign()
        case "%": calc.percent()
        case "÷": calc.operation(.divide)
        case "×": calc.operation(.multiply)
        case "−": calc.operation(.subtract)
        case "+": calc.operation(.add)
        case "=": calc.equals()
        case "⌫": calc.backspace()
        default: calc.digit(k)
        }
    }
}

// MARK: - Unit converter

struct ConverterView: View {
    enum Pair: String, CaseIterable, Identifiable {
        case volume = "Gallons ⇄ Liters", mass = "Pounds ⇄ Kilograms", length = "Miles ⇄ Kilometers", temp = "°F ⇄ °C"
        var id: String { rawValue }
        var units: (Dimension, Dimension, String, String) {
            switch self {
            case .volume: (UnitVolume.gallons, UnitVolume.liters, "gal", "L")
            case .mass: (UnitMass.pounds, UnitMass.kilograms, "lb", "kg")
            case .length: (UnitLength.miles, UnitLength.kilometers, "mi", "km")
            case .temp: (UnitTemperature.fahrenheit, UnitTemperature.celsius, "°F", "°C")
            }
        }
    }

    @AppStorage("converter.pair") private var pair: Pair = .volume
    @State private var left = "1"
    @State private var right = ""
    @FocusState private var focus: Int?

    var body: some View {
        Form {
            Picker("Convert", selection: $pair) {
                ForEach(Pair.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()

            Section {
                field($left, unit: pair.units.2, tag: 0)
                field($right, unit: pair.units.3, tag: 1)
            } footer: {
                Text("Type in either box. US gallons.")
            }
        }
        .navigationTitle("Unit converter")
        .onChange(of: left) { if focus != 1 { right = convert(left, from: pair.units.0, to: pair.units.1) } }
        .onChange(of: right) { if focus == 1 { left = convert(right, from: pair.units.1, to: pair.units.0) } }
        .onChange(of: pair) { right = convert(left, from: pair.units.0, to: pair.units.1) }
        .onAppear { right = convert(left, from: pair.units.0, to: pair.units.1) }
    }

    private func field(_ text: Binding<String>, unit: String, tag: Int) -> some View {
        HStack {
            TextField("0", text: text)
                .keyboardType(.numbersAndPunctuation)
                .font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
                .focused($focus, equals: tag)
            Text(unit).font(.title2).foregroundStyle(.secondary)
        }
    }

    private func convert(_ s: String, from: Dimension, to: Dimension) -> String {
        guard let v = Double(s.replacingOccurrences(of: ",", with: ".")) else { return "" }
        let out = Measurement(value: v, unit: from).converted(to: to).value
        return out.formatted(.number.precision(.fractionLength(0...3)).grouping(.never))
    }
}

// MARK: - Compass

struct CompassView: View {
    @State private var location = LocationProvider.shared

    private var degrees: Double? {
        guard let h = location.heading else { return nil }
        return h.trueHeading >= 0 ? h.trueHeading : h.magneticHeading
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            if !LocationProvider.headingAvailable {
                ContentUnavailableView("No compass", systemImage: "location.north.line",
                                       description: Text("This device has no magnetometer. Try it on an iPhone."))
            } else if let degrees {
                ZStack {
                    Circle().stroke(.secondary.opacity(0.4), lineWidth: 2)
                    ForEach(0..<72) { i in
                        Rectangle()
                            .fill(i % 18 == 0 ? Color.primary : Color.secondary)
                            .frame(width: i % 6 == 0 ? 3 : 1, height: i % 6 == 0 ? 16 : 8)
                            .offset(y: -132)
                            .rotationEffect(.degrees(Double(i) * 5))
                    }
                    ForEach(Array(["N", "E", "S", "W"].enumerated()), id: \.offset) { i, label in
                        Text(label)
                            .font(.title2.bold())
                            .foregroundStyle(label == "N" ? .red : .primary)
                            .offset(y: -105)
                            .rotationEffect(.degrees(Double(i) * 90))
                    }
                }
                .frame(width: 280, height: 280)
                .rotationEffect(.degrees(-degrees))
                .animation(.easeOut(duration: 0.2), value: degrees)
                .overlay(alignment: .top) {
                    Image(systemName: "arrowtriangle.down.fill").foregroundStyle(.orange).offset(y: -20)
                }
                Text("\(Int(degrees.rounded()) % 360)°  \(cardinal(degrees))")
                    .font(.system(size: 52, weight: .bold, design: .rounded).monospacedDigit())
                Text(location.heading?.trueHeading ?? -1 >= 0 ? "True north" : "Magnetic north (allow location for true north)")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                ProgressView("Reading compass…")
            }
            Spacer()
            Text("Hold the phone flat, away from magnets and metal.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding()
        .navigationTitle("Compass")
        .onAppear { location.startHeading(); location.start() }
        .onDisappear { location.stopHeading(); location.stop() }
    }

    private func cardinal(_ d: Double) -> String {
        let names = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE", "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
        return names[Int((d + 11.25) / 22.5) % 16]
    }
}

// MARK: - Coordinates

struct CoordinatesView: View {
    @State private var location = LocationProvider.shared
    @State private var copied = false

    var body: some View {
        List {
            if let loc = location.location {
                Section {
                    big("Latitude", String(format: "%.5f°", loc.coordinate.latitude))
                    big("Longitude", String(format: "%.5f°", loc.coordinate.longitude))
                    big("Elevation", loc.verticalAccuracy >= 0
                        ? "\(Int(Measurement(value: loc.altitude, unit: UnitLength.meters).converted(to: .feet).value.rounded()).formatted()) ft"
                        : "—")
                } footer: {
                    Text("Accuracy ±\(Int(loc.horizontalAccuracy)) m · updated \(loc.timestamp.formatted(date: .omitted, time: .standard))")
                }
                Section("Other formats") {
                    LabeledContent("Degrees, minutes, seconds", value: dms(loc.coordinate))
                    LabeledContent("For texting", value: DistanceFormat.coordinates(loc.coordinate.latitude, loc.coordinate.longitude))
                }
                Section {
                    Button(copied ? "Copied" : "Copy coordinates", systemImage: copied ? "checkmark" : "doc.on.doc") {
                        UIPasteboard.general.string = DistanceFormat.coordinates(loc.coordinate.latitude, loc.coordinate.longitude)
                        copied = true
                    }
                }
            } else {
                ContentUnavailableView {
                    Label(location.isDenied ? "Location is off" : "Waiting for GPS…", systemImage: "scope")
                } description: {
                    Text(location.isDenied ? "Turn on location for DayZero in Settings." : "GPS works with no network. Outdoors with a clear sky is fastest.")
                }
            }
        }
        .navigationTitle("Coordinates")
        .onAppear { location.startPrecise() }
        .onDisappear { location.stopPrecise() }
    }

    private func big(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 38, weight: .bold, design: .rounded).monospacedDigit()).textSelection(.enabled)
        }
    }

    private func dms(_ c: CLLocationCoordinate2D) -> String {
        func part(_ v: Double, _ pos: String, _ neg: String) -> String {
            let a = abs(v), d = Int(a), m = Int((a - Double(d)) * 60), s = (a - Double(d) - Double(m) / 60) * 3600
            return String(format: "%d°%02d′%04.1f″%@", d, m, s, v >= 0 ? pos : neg)
        }
        return "\(part(c.latitude, "N", "S")) \(part(c.longitude, "E", "W"))"
    }
}

// MARK: - Sun times

struct SunTimesView: View {
    @State private var location = LocationProvider.shared
    @State private var date = Date.now

    var body: some View {
        List {
            if let loc = location.location {
                let day = SunTimes.day(for: date, latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude)
                Section {
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                }
                Section {
                    row("First light", day.firstLight, "sun.horizon")
                    row("Sunrise", day.sunrise, "sunrise.fill")
                    row("Sunset", day.sunset, "sunset.fill")
                    row("Last light", day.lastLight, "moon.stars")
                    if let r = day.sunrise, let s = day.sunset {
                        let mins = Int(s.timeIntervalSince(r) / 60)
                        LabeledContent("Daylight", value: "\(mins / 60) h \(mins % 60) min")
                    }
                    if day.isPolarDay { Text("The sun doesn't set today.") }
                    if day.isPolarNight { Text("The sun doesn't rise today.") }
                } footer: {
                    Text("Calculated on this phone from the date and your GPS position. First and last light are civil twilight, when there's enough light to work outside.")
                }
            } else {
                ContentUnavailableView {
                    Label(location.isDenied ? "Location is off" : "Waiting for GPS…", systemImage: "sunrise")
                } description: {
                    Text("Sun times need your position. No network required.")
                }
            }
        }
        .navigationTitle("Sun times")
        .onAppear { location.start() }
        .onDisappear { location.stop() }
    }

    private func row(_ label: String, _ date: Date?, _ symbol: String) -> some View {
        LabeledContent {
            Text(date?.formatted(date: .omitted, time: .shortened) ?? "—")
                .font(.title2.weight(.semibold).monospacedDigit())
        } label: {
            Label(label, systemImage: symbol)
        }
    }
}

// MARK: - Timer & stopwatch

struct TimerView: View {
    enum Mode: String, CaseIterable { case timer = "Timer", stopwatch = "Stopwatch" }
    @State private var store = TimerStore.shared
    let mode: Mode
    @State private var hours = 0
    @State private var minutes = 10
    @State private var seconds = 0

    var body: some View {
        VStack(spacing: 20) {
            switch mode {
            case .timer: countdown
            case .stopwatch: stopwatch
            }
            Spacer()
        }
        .padding()
        .navigationTitle(mode.rawValue)
        .onAppear {
            let d = Int(store.lastDuration)
            hours = d / 3600; minutes = d / 60 % 60; seconds = d % 60
        }
    }

    @ViewBuilder private var countdown: some View {
        if store.countdownActive {
            TimelineView(.periodic(from: .now, by: 0.1)) { ctx in
                let remaining = store.countdownRemaining(at: ctx.date) ?? 0
                Text(TimerStore.format(remaining, tenths: false))
                    .font(.system(size: 72, weight: .light, design: .rounded).monospacedDigit())
                    .onChange(of: remaining <= 0) { _, done in if done && store.countdownRunning { store.countdownFinished() } }
            }
            .frame(height: 160)
            HStack(spacing: 16) {
                Button("Cancel", role: .destructive) { store.cancelCountdown() }
                    .buttonStyle(.bordered).controlSize(.large)
                if store.countdownRunning {
                    Button("Pause") { store.pauseCountdown() }.buttonStyle(.borderedProminent).controlSize(.large)
                } else {
                    Button("Resume") { store.resumeCountdown() }.buttonStyle(.borderedProminent).controlSize(.large)
                }
            }
            Text("Keeps running if you leave the app. A notification sounds when it's done.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        } else {
            HStack(spacing: 0) {
                wheel($hours, 0..<24, "h")
                wheel($minutes, 0..<60, "min")
                wheel($seconds, 0..<60, "s")
            }
            .frame(height: 180)
            Button {
                store.startCountdown(TimeInterval(hours * 3600 + minutes * 60 + seconds))
            } label: {
                Text("Start").font(.title3.bold()).frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .disabled(hours + minutes + seconds == 0)
        }
    }

    private func wheel(_ value: Binding<Int>, _ range: Range<Int>, _ unit: String) -> some View {
        Picker(unit, selection: value) {
            ForEach(range, id: \.self) { Text("\($0) \(unit)").tag($0) }
        }
        .pickerStyle(.wheel)
    }

    private var stopwatch: some View {
        VStack(spacing: 16) {
            TimelineView(.periodic(from: .now, by: 0.1)) { ctx in
                Text(TimerStore.format(store.stopwatchElapsed(at: ctx.date)))
                    .font(.system(size: 64, weight: .light, design: .rounded).monospacedDigit())
            }
            .frame(height: 140)
            HStack(spacing: 16) {
                Button(store.stopwatchRunning ? "Lap" : "Reset") {
                    store.stopwatchRunning ? store.lap() : store.resetStopwatch()
                }
                .buttonStyle(.bordered).controlSize(.large)
                Button(store.stopwatchRunning ? "Stop" : "Start") {
                    store.stopwatchRunning ? store.stopStopwatch() : store.startStopwatch()
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .tint(store.stopwatchRunning ? .red : .green)
            }
            List(Array(store.laps.enumerated()), id: \.offset) { i, lap in
                LabeledContent("Lap \(store.laps.count - i)", value: TimerStore.format(lap))
                    .monospacedDigit()
            }
            .listStyle(.plain)
        }
    }
}
