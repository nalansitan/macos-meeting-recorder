import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("export", Path(__file__).parents[1] / "scripts/export.py")
export = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(export)


class SubtitleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.target = self.root / "项目周会.srt"

    def render(self, cues, duration=20, state="completed"):
        (self.root / "captions.jsonl").write_text("".join(json.dumps(c, ensure_ascii=False) + "\n" for c in cues))
        (self.root / "captions-status.json").write_text(json.dumps({"state": state, "errors": []}))
        return export.subtitle_export(self.root, self.target, duration)

    def cue(self, track, start, end, text):
        return dict(track=track, start=start, end=end, text=text)

    def test_named_speakers_keep_sides_and_rename_export(self):
        record = {"model": "fixture", "speakers": [
            {"id": "m1", "track": "microphone", "number": 1, "name": "张三"},
            {"id": "s1", "track": "system", "number": 1, "name": "李四"}]}
        (self.root / "speakers.json").write_text(json.dumps(record))
        turns = [{"track": "microphone", "speakerID": "m1", "start": 1, "end": 4},
                 {"track": "system", "speakerID": "s1", "start": 1, "end": 4}]
        (self.root / "speaker-turns.jsonl").write_text("\n".join(map(json.dumps, turns)))
        cues = [self.cue("microphone", 1, 4, "本地"), self.cue("system", 1, 4, "远端")]
        self.render(cues)
        self.assertIn("我方 · 张三：本地\n会议方 · 李四：远端", self.target.read_text())
        record["speakers"][1]["name"] = "王五"
        (self.root / "speakers.json").write_text(json.dumps(record))
        self.render(cues)
        self.assertIn("会议方 · 王五", self.target.read_text())
        self.assertNotIn("李四", self.target.read_text())

    def test_ambiguous_turn_does_not_invent_name(self):
        (self.root / "speakers.json").write_text(json.dumps({"speakers": []}))
        turns = [{"track": "system", "speakerID": person, "start": 0, "end": 4} for person in ["a", "b"]]
        (self.root / "speaker-turns.jsonl").write_text("\n".join(map(json.dumps, turns)) + "\n{broken")
        self.render([self.cue("system", 0, 4, "混合发言")])
        self.assertIn("会议方 · 多人/待确认", self.target.read_text())

    def test_switch_splits_timed_words_but_legacy_stays_uncertain(self):
        (self.root / "speakers.json").write_text(json.dumps({"speakers": [
            {"id": "a", "number": 1, "name": "张三"}, {"id": "b", "number": 2, "name": "李四"}]}))
        turns = [{"track": "system", "speakerID": "a", "start": 0, "end": 3},
                 {"track": "system", "speakerID": "b", "start": 3, "end": 4}]
        (self.root / "speaker-turns.jsonl").write_text("\n".join(map(json.dumps, turns)))
        cue = self.cue("system", 0, 4, "说完了好的")
        self.render([cue])
        self.assertIn("多人/待确认：说完了好的", self.target.read_text())
        cue["tokens"] = [{"start": 0, "end": 3, "text": "说完了"},
                         {"start": 3, "end": 4, "text": "好的"}]
        count, _ = self.render([cue])
        self.assertEqual(count, 2)
        text = self.target.read_text()
        self.assertIn("张三：说完了", text)
        self.assertIn("李四：好的", text)
        self.assertIn("00:00:03,000 --> 00:00:04,000", text)
        cue["tokens"][0]["end"] = 3.5  # Invalid overlapping word times must not lose text.
        self.render([cue])
        self.assertIn("多人/待确认：说完了好的", self.target.read_text())

    def test_overlap_is_two_lines_without_overlapping_cues(self):
        count, warnings = self.render([self.cue("microphone", 1, 4, "我先说"), self.cue("system", 2, 5, "好的")])
        self.assertEqual(count, 3)
        self.assertEqual(warnings, [])
        self.assertEqual(self.target.read_text(), "1\n00:00:01,000 --> 00:00:02,000\n我：我先说\n\n"
                         "2\n00:00:02,000 --> 00:00:04,000\n我：我先说\n会议对方：好的\n\n"
                         "3\n00:00:04,000 --> 00:00:05,000\n会议对方：好的\n\n")

    def test_shared_timeline_preserves_gaps_and_clamps_to_audio(self):
        count, _ = self.render([self.cue("microphone", 8.123, 13, "晚开始"), self.cue("system", -0.5, 1, "开始")], duration=10)
        text = self.target.read_text()
        self.assertEqual(count, 2)
        self.assertIn("00:00:00,000 --> 00:00:01,000", text)
        self.assertIn("00:00:08,123 --> 00:00:10,000", text)

    def test_incomplete_and_empty_are_explicit(self):
        count, warnings = self.render([], state="running")
        self.assertEqual(count, 0)
        self.assertEqual(len(warnings), 2)
        self.assertEqual(self.target.read_text(), "")

    def test_legacy_recordings_have_no_invented_subtitle(self):
        self.assertEqual(export.subtitle_export(self.root, self.target, 10), (None, []))
        self.assertFalse(self.target.exists())

    def test_invalid_times_fail(self):
        for start, end in [(float("nan"), 2), (1, float("inf")), (3, 2)]:
            with self.assertRaisesRegex(ValueError, "时间戳"):
                self.render([self.cue("microphone", start, end, "坏数据")])

    def test_truncated_journal_recovers_confirmed_prefix(self):
        self.render([self.cue("system", 2, 3, "已落盘")], state="failed")
        with (self.root / "captions.jsonl").open("a") as stream:
            stream.write('{"track":')
        count, warnings = export.subtitle_export(self.root, self.target, 10)
        self.assertEqual(count, 1)
        self.assertEqual(len(warnings), 2)


if __name__ == "__main__":
    unittest.main()
