import Foundation
import os

/// Kick-band onset detector. Runs on the audio thread, sample by sample.
///
/// 40–120 Hz band-pass → 10 ms energy hops → log-energy rise vs. the previous 40 ms
/// → adaptive threshold (median + k·MAD over the last second) → peak pick with a
/// tempo-aware refractory period. Tune it with tools/beat-harness (synthetic track
/// with known kick times, or any audio file).
final class BeatEngine {
    struct Snapshot { var lastBeat: Double; var strength: Double; var interval: Double; var energy: Double }

    private struct Biquad {
        var b0 = 0.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
        var z1 = 0.0, z2 = 0.0
        static func highpass(_ f: Double, _ fs: Double, q: Double = 0.7071) -> Biquad { make(f, fs, q, high: true) }
        static func lowpass(_ f: Double, _ fs: Double, q: Double = 0.7071) -> Biquad { make(f, fs, q, high: false) }
        private static func make(_ f: Double, _ fs: Double, _ q: Double, high: Bool) -> Biquad {
            let w = 2 * Double.pi * f / fs, c = cos(w), alpha = sin(w) / (2 * q), a0 = 1 + alpha
            var bq = Biquad()
            if high { bq.b0 = (1 + c) / 2 / a0; bq.b1 = -(1 + c) / a0 } else { bq.b0 = (1 - c) / 2 / a0; bq.b1 = (1 - c) / a0 }
            bq.b2 = bq.b0; bq.a1 = -2 * c / a0; bq.a2 = (1 - alpha) / a0
            return bq
        }
        @inline(__always) mutating func process(_ x: Double) -> Double {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
    }

    private var hp1: Biquad, hp2: Biquad, lp1: Biquad, lp2: Biquad
    private let hop: Int
    private let hopSeconds: Double
    private var acc = 0.0, count = 0
    private var hops = 0
    private var logRing = [Double](repeating: -100, count: 4)
    private var fluxRing = [Double](repeating: 0, count: 100)
    private var fluxCount = 0
    private var prev1 = 0.0, prev2 = 0.0     // flux[i-1], flux[i-2]
    private var thrPrev = 3.0
    private var lastBeatStream = -1e9
    private var recent: [Double] = []
    private var interval = 0.5

    /// Lower = more sensitive. Written from the main thread, read on the audio thread.
    var sensitivity: Double = 2.2

    private let lock = OSAllocatedUnfairLock(initialState: Snapshot(lastBeat: 0, strength: 0, interval: 0.5, energy: 0))

    init(sampleRate: Double) {
        hp1 = .highpass(40, sampleRate); hp2 = .highpass(40, sampleRate)
        lp1 = .lowpass(120, sampleRate); lp2 = .lowpass(120, sampleRate)
        hop = max(1, Int((sampleRate * 0.01).rounded()))
        hopSeconds = Double(hop) / sampleRate
    }

    var snapshot: Snapshot { lock.withLock { $0 } }

    /// Feed interleaved float samples.
    func process(_ samples: UnsafePointer<Float>, frames: Int, channels: Int) {
        let ch = max(channels, 1)
        for f in 0..<frames {
            var m = 0.0
            for c in 0..<ch { m += Double(samples[f * ch + c]) }
            m /= Double(ch)
            var y = hp1.process(m); y = hp2.process(y); y = lp1.process(y); y = lp2.process(y)
            acc += y * y; count += 1
            if count == hop { endHop(); acc = 0; count = 0 }
        }
    }

    private func endHop() {
        hops += 1
        let now = Double(hops) * hopSeconds
        let energy = acc / Double(hop)
        let L = 10 * log10(energy + 1e-10)
        let mean = logRing.reduce(0, +) / Double(logRing.count)
        let flux = max(0, L - mean)
        logRing.removeFirst(); logRing.append(L)

        // Peak-pick the previous hop (1 hop = 10 ms lookahead).
        let c = prev1
        if fluxCount >= fluxRing.count, c > thrPrev, c >= prev2, c >= flux {
            let tBeat = now - hopSeconds
            let refractory = max(0.2, 0.45 * interval)
            if tBeat - lastBeatStream > refractory {
                if tBeat - lastBeatStream < 1.5 {
                    recent.append(tBeat); if recent.count > 10 { recent.removeFirst() }
                    if recent.count >= 3 {
                        let gaps = zip(recent.dropFirst(), recent).map { $0 - $1 }.sorted()
                        interval = min(max(gaps[gaps.count / 2], 0.3), 1.0)
                    }
                } else {
                    recent = [tBeat]
                }
                lastBeatStream = tBeat
                let strength = min(1, c / (thrPrev * 2.5))
                let wall = ProcessInfo.processInfo.systemUptime - hopSeconds
                let iv = interval
                lock.withLock { $0.lastBeat = wall; $0.strength = strength; $0.interval = iv }
            }
        }

        // Threshold for the current hop, from the history before it.
        let sorted = fluxRing.sorted()
        let med = sorted[sorted.count / 2]
        let mad = fluxRing.map { abs($0 - med) }.sorted()[fluxRing.count / 2] + 1e-6
        thrPrev = max(med + sensitivity * 1.4826 * mad, 3.0)

        fluxRing[fluxCount % fluxRing.count] = flux
        fluxCount += 1
        prev2 = prev1; prev1 = flux
        let e = min(1, max(0, (L + 60) / 50))
        lock.withLock { $0.energy = e }
    }
}
