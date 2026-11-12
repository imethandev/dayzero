import SwiftUI
import UIKit

enum ToolID: String, CaseIterable, Identifiable {
    case flashlight, sos, screenLight, calculator, converter, compass, coordinates, sunTimes, timer, stopwatch, whistle, morse
    case phone, messages, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .flashlight: "Flashlight"
        case .sos: "SOS signal"
        case .screenLight: "Screen light"
        case .calculator: "Calculator"
        case .converter: "Unit converter"
        case .compass: "Compass"
        case .coordinates: "Coordinates"
        case .sunTimes: "Sun times"
        case .timer: "Timer"
        case .stopwatch: "Stopwatch"
        case .whistle: "Whistle"
        case .morse: "Morse code"
        case .phone: "Phone"
        case .messages: "Messages"
        case .settings: "App settings"
        }
    }

    var symbol: String {
        switch self {
        case .flashlight: "flashlight.on.fill"
        case .sos: "sos"
        case .screenLight: "lightbulb.fill"
        case .calculator: "plus.forwardslash.minus"
        case .converter: "arrow.left.arrow.right"
        case .compass: "location.north.line.fill"
        case .coordinates: "scope"
        case .sunTimes: "sunrise.fill"
        case .timer: "timer"
        case .stopwatch: "stopwatch"
        case .whistle: "speaker.wave.3.fill"
        case .morse: "ellipsis.message.fill"
        case .phone: "phone.fill"
        case .messages: "message.fill"
        case .settings: "gear"
        }
    }

    /// System shortcuts open another app instead of a screen here.
    var isShortcut: Bool { [.phone, .messages, .settings].contains(self) }

    static let defaultOrder: [ToolID] = allCases

    /// Saved order with tools added in later versions slotted in after their
    /// neighbor in the default order (so Stopwatch appears right after Timer).
    static func resolveOrder(_ raw: String) -> [ToolID] {
        var list = raw.split(separator: ",").compactMap { ToolID(rawValue: String($0)) }
        for (i, tool) in defaultOrder.enumerated() where !list.contains(tool) {
            let before = defaultOrder[..<i].last { list.contains($0) }
            let at = before.flatMap { list.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
            list.insert(tool, at: at)
        }
        return list
    }

    /// Phone calls need cell service; every other screen works fully offline.
    var worksOffline: Bool { self != .phone }
}

/// Shown at the top of every tool screen.
struct OfflineBadge: View {
    var worksOffline = true

    var body: some View {
        Label(worksOffline ? "Works offline" : "Needs cell service",
              systemImage: worksOffline ? "wifi.slash" : "antenna.radiowaves.left.and.right")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(worksOffline ? Color.green : Color.orange)
            .background((worksOffline ? Color.green : Color.orange).opacity(0.15), in: Capsule())
            .overlay(Capsule().strokeBorder((worksOffline ? Color.green : Color.orange).opacity(0.4), lineWidth: 1))
            .accessibilityLabel(worksOffline ? "Works offline, no internet or cell service needed" : "Needs cell service")
    }
}

/// Destination screen for a tool.
struct ToolScreen: View {
    let tool: ToolID

    var body: some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                OfflineBadge(worksOffline: tool.worksOffline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(.bar)
            }
            // Inline titles: a large title would collapse behind the badge on scrolling screens.
            .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private var content: some View {
        switch tool {
        case .flashlight: FlashlightView()
        case .sos: SOSView()
        case .screenLight: ScreenLightLauncher()
        case .calculator: CalculatorView()
        case .converter: ConverterView()
        case .compass: CompassView()
        case .coordinates: CoordinatesView()
        case .sunTimes: SunTimesView()
        case .timer: TimerView(mode: .timer)
        case .stopwatch: TimerView(mode: .stopwatch)
        case .whistle: WhistleView()
        case .morse: MorseView()
        case .phone: DialerView()
        case .messages, .settings: EmptyView()
        }
    }
}

// MARK: - Flashlight

struct FlashlightView: View {
    @State private var tools = ToolController.shared

    var body: some View {
        VStack(spacing: 32) {
            Spacer()
            Button { tools.toggleTorch() } label: {
                Image(systemName: tools.torchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                    .font(.system(size: 80))
                    .frame(width: 200, height: 200)
                    .background(tools.torchOn ? Color.yellow : Color.secondary.opacity(0.2), in: Circle())
                    .foregroundStyle(tools.torchOn ? .black : .primary)
            }
            .accessibilityLabel(tools.torchOn ? "Turn flashlight off" : "Turn flashlight on")
            Text(tools.torchOn ? "On" : "Off").font(.title.bold())
            VStack(alignment: .leading) {
                Label("Brightness", systemImage: "sun.max")
                Slider(value: Binding(get: { Double(tools.torchLevel) }, set: { tools.torchLevel = Float($0) }),
                       in: 0.05...1)
                    .accessibilityLabel("Brightness")
            }
            .padding(.horizontal, 32)
            if let error = tools.torchError {
                Text(error).foregroundStyle(.secondary)
            }
            Spacer()
            Text("The light turns off when you leave DayZero.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding()
        .navigationTitle("Flashlight")
    }
}

// MARK: - SOS

struct SOSView: View {
    @State private var tools = ToolController.shared
    @AppStorage("sos.screenFlash") private var screenFlash = true

    private var lit: Bool { tools.sosRunning && tools.signalElementOn }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Pattern and status
                VStack(spacing: 6) {
                    Text("··· ––– ···")
                        .font(.system(size: 44, weight: .heavy, design: .monospaced))
                        .foregroundStyle(lit ? .red : .primary)
                    Text(tools.sosRunning ? "Signalling SOS. Point the back of the phone toward searchers." : "Morse code for SOS")
                        .font(.subheadline.weight(tools.sosRunning ? .semibold : .regular))
                        .foregroundStyle(tools.sosRunning ? .red : .secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 8)

                Button { tools.toggleSOS() } label: {
                    Text(tools.sosRunning ? "STOP SIGNAL" : "START SOS")
                        .font(.title2.weight(.black))
                        .frame(maxWidth: .infinity, minHeight: 84)
                }
                .buttonStyle(.borderedProminent)
                .tint(tools.sosRunning ? .gray : .red)
                .accessibilityHint(tools.sosRunning ? "Stops the flashing" : "Starts flashing SOS with the flashlight")

                Toggle(isOn: $screenFlash) {
                    Label("Flash the screen too", systemImage: "iphone.radiowaves.left.and.right")
                }
                .padding(.horizontal, 4)

                if let e = tools.torchError {
                    Label(e, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote).foregroundStyle(.orange)
                }

                InfoCard(title: "When you start SOS", tint: .red, rows: [
                    ("flashlight.on.fill", "The rear flashlight blinks SOS in Morse code at full brightness: 3 short flashes, 3 long, 3 short."),
                    ("timer", "Short flashes last 0.2 s and long flashes 0.6 s. Each round takes 5.4 s, then a 1.4 s pause before it repeats."),
                    ("repeat", "It repeats until you tap Stop Signal."),
                    ("iphone", screenFlash
                        ? "The screen flashes white in time with the light, so it can be seen from the front too."
                        : "The screen stays as it is. Turn on “Flash the screen too” to signal from the front as well."),
                    ("lock.open.fill", "The phone won't auto-lock while SOS runs."),
                ])

                InfoCard(title: "Keep in mind", tint: .orange, rows: [
                    ("phone.down.fill", "SOS does not call 911 or send a message or your location to anyone. It is a light signal only."),
                    ("arrow.uturn.backward", "It stops if you leave DayZero or press the side button to lock the phone. Keep the app open."),
                    ("battery.25", "The flashlight uses a lot of battery. Use it when someone could see it, mostly at night."),
                    ("eye.fill", "Hold the phone up with the back facing the people or aircraft you want to reach."),
                ])

                CallButton(label: "Call 911", phone: "911")
                Text("Calling needs cell service, or Wi-Fi calling.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding()
        }
        .background((screenFlash && lit ? Color.white : Color(.systemBackground)).ignoresSafeArea())
        .navigationTitle("SOS signal")
    }
}

private struct InfoCard: View {
    let title: String
    let tint: Color
    let rows: [(String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            ForEach(rows, id: \.1) { symbol, text in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: symbol)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(tint)
                        .frame(width: 24)
                    Text(text).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Screen light

struct ScreenLightLauncher: View {
    @State private var showing = false
    @State private var red = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Button { red = false; showing = true } label: {
                Label("White light", systemImage: "sun.max.fill").frame(maxWidth: .infinity, minHeight: 70)
            }
            .buttonStyle(.borderedProminent).tint(.gray)
            Button { red = true; showing = true } label: {
                Label("Red light (night vision)", systemImage: "moon.fill").frame(maxWidth: .infinity, minHeight: 70)
            }
            .buttonStyle(.borderedProminent).tint(.red)
            Text("Fills the screen at full brightness. Red light keeps your eyes adjusted to the dark. Tap the light to switch color.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Spacer()
        }
        .font(.title3.weight(.semibold))
        .padding(32)
        .navigationTitle("Screen light")
        .fullScreenCover(isPresented: $showing) { ScreenLight(red: $red) }
    }
}

struct ScreenLight: View {
    @Binding var red: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var previousBrightness: CGFloat = 0.5

    var body: some View {
        (red ? Color(red: 1, green: 0, blue: 0) : Color.white)
            .ignoresSafeArea()
            .onTapGesture { red.toggle() }
            .overlay(alignment: .bottom) {
                Button("Done") { dismiss() }
                    .font(.headline)
                    .padding(.horizontal, 28).padding(.vertical, 12)
                    .background(.black.opacity(0.25), in: Capsule())
                    .foregroundStyle(.black.opacity(0.7))
                    .padding(.bottom, 30)
            }
            .statusBarHidden()
            .persistentSystemOverlays(.hidden)
            .onAppear {
                previousBrightness = UIScreen.main.brightness
                UIScreen.main.brightness = 1
                UIApplication.shared.isIdleTimerDisabled = true
            }
            .onDisappear {
                UIScreen.main.brightness = previousBrightness
                if !ToolController.shared.sosRunning { UIApplication.shared.isIdleTimerDisabled = false }
            }
            .accessibilityLabel(red ? "Red screen light" : "White screen light")
            .accessibilityHint("Tap to switch color")
    }
}

// MARK: - Whistle

struct WhistleView: View {
    @State private var tools = ToolController.shared
    @State private var blastTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: tools.whistleOn ? "speaker.wave.3.fill" : "speaker.fill")
                .font(.system(size: 70))
                .foregroundStyle(tools.whistleOn ? .orange : .secondary)
                .symbolEffect(.variableColor.iterative, isActive: tools.whistleOn)
            Text("Hold to whistle")
                .font(.title2.bold())
                .frame(maxWidth: .infinity, minHeight: 120)
                .background(tools.whistleOn ? Color.orange : Color.orange.opacity(0.25), in: RoundedRectangle(cornerRadius: 24))
                .foregroundStyle(tools.whistleOn ? .white : .primary)
                .onLongPressGesture(minimumDuration: 0, maximumDistance: 80, pressing: { pressing in
                    if pressing { cancelBlasts(); tools.startWhistle() } else { tools.stopWhistle() }
                }, perform: {})
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { tools.whistleOn ? tools.stopWhistle() : tools.startWhistle() }
            Button {
                blastTask == nil ? threeBlasts() : cancelBlasts()
            } label: {
                Label(blastTask == nil ? "Three blasts (distress)" : "Stop", systemImage: "repeat")
                    .frame(maxWidth: .infinity, minHeight: 56)
            }
            .buttonStyle(.bordered)
            Spacer()
            Text("Turn the volume all the way up. Plays even with the ring switch on silent. Three blasts is the international distress signal.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(28)
        .navigationTitle("Whistle")
        .onDisappear { cancelBlasts(); tools.stopWhistle() }
    }

    private func threeBlasts() {
        blastTask = Task { @MainActor in
            while !Task.isCancelled {
                for _ in 0..<3 {
                    tools.startWhistle()
                    try? await Task.sleep(for: .seconds(1))
                    tools.stopWhistle()
                    try? await Task.sleep(for: .seconds(0.6))
                }
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    private func cancelBlasts() {
        blastTask?.cancel()
        blastTask = nil
        tools.stopWhistle()
    }
}

// MARK: - Morse

struct MorseView: View {
    @State private var tools = ToolController.shared
    @AppStorage("morse.text") private var text = "SOS"
    @AppStorage("morse.wpm") private var wpm = 10.0
    @AppStorage("morse.light") private var useLight = true
    @AppStorage("morse.sound") private var useSound = true

    var body: some View {
        Form {
            Section("Message") {
                TextField("Type a message", text: $text, axis: .vertical)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .lineLimit(1...4)
                Text(MorseCode.encode(text).isEmpty ? "—" : MorseCode.encode(text))
                    .font(.title3.monospaced().weight(.semibold))
                    .foregroundStyle(tools.signal == .morse && tools.signalElementOn ? .orange : .primary)
                    .textSelection(.enabled)
            }
            Section("Send by") {
                Toggle("Flashlight", isOn: $useLight)
                Toggle("Sound", isOn: $useSound)
                LabeledContent("Speed") {
                    Stepper("\(Int(wpm)) words/min", value: $wpm, in: 5...25)
                }
            }
            Section {
                Button {
                    tools.signal == .morse ? tools.stopSignal() : tools.sendMorse(text, wpm: wpm, light: useLight, sound: useSound)
                } label: {
                    Label(tools.signal == .morse ? "Stop" : "Send", systemImage: tools.signal == .morse ? "stop.fill" : "play.fill")
                        .frame(maxWidth: .infinity)
                        .font(.headline)
                }
                .disabled(MorseCode.encode(text).isEmpty || (!useLight && !useSound))
            }
            Section("Reference") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), alignment: .leading, spacing: 6) {
                    ForEach(Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789").map(String.init), id: \.self) { ch in
                        Text("\(ch)  \(MorseCode.table[Character(ch)] ?? "")").font(.callout.monospaced())
                    }
                }
            }
        }
        .navigationTitle("Morse code")
        .onDisappear { if tools.signal == .morse { tools.stopSignal() } }
    }
}

// MARK: - Phone dialer

struct DialerView: View {
    @State private var number = ""
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            Section {
                TextField("Phone number", text: $number)
                    .keyboardType(.phonePad)
                    .font(.system(size: 30, weight: .semibold, design: .rounded).monospacedDigit())
                Button {
                    if let url = PhoneLink.url(for: number) { openURL(url) }
                } label: {
                    Label("Call", systemImage: "phone.fill").frame(maxWidth: .infinity).font(.headline)
                }
                .disabled(PhoneLink.url(for: number) == nil)
            } footer: {
                Text("Opens the iPhone dialer. Calling needs cell service, or Wi-Fi calling.")
            }
            Section {
                CallButton(label: "Call 911", phone: "911", prominent: true)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Phone")
    }
}
