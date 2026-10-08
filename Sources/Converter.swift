import Foundation

struct ConversionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum ConversionProgress {
    case rendering(frames: Int, fraction: Double?)
    case finalizing
    case finished
}

// One instance per job. The lock allows the UI to cancel a running child process.
final class Converter: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        if let process, process.isRunning { process.terminate() }
        lock.unlock()
    }

    private func executable(_ name: String) throws -> URL {
        let paths = [Bundle.main.resourceURL?.appendingPathComponent(name).path,
                     "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"]
            .compactMap { $0 }
        for path in paths where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        throw ConversionError(message: "FFmpeg is required. Install it with ‘brew install ffmpeg’, then try again.")
    }

    private func run(_ name: String, _ arguments: [String], onLine: ((String) -> Void)? = nil) throws -> Data {
        let task = Process()
        task.executableURL = try executable(name)
        task.arguments = arguments
        // Use files rather than pipes so verbose decoders cannot deadlock or fill memory.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stdout = directory.appendingPathComponent("stdout")
        let stderr = directory.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: stdout.path, contents: nil)
        FileManager.default.createFile(atPath: stderr.path, contents: nil)
        let out = try FileHandle(forWritingTo: stdout)
        let err = try FileHandle(forWritingTo: stderr)
        let reader = try FileHandle(forReadingFrom: stdout)
        defer { try? out.close(); try? err.close(); try? reader.close() }
        var pending = Data()
        func readProgress() {
            guard let data = try? reader.read(upToCount: 65536), !data.isEmpty else { return }
            pending.append(data)
            while let newline = pending.firstIndex(of: 10) {
                let line = String(decoding: pending[..<newline], as: UTF8.self)
                pending.removeSubrange(...newline)
                onLine?(line)
            }
        }
        task.standardOutput = out
        task.standardError = err
        task.standardInput = FileHandle.nullDevice
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        do { try task.run() } catch { lock.unlock(); throw error }
        process = task
        lock.unlock()
        if onLine != nil {
            // Poll only the newly written progress bytes on the worker queue.
            // File-backed output avoids pipe backpressure during long renders.
            while task.isRunning {
                readProgress()
                Thread.sleep(forTimeInterval: 0.15)
            }
            readProgress()
        }
        task.waitUntilExit()
        lock.lock()
        process = nil
        let wasCancelled = cancelled
        lock.unlock()
        if wasCancelled { throw CancellationError() }
        guard task.terminationStatus == 0 else {
            let handle = try FileHandle(forReadingFrom: stderr)
            defer { try? handle.close() }
            let size = try handle.seekToEnd()
            try handle.seek(toOffset: size > 6000 ? size - 6000 : 0)
            let detail = String(data: try handle.readToEnd() ?? Data(), encoding: .utf8) ?? "Unknown error"
            throw ConversionError(message: "Couldn’t process this video.\n\n\(detail)")
        }
        return try Data(contentsOf: stdout)
    }

    func convert(input: URL, output: URL, onProgress: @escaping (ConversionProgress) -> Void = { _ in }) throws {
        guard input.isFileURL else { throw ConversionError(message: "Choose a video stored on this Mac.") }
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw ConversionError(message: "The output file already exists. Choose a new filename.")
        }
        let metadata = try run("ffprobe", ["-v", "error", "-show_streams", "-show_format", "-of", "json", input.path])
        let root = try JSONSerialization.jsonObject(with: metadata) as? [String: Any]
        let streams = root?["streams"] as? [[String: Any]] ?? []
        guard let video = streams.first(where: {
            $0["codec_type"] as? String == "video" &&
            (($0["disposition"] as? [String: Any])?["attached_pic"] as? Int ?? 0) == 0
        }), let index = video["index"] as? Int else {
            throw ConversionError(message: "This file doesn’t contain a playable video. Try a MOV or MP4 file.")
        }
        let transfer = video["color_transfer"] as? String ?? ""
        let hdr = transfer == "arib-std-b67" || transfer == "smpte2084"
        let hasAudio = streams.contains { $0["codec_type"] as? String == "audio" }
        let format = root?["format"] as? [String: Any]
        let duration = [video["duration"], format?["duration"]]
            .compactMap { $0 as? String }.compactMap(Double.init)
            .first { $0.isFinite && $0 > 0 }
        // Output is constant 30 fps, including frame duplication/drop for VFR
        // input. Audio timestamps can run ahead, so never use out_time here.
        let expectedFrames = duration.map { max(1, ceil($0 * 30)) }
        onProgress(.rendering(frames: 0, fraction: expectedFrames == nil ? nil : 0))

        // Autorotation happens before filters. Fit the displayed image inside a
        // landscape/portrait 1080p envelope, preserving framing and square pixels.
        var filters = [
            "fps=30",
            "scale=w='max(2,trunc(iw*sar/2)*2)':h=ih:flags=bicubic", "setsar=1",
            "scale=w='if(gte(iw,ih),1920,1080)':h='if(gte(iw,ih),1080,1920)':force_original_aspect_ratio=decrease:force_divisible_by=2:flags=bicubic", "setsar=1"
        ]
        if hdr {
            // iPhone 15 Dolby Vision profile 8 has an HLG-compatible base layer.
            // Work in linear light, then map to SDR rather than merely relabeling it.
            filters += [
                "zscale=t=linear:npl=100", "format=gbrpf32le",
                "zscale=p=bt709", "tonemap=tonemap=mobius:param=0.3:desat=2",
                "zscale=t=bt709:m=bt709:r=limited", "format=yuv420p"
            ]
        } else {
            // Convert known wide-gamut SDR correctly; ordinary untagged video is
            // treated as Rec.709, which is the normal phone-video convention.
            let primaries = video["color_primaries"] as? String ?? "bt709"
            let matrix = video["color_space"] as? String ?? "bt709"
            let p = primaries == "unknown" ? "bt709" : primaries
            let m = matrix == "unknown" ? "bt709" : matrix
            let t = transfer.isEmpty || transfer == "unknown" ? "bt709" : transfer
            let range = video["color_range"] as? String == "pc" ? "full" : "limited"
            filters += ["zscale=pin=\(p):tin=\(t):min=\(m):rin=\(range):p=bt709:t=bt709:m=bt709:r=limited", "format=yuv420p"]
        }
        // TikTok reference: darker low/mid tones, clipped stage lighting,
        // saturated colour and softer motion/detail. Temporal blending is an
        // approximation of motion smear, not recovered shutter exposure.
        filters += [
            "tmix=frames=2:weights='3 1'",
            "gblur=sigma=1.1:steps=2",
            "unsharp=5:5:0.15:3:3:0",
            "eq=saturation=1.12",
            "curves=master='0/0 0.10/0.04 0.25/0.20 0.45/0.50 0.65/0.85 0.76/1 1/1'",
            "format=yuv420p"
        ]
        // Only bright pixels feed the halo. Add luminance, not chroma, so the
        // bloom cannot turn dark regions purple or wash the whole image grey.
        // Grain is temporal and weighted toward shadows, with weaker chroma
        // noise and much less luma noise on already clipped highlights.
        var graph = [
            "[0:\(index)]" + filters.joined(separator: ",") + ",split=2[detail][highlights]",
            "[highlights]lutyuv=y='16+max(0,val-175)*2':u=128:v=128,gblur=sigma=14:steps=2[halo]",
            "[detail][halo]blend=c0_expr='min(235,A+0.25*(B-16))':c1_expr=A:c2_expr=A,split=2[clean][grain]",
            "[grain]noise=c0s=12:c0f=t+u:c1s=6:c1f=t+u:c2s=6:c2f=t+u:all_seed=5[noisy]",
            "[clean][noisy]blend=c0_expr='A+(B-A)*(1-0.8*clip((A-16)/219,0,1))':c1_expr='A+0.65*(B-A)':c2_expr='A+0.65*(B-A)',limiter=min=16:max=235:planes=1,format=yuv420p,setparams=range=limited:color_primaries=bt709:color_trc=bt709:colorspace=bt709[video]"
        ].joined(separator: ";")
        if hasAudio {
            // Retain the reference's vocal/crowd presence with modest bass emphasis;
            // overload loud passages and compress their envelope, not all
            // high frequencies. Tuned using measured decoded AAC output.
            graph += ";[0:a:0]" + [
                "aformat=channel_layouts=mono", "highpass=f=85:p=2",
                "bass=g=3:f=160:t=q:w=0.7", "equalizer=f=1400:t=q:w=0.7:g=3",
                "aeval=exprs='clip(val(0)*3,-0.7,0.7)':c=mono",
                "treble=g=3:f=900:t=q:w=0.7", "lowpass=f=9500:p=2",
                "acompressor=threshold=0.15:ratio=4:attack=10:release=140:makeup=1.5",
                "volume=0.72", "alimiter=limit=0.6:level=false:latency=true"
            ].joined(separator: ",") + "[audio]"
        }
        var arguments = ["-hide_banner", "-loglevel", "error", "-nostdin", "-nostats",
                         "-progress", "pipe:1", "-stats_period", "0.25", "-n", "-i", input.path,
                         "-filter_complex", graph,
                         "-map", "[video]", "-map_metadata", "-1", "-map_chapters", "-1",
                         "-c:v", "libx264", "-preset", "medium", "-profile:v", "high", "-level:v", "4.1",
                         "-b:v", "4M", "-maxrate", "6M", "-bufsize", "8M", "-g", "30",
                         "-pix_fmt", "yuv420p", "-color_primaries", "bt709", "-color_trc", "bt709",
                         "-colorspace", "bt709", "-color_range", "tv"]
        if hasAudio {
            arguments += ["-map", "[audio]", "-c:a", "aac", "-b:a", "64k", "-ar", "44100", "-ac", "1"]
        }
        arguments += ["-metadata:s:v:0", "rotate=0", "-movflags", "+faststart", "-f", "mov", output.path]
        var frames = 0
        var finalizing = false
        _ = try run("ffmpeg", arguments) { line in
            if line.hasPrefix("frame="), let count = Int(line.dropFirst(6).trimmingCharacters(in: .whitespaces)) {
                frames = max(frames, count)
            } else if line.hasPrefix("progress=") {
                if line == "progress=end" || expectedFrames.map({ Double(frames) >= $0 }) == true {
                    finalizing = true
                    onProgress(.finalizing)
                } else if !finalizing {
                    onProgress(.rendering(frames: frames, fraction: expectedFrames.map { min(0.99, Double(frames) / $0) }))
                }
            }
        }
        // Do not report completion on a progress=end record alone: the child
        // must exit successfully, including fast-start muxing and disk writes.
        onProgress(.finished)
    }
}
