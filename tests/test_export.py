import fcntl
import importlib.util
import json
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import unittest
import wave

SPEC = importlib.util.spec_from_file_location("export", Path(__file__).parents[1] / "scripts/export.py")
module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(module)


@unittest.skipUnless(shutil.which("ffmpeg"), "FFmpeg required")
class ExportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def fragment(self, name, value, seconds=0.25):
        wav = self.root / "fixture.wav"
        with wave.open(str(wav), "wb") as output:
            output.setparams((1, 2, module.RATE, 0, "NONE", ""))
            output.writeframes(struct.pack("<h", value) * round(seconds * module.RATE))
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(wav), str(self.root / name)], check=True)

    def manifest(self, fragments, duration=2, state="completed"):
        (self.root / "meeting.json").write_text(json.dumps({"version": 1, "state": state, "duration": duration, "fragments": fragments}))

    def samples(self):
        data = subprocess.run(["ffmpeg", "-v", "error", "-i", str(self.root / "meeting.m4a"),
                               "-map", "0:a:0", "-f", "s16le", "-"],
                              check=True, capture_output=True).stdout
        return struct.unpack("<%dh" % (len(data) // 2), data)

    def test_delayed_start_pause_and_shared_end(self):
        self.fragment("mic.caf", 8000)
        self.fragment("mic2.caf", 12000)
        self.fragment("remote.caf", 16000)
        self.manifest([
            {"file": "mic.caf", "track": "microphone", "start": 0.25},
            {"file": "mic2.caf", "track": "microphone", "start": 1.25},
            {"file": "remote.caf", "track": "system", "start": 0.75},
        ])
        result = module.export(self.root)
        audio = self.samples()
        self.assertEqual(len(audio), 32000)
        self.assertEqual(audio[1000], 0)
        self.assertEqual(audio[5000], 4000)
        self.assertEqual(audio[15000], 8000)
        self.assertEqual(audio[21000], 6000)
        self.assertEqual(audio[18000], 0)
        self.assertEqual(result["warnings"], [])
        probe = json.loads(subprocess.check_output(["ffprobe", "-v", "error", "-show_streams",
                                                   "-of", "json", str(self.root / "meeting.m4a")]))
        self.assertEqual(len(probe["streams"]), 1)
        self.assertEqual([s["codec_name"] for s in probe["streams"]], ["alac"])
        self.assertEqual([s["tags"]["handler_name"] for s in probe["streams"]], ["Meeting mix"])
        for stream in probe["streams"]:
            self.assertEqual(float(stream["start_time"]), 0)
            self.assertEqual(float(stream["duration"]), 2)
        for name in ("microphone.wav", "system.wav", "meeting.wav", "meeting-transcription.wav"):
            self.assertFalse((self.root / name).exists())

    def test_recover_uncheckpointed_tail_and_missing_track(self):
        self.fragment("mic.caf", 8000, 1)
        self.manifest([{"file": "mic.caf", "track": "microphone", "start": 0, "duration": 0}], duration=0, state="recording")
        result = module.export(self.root)
        self.assertEqual(result["duration"], 1)
        self.assertEqual(len(result["warnings"]), 2)
        self.assertTrue((self.root / "mic.caf").is_file())

    def test_simultaneous_sources_are_mixed_without_clipping(self):
        self.fragment("mic.caf", 30000, 1)
        self.fragment("remote.caf", 20000, 1)
        self.manifest([{"file": "mic.caf", "track": "microphone", "start": 0},
                       {"file": "remote.caf", "track": "system", "start": 0}], duration=1)
        result = module.export(self.root)
        self.assertEqual(self.samples()[100], 25000)
        self.assertEqual(result["audio_tracks"], ["mixed"])

    def test_named_recording_and_repeat_export(self):
        self.root = self.root / "2026-10-23_14-30-00-ABC123"
        self.root.mkdir()
        self.fragment("mic.caf", 8000, 1)
        self.manifest([{"file": "mic.caf", "track": "microphone", "start": 0}], duration=1)
        (self.root / "captions.jsonl").write_text(json.dumps({"track": "microphone", "start": 0.1, "end": 0.8, "text": "测试字幕"}) + "\n")
        (self.root / "captions-status.json").write_text(json.dumps({"state": "completed"}))
        report = module.export(self.root, title="  项目周会 / 需求讨论  ")
        self.assertEqual(report["file"], "项目周会 _ 需求讨论_2026-10-23_14-30-00.m4a")
        self.assertTrue((self.root / report["file"]).is_file())
        self.assertEqual(report["subtitle_file"], "项目周会 _ 需求讨论_2026-10-23_14-30-00.srt")
        self.assertIn("我：测试字幕", (self.root / report["subtitle_file"]).read_text())
        self.assertFalse((self.root / "meeting.m4a").exists())
        repeated = module.export(self.root)
        self.assertEqual(repeated["file"], report["file"])
        self.assertEqual(repeated["title"], "项目周会 / 需求讨论")
        self.assertEqual(repeated["subtitle_file"], report["subtitle_file"])
        unnamed = module.export(self.root, title="")
        self.assertEqual(unnamed["file"], "meeting.m4a")
        self.assertTrue((self.root / "meeting.srt").is_file())
        self.assertTrue((self.root / report["file"]).is_file())

    def test_filename_sanitization(self):
        for title in ("../../逃逸", "a\nb", "会议" * 200, "...", "主题.m4a"):
            filename = module.recording_filename(title)
            self.assertEqual(Path(filename).name, filename)
            self.assertNotIn("\n", filename)
            self.assertLessEqual(len(filename.encode("utf-8")), 164)
        self.assertEqual(module.recording_filename("主题.m4a"), "主题.m4a")
        self.assertEqual(module.recording_filename("..."), "meeting.m4a")
        self.assertEqual(module.recording_filename("项目周会", "2026-10-23_14-30-00"),
                         "项目周会_2026-10-23_14-30-00.m4a")
        self.assertEqual(module.recording_start_stamp(Path("2026-10-23_14-30-00-ABC123"), {}),
                         "2026-10-23_14-30-00")

    def test_bad_subtitles_do_not_lose_audio(self):
        self.fragment("mic.caf", 8000, 1)
        self.manifest([{"file": "mic.caf", "track": "microphone", "start": 0}], duration=1)
        (self.root / "captions.jsonl").write_text(json.dumps({"track": "unknown", "text": "坏数据"}))
        report = module.export(self.root)
        self.assertTrue((self.root / "meeting.m4a").is_file())
        self.assertIsNone(report["subtitle_file"])
        self.assertIn("字幕记录无效", report["subtitle_error"])

    def test_reject_active_recording(self):
        with (self.root / "capture.lock").open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            with self.assertRaises(BlockingIOError):
                module.export(self.root)

    def test_reject_unsafe_and_invalid_inputs(self):
        for filename, start in [("../outside.caf", 0), ("missing.caf", 0)]:
            self.manifest([{"file": filename, "track": "microphone", "start": start}])
            with self.assertRaises(ValueError):
                module.export(self.root)

    def test_overlapping_fragments_do_not_shift_following_audio(self):
        self.fragment("a.caf", 8000, 0.5)
        self.fragment("b.caf", 12000, 0.5)
        self.manifest([{"file": "a.caf", "track": "microphone", "start": 0},
                       {"file": "b.caf", "track": "microphone", "start": 0.25}], duration=0.75)
        module.export(self.root)
        audio = self.samples()
        self.assertEqual(len(audio), 12000)
        self.assertEqual(audio[6000], 4000)
        self.assertEqual(audio[9000], 6000)


if __name__ == "__main__":
    unittest.main()
