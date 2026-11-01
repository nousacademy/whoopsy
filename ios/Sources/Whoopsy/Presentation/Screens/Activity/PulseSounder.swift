import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

/// A click on every pulse the metronome draws, at the same rate and from the same clock.
///
/// **The sound is part of the measurement, not decoration.** A rate read by eye alone is hard to match
/// against a felt rhythm at the slow end and impossible at the fast end — past about three a second the
/// square is a shimmer — so the click carries the beat the eye cannot resolve. It is generated rather
/// than bundled: a short sine burst with a fast decay, synthesised once, because an eighth bundled
/// resource for one 40 ms tone would be a file to ship and a `Bundle.module` lookup to fail.
///
/// **Nothing here decides the rate.** `PulseTiming.secondsUntilNextPulse` owns the timing, from the same
/// phase the square is lit from, so a click and a flash cannot drift apart; this type only waits and
/// plays. That split is what lets §26 assert the cadence — a rule written into an audio callback is a
/// rule the runner cannot see.
///
/// **It obeys the silent switch.** The session category is `.ambient`, so a phone on silent stays
/// silent and any music already playing keeps playing; a metronome that overrode the ringer would be a
/// surprise in a sheet the user opened to type a note.
@MainActor
final class PulseSounder {

    #if canImport(AVFoundation)
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var click: AVAudioPCMBuffer?
    private var isPrepared = false
    #endif

    /// Plays a click on every pulse until the task is cancelled — which is what `.task(id: rate)`
    /// does when the gauge moves or the sheet closes.
    func run(ratePerMinute: Double) async {
        guard ratePerMinute > 0 else { return }
        prepareIfNeeded()
        while !Task.isCancelled {
            let now = Date().timeIntervalSinceReferenceDate
            let wait = PulseTiming.secondsUntilNextPulse(at: now, ratePerMinute: ratePerMinute)
            // The sleep is what re-reads the clock; the next iteration recomputes from it, so a late
            // wake cannot accumulate into drift the way a fixed-interval timer would.
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled else { return }
            play()
        }
    }

    /// Stops the engine when the metronome is no longer on screen.
    ///
    /// The task's cancellation stops the clicks; this stops the audio hardware, which otherwise keeps a
    /// running engine alive behind a closed sheet.
    func finish() {
        #if canImport(AVFoundation)
        player.stop()
        engine.stop()
        #endif
    }

    // MARK: - The click

    #if canImport(AVFoundation)
    private func prepareIfNeeded() {
        guard !isPrepared else { return }
        isPrepared = true

        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        // `.ambient` respects the silent switch and mixes with whatever is already playing.
        try? session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
        #endif

        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)
        guard let format,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2_205) else { return }
        // 50 ms: long enough to be heard as a tick, short enough that two clicks never overlap at the
        // 500/min ceiling, where a whole period is 120 ms.
        buffer.frameLength = 2_205
        if let samples = buffer.floatChannelData?[0] {
            let rate = format.sampleRate
            for frame in 0..<Int(buffer.frameLength) {
                let t = Double(frame) / rate
                let envelope = exp(-t * 90)
                samples[frame] = Float(sin(2 * .pi * 1_000 * t) * envelope * 0.35)
            }
        }
        click = buffer

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        try? engine.start()
        player.play()
    }

    private func play() {
        guard let click, engine.isRunning else { return }
        player.scheduleBuffer(click, at: nil, options: [])
        if !player.isPlaying { player.play() }
    }
    #else
    private func prepareIfNeeded() {}
    private func play() {}
    #endif
}
