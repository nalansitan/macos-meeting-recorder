import AVFoundation
import Foundation

@main struct SoftwareAECSmoke {
    static let rate = 48000
    static let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
    static func pcm(_ values: [Float]) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(values.count))!
        buffer.frameLength = AVAudioFrameCount(values.count)
        buffer.floatChannelData![0].update(from: values, count: values.count)
        return buffer
    }
    static func energy(_ values: ArraySlice<Float>) -> Double {
        values.reduce(0) { $0 + Double($1) * Double($1) } / Double(max(1, values.count))
    }
    static func correlation(_ a: [Float], _ b: [Float], range: Range<Int>) -> Double {
        var best = 0.0
        var bestLag = 0
        for lag in stride(from: -1440, through: 1440, by: 1) {
            var aa = 0.0, bb = 0.0, ab = 0.0
            for i in stride(from: range.lowerBound, to: range.upperBound, by: 4) {
                let x = Double(a[i]), y = Double(b[i + lag])
                aa += x*x; bb += y*y; ab += x*y
            }
            let value = ab / max(1e-20, sqrt(aa*bb))
            if value > best { best = value; bestLag = lag }
        }
        precondition(abs(bestLag) <= 4, "AEC latency compensation no longer matches the pinned library")
        print("Best local-voice alignment: \(bestLag) samples")
        return best
    }
    static func main() throws {
        let total = rate * 18 + 137
        var seed: UInt64 = 123456
        func noise() -> Float {
            seed = seed &* 6364136223846793005 &+ 1
            return Float(Double(seed >> 32) / Double(UInt32.max) * 2 - 1)
        }
        var far = [Float](repeating: 0, count: total)
        var near = far, microphone = far
        var f: Float = 0, n: Float = 0
        for i in 0..<total {
            f = f * 0.78 + noise() * 0.22
            n = n * 0.72 + noise() * 0.28
            let time = Double(i) / Double(rate)
            if time < 12 { far[i] = f * Float(0.35 + 0.15 * sin(time * 3)) }
            if time >= 8 && time < 11 || time >= 13 { near[i] = n * 0.4 }
            microphone[i] = near[i] + (i >= 1920 ? far[i - 1920] * 0.65 : 0)
                + (i >= 3840 ? far[i - 3840] * 0.12 : 0) + noise() * 0.00003
        }
        let processor = try SoftwareEchoCanceller(epoch: 100)
        var output = [Float](repeating: 0, count: total)
        var delivered = 0
        func collect(_ pcm: AVAudioPCMBuffer, _ time: Double) {
            let start = Int(((time - 100) * Double(rate)).rounded())
            let length = Int(pcm.frameLength)
            precondition(start >= 0 && start + length <= total)
            output.replaceSubrange(start..<(start + length), with: UnsafeBufferPointer(start: pcm.floatChannelData![0], count: length))
            delivered += length
        }
        // Deliberately vary packet size, cross 10 ms boundaries and reverse callback order.
        var start = 0, packet = 0
        while start < total {
            let length = min([1024, 480, 997, 240][packet % 4], total - start)
            let end = start + length
            let time = 100 + Double(start) / Double(rate)
            if packet % 2 == 0 {
                try processor.ingest(pcm(Array(microphone[start..<end])), track: "microphone", timestamp: time, deliver: collect)
                try processor.ingest(pcm(Array(far[start..<end])), track: "system", timestamp: time, deliver: collect)
            } else {
                try processor.ingest(pcm(Array(far[start..<end])), track: "system", timestamp: time, deliver: collect)
                try processor.ingest(pcm(Array(microphone[start..<end])), track: "microphone", timestamp: time, deliver: collect)
            }
            start = end; packet += 1
        }
        try processor.finish(deliver: collect)
        precondition(delivered == total, "Dropped or duplicated microphone samples, including tail")
        precondition(processor.missingReferenceFrames == 0)
        let echoRange = (rate * 5)..<(rate * 8)
        let reduction = 10 * log10(energy(microphone[echoRange]) / max(1e-20, energy(output[echoRange])))
        let doubleRange = (rate * 9)..<(rate * 11)
        let nearRange = (rate * 14)..<(rate * 16)
        let doubleCorrelation = correlation(near, output, range: doubleRange)
        let nearCorrelation = correlation(near, output, range: nearRange)
        let doubleGain = sqrt(energy(output[doubleRange]) / energy(near[doubleRange]))
        let nearGain = sqrt(energy(output[nearRange]) / energy(near[nearRange]))
        print(String(format: "AEC3: echo reduction %.1f dB, double-talk correlation %.3f / gain %.3f, near-only correlation %.3f / gain %.3f", reduction, doubleCorrelation, doubleGain, nearCorrelation, nearGain))
        precondition(reduction > 12, "Insufficient echo cancellation")
        precondition(doubleCorrelation > 0.65 && doubleGain > 0.4 && doubleGain < 1.6, "Lost local voice during double talk")
        precondition(nearCorrelation > 0.9 && nearGain > 0.75 && nearGain < 1.25, "Lost local-only voice")
        let tailGain = sqrt(energy(output.suffix(137)) / energy(near.suffix(137)))
        precondition(tailGain > 0.6 && tailGain < 1.4, "Lost final partial-frame local speech")
        // With no reference at all, preserve local input exactly.
        try processor.reset()
        var bypass = [Float]()
        let original = Array(near[(rate * 14)..<(rate * 14 + 1001)])
        try processor.ingest(pcm(original), track: "microphone", timestamp: 101) { buffer, _ in
            bypass += UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
        }
        try processor.finish { buffer, _ in
            bypass += UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
        }
        precondition(bypass == original, "Missing reference must not erase local speech")
        // A very large timestamp discontinuity must not process hours of silence.
        try processor.reset()
        var gapSamples = 0
        for time in [100.0, 3700.0] {
            try processor.ingest(pcm(original), track: "microphone", timestamp: time) { buffer, _ in gapSamples += Int(buffer.frameLength) }
        }
        try processor.finish { buffer, _ in gapSamples += Int(buffer.frameLength) }
        precondition(gapSamples == original.count * 2)
        print("PASS: AEC3 numerical echo reduction, near-end preservation, double talk, packet reordering, exact tail and missing-reference bypass; no audio devices used")
    }
}
