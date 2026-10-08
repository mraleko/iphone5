import Foundation

struct ConversionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
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

    private func run(_ name: String, _ arguments: [String]) throws -> Data {
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
        defer { try? out.close(); try? err.close() }
        task.standardOutput = out
        task.standardError = err
        task.standardInput = FileHandle.nullDevice
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        do { try task.run() } catch { lock.unlock(); throw error }
        process = task
        lock.unlock()
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

    func convert(input: URL, output: URL) throws {
        guard input.isFileURL else { throw ConversionError(message: "Choose a video stored on this Mac.") }
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw ConversionError(message: "The output file already exists. Choose a new filename.")
        }
        let metadata = try run("ffprobe", ["-v", "error", "-show_streams", "-of", "json", input.path])
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
        // Restrained approximation of the older ISP: less fine detail, modest
        // edge enhancement, reduced shadow/highlight latitude and subtle noise.
        // These are aesthetic estimates, not a measured sensor calibration.
        filters += [
            "gblur=sigma=0.45:steps=1",
            "unsharp=5:5:0.35:3:3:0",
            "eq=contrast=1.055:brightness=-0.008:saturation=0.96:gamma=0.985",
            "noise=c0s=2:c0f=t+u:c1s=1:c1f=t+u:c2s=1:c2f=t+u:all_seed=5",
            "format=yuv420p"
        ]
        var arguments = ["-hide_banner", "-loglevel", "error", "-nostdin", "-n", "-i", input.path,
                         "-map", "0:\(index)", "-map", "0:a:0?", "-map_metadata", "-1", "-map_chapters", "-1",
                         "-vf", filters.joined(separator: ","),
                         "-c:v", "libx264", "-preset", "medium", "-profile:v", "high", "-level:v", "4.1",
                         "-b:v", "17M", "-maxrate", "20M", "-bufsize", "34M", "-g", "30",
                         "-pix_fmt", "yuv420p", "-color_primaries", "bt709", "-color_trc", "bt709",
                         "-colorspace", "bt709", "-color_range", "tv"]
        if hasAudio {
            arguments += ["-af", [
                "aformat=channel_layouts=mono", "highpass=f=100:p=2", "lowpass=f=14000:p=2",
                "equalizer=f=2800:t=q:w=0.8:g=1.5",
                "acompressor=threshold=0.125:ratio=2:attack=10:release=180:makeup=1.15",
                "alimiter=limit=0.95:level=false:latency=true"
            ].joined(separator: ","), "-c:a", "aac", "-b:a", "64k", "-ar", "44100", "-ac", "1"]
        }
        arguments += ["-metadata:s:v:0", "rotate=0", "-movflags", "+faststart", "-f", "mov", output.path]
        _ = try run("ffmpeg", arguments)
    }
}
