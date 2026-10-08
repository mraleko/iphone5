"""End-to-end conversion checks; requires ffmpeg/ffprobe and a built app."""
import json
import pathlib
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
APP = ROOT / "iPhone 5 Generator.app/Contents/MacOS/iPhone5Generator"
FFMPEG = shutil.which("ffmpeg")
FFPROBE = shutil.which("ffprobe")


def run(*args):
    result = subprocess.run(list(map(str, args)), capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(f"Command failed: {args}\n{result.stderr}")
    return result


def generate(path, size="640x360", audio=True, hdr=None):
    args = [FFMPEG, "-v", "error", "-f", "lavfi", "-i", f"testsrc2=size={size}:rate=60:duration=0.6"]
    if audio:
        args += ["-f", "lavfi", "-i", "sine=frequency=1000:sample_rate=48000:duration=0.6", "-ac", "2", "-c:a", "aac"]
    if hdr:
        args += ["-vf", f"zscale=pin=bt709:tin=bt709:min=bt709:p=bt2020:t={hdr}:m=bt2020nc,format=yuv420p10le",
                 "-c:v", "libx265", "-preset", "ultrafast", "-x265-params", "log-level=error",
                 "-color_primaries", "bt2020", "-color_trc", hdr, "-colorspace", "bt2020nc"]
    else:
        args += ["-c:v", "libx264", "-pix_fmt", "yuv420p"]
    run(*args, path)


def check(source, destination, size, audio=True):
    run(APP, "--convert", source, destination)
    info = json.loads(run(FFPROBE, "-v", "error", "-show_streams", "-show_format", "-of", "json", destination).stdout)
    video = next(s for s in info["streams"] if s["codec_type"] == "video")
    assert (video["width"], video["height"]) == size, video
    assert video["codec_name"] == "h264"
    assert video["pix_fmt"] == "yuv420p"
    assert video["r_frame_rate"] == "30/1"
    assert video["color_transfer"] == "bt709"
    assert video["color_primaries"] == "bt709"
    assert video["color_range"] == "tv"
    assert abs(float(info["format"]["duration"]) - 0.6) < 0.12
    tracks = [s for s in info["streams"] if s["codec_type"] == "audio"]
    assert bool(tracks) == audio
    if audio:
        assert tracks[0]["channels"] == 1
        assert tracks[0]["sample_rate"] == "44100"
        assert tracks[0]["codec_name"] == "aac"
    run(FFMPEG, "-v", "error", "-i", destination, "-f", "null", "-")
    print(f"PASS: {source.name}")


with tempfile.TemporaryDirectory(prefix="iphone5-smoke-") as folder:
    temp = pathlib.Path(folder)
    landscape = temp / "landscape with spaces.mov"
    generate(landscape)
    check(landscape, temp / "landscape-out.mov", (1920, 1080))
    portrait = temp / "portrait.mov"
    generate(portrait, size="360x640")
    check(portrait, temp / "portrait-out.mov", (1080, 1920))
    rotated = temp / "rotation-metadata.mov"
    run(FFMPEG, "-v", "error", "-display_rotation:v:0", "90", "-i", landscape, "-c", "copy", rotated)
    check(rotated, temp / "rotated-out.mov", (1080, 1920))
    silent = temp / "silent-square.mp4"
    generate(silent, size="480x480", audio=False)
    check(silent, temp / "silent-out.mov", (1080, 1080), audio=False)
    for transfer in ("arib-std-b67", "smpte2084"):
        hdr = temp / f"hdr-{transfer}.mov"
        generate(hdr, hdr=transfer)
        check(hdr, temp / f"hdr-{transfer}-out.mov", (1920, 1080))
    corrupt = temp / "broken.mov"
    corrupt.write_text("not a video")
    result = subprocess.run([str(APP), "--convert", str(corrupt), str(temp / "broken-out.mov")], capture_output=True)
    assert result.returncode != 0
    assert not (temp / "broken-out.mov").exists()
    print("PASS: invalid input rejected")
    existing = temp / "existing.mov"
    existing.write_text("keep me")
    result = subprocess.run([str(APP), "--convert", str(landscape), str(existing)], capture_output=True)
    assert result.returncode != 0
    assert existing.read_text() == "keep me"
    print("PASS: existing output protected")

print("All conversion checks passed.")
