import AVFoundation
import Observation
import OSLog
import UIKit

/// The rear LED. Needs a real iPhone; the Simulator has no torch.
enum Torch {
    private static let log = Logger(subsystem: AppInfo.bundleID, category: "torch")

    static var device: AVCaptureDevice? {
        guard let d = AVCaptureDevice.default(for: .video), d.hasTorch else { return nil }
        return d
    }

    static var isAvailable: Bool { device?.isTorchAvailable ?? false }

    @discardableResult
    static func set(_ on: Bool, level: Float = 1) -> Bool {
        guard let d = device else { return false }
        do {
            try d.lockForConfiguration()
            defer { d.unlockForConfiguration() }
            if on {
                try d.setTorchModeOn(level: min(1, max(0.05, level)))
            } else {
                d.torchMode = .off
            }
            return true
        } catch {
            log.error("Torch failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}

/// A sine tone through the speaker, for the whistle and Morse sound.
/// Uses the playback audio category so it sounds even with the ring switch on silent.
final class ToneGenerator {
    static let shared = ToneGenerator()

    private var engine: AVAudioEngine?
    private var phase: Double = 0
    // Read on the audio thread; simple values are fine for an on/off gate.
    private var frequency: Double = 3150
    private var gateOn = false
    private var level: Double = 0

    var isRunning: Bool { engine?.isRunning ?? false }

    func start(frequency: Double) {
        self.frequency = frequency
        if engine == nil { build() }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        if !(engine?.isRunning ?? false) { try? engine?.start() }
    }

    /// Turns the tone on or off without restarting the engine (fast enough for Morse).
    func gate(_ on: Bool) { gateOn = on }

    func stop() {
        gateOn = false
        engine?.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func build() {
        let engine = AVAudioEngine()
        let format = engine.outputNode.inputFormat(forBus: 0)
        let sampleRate = format.sampleRate
        let mono = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let source = AVAudioSourceNode { [unowned self] _, _, frameCount, bufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            let step = 2 * Double.pi * self.frequency / sampleRate
            for frame in 0..<Int(frameCount) {
                // Short ramp avoids clicks when gating.
                let target = self.gateOn ? 0.9 : 0
                self.level += (target - self.level) * 0.01
                let sample = Float(sin(self.phase) * self.level)
                self.phase += step
                if self.phase > 2 * .pi { self.phase -= 2 * .pi }
                for buffer in buffers {
                    buffer.mData?.assumingMemoryBound(to: Float.self)[frame] = sample
                }
            }
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: mono)
        engine.mainMixerNode.outputVolume = 1
        self.engine = engine
    }
}

/// Shared state for the light and sound tools, so the grid shows what's on
/// and quick actions can drive them.
@Observable
final class ToolController {
    static let shared = ToolController()

    enum Signal: Equatable { case sos, morse }

    private(set) var torchOn = false
    var torchLevel: Float = UserDefaults.standard.object(forKey: "torch.level") as? Float ?? 1 {
        didSet {
            UserDefaults.standard.set(torchLevel, forKey: "torch.level")
            if torchOn { Torch.set(true, level: torchLevel) }
        }
    }
    private(set) var signal: Signal?
    /// True while the current signal element is lit/sounding (drives on-screen flashes).
    private(set) var signalElementOn = false
    private(set) var whistleOn = false
    private(set) var torchError: String?

    private var signalTask: Task<Void, Never>?

    var sosRunning: Bool { signal == .sos }
    var torchAvailable: Bool { Torch.isAvailable }

    // MARK: Flashlight

    func setTorch(_ on: Bool) {
        if signal != nil { stopSignal() }
        if Torch.set(on, level: torchLevel) {
            torchOn = on
            torchError = nil
        } else if on {
            torchOn = false
            torchError = "This device has no flashlight."
        } else {
            torchOn = false
        }
    }

    func toggleTorch() { setTorch(!torchOn) }

    // MARK: SOS and Morse

    func startSOS() {
        play(MorseCode.timeline("SOS"), unit: 0.2, light: true, sound: false, repeats: true, kind: .sos)
        UIApplication.shared.isIdleTimerDisabled = true // keep the screen awake while signalling
    }

    func toggleSOS() { sosRunning ? stopSignal() : startSOS() }

    func sendMorse(_ text: String, wpm: Double, light: Bool, sound: Bool) {
        let t = MorseCode.timeline(text)
        guard !t.isEmpty else { return }
        play(t, unit: MorseCode.unitSeconds(wpm: wpm), light: light, sound: sound, repeats: false, kind: .morse)
    }

    func stopSignal() {
        signalTask?.cancel()
        signalTask = nil
        finishSignal()
    }

    private func play(_ timeline: [MorseCode.Element], unit: Double, light: Bool, sound: Bool, repeats: Bool, kind: Signal) {
        stopSignal()
        if torchOn { Torch.set(false); torchOn = false }
        if whistleOn { stopWhistle() }
        if light && !Torch.isAvailable { torchError = "This device has no flashlight. Use sound or the screen." }
        signal = kind
        if sound { ToneGenerator.shared.start(frequency: 700) }
        signalTask = Task { @MainActor [weak self] in
            repeat {
                for element in timeline {
                    guard !Task.isCancelled else { return }
                    switch element {
                    case .on(let units):
                        self?.signalElementOn = true
                        if light { Torch.set(true, level: 1) }
                        if sound { ToneGenerator.shared.gate(true) }
                        try? await Task.sleep(for: .seconds(Double(units) * unit))
                    case .off(let units):
                        self?.signalElementOn = false
                        if light { Torch.set(false) }
                        if sound { ToneGenerator.shared.gate(false) }
                        try? await Task.sleep(for: .seconds(Double(units) * unit))
                    }
                }
            } while repeats && !Task.isCancelled
            if !Task.isCancelled { self?.finishSignal() }
        }
    }

    private func finishSignal() {
        if signal != nil {
            Torch.set(false)
            ToneGenerator.shared.gate(false)
            ToneGenerator.shared.stop()
        }
        signal = nil
        signalElementOn = false
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // MARK: Whistle

    func startWhistle() {
        if signal != nil { stopSignal() }
        ToneGenerator.shared.start(frequency: 3150) // near a pea whistle's pitch, carries well
        ToneGenerator.shared.gate(true)
        whistleOn = true
    }

    func stopWhistle() {
        ToneGenerator.shared.gate(false)
        ToneGenerator.shared.stop()
        whistleOn = false
    }

    // MARK: App lifecycle

    /// The LED turns off when DayZero leaves the screen. SOS keeps the screen awake,
    /// so it only stops if the user actually leaves the app.
    func appDidEnterBackground() {
        stopSignal()
        if torchOn { Torch.set(false); torchOn = false }
        if whistleOn { stopWhistle() }
    }
}
