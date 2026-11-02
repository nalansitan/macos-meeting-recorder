#!/usr/bin/env python3
"""Recover CAF fragments onto their shared timeline; keep all source recordings."""
import argparse
import bisect
from datetime import datetime
import re
import fcntl
import json
import math
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import wave

RATE = 16000
MAX_SECONDS = 8 * 3600


def silence(output, frames):
    while frames:
        count = min(frames, RATE)
        output.writeframesraw(b"\0\0" * count)
        frames -= count


def validate(folder, manifest):
    if manifest.get("version") != 1:
        raise ValueError("不支持的录音清单版本")
    duration = float(manifest.get("duration", 0))
    if not math.isfinite(duration) or not 0 <= duration <= MAX_SECONDS:
        raise ValueError("导出支持最多 8 小时的录音")
    fragments = manifest.get("fragments", [])
    if not fragments:
        raise ValueError("没有已保存的音频片段，请检查录音权限")
    for item in fragments:
        if item["track"] not in {"microphone", "system"}:
            raise ValueError("未知音轨")
        name = item["file"]
        if not isinstance(name, str) or Path(name).name != name:
            raise ValueError("无效的片段路径")
        file = (folder / name).resolve()
        if file.parent != folder or not file.is_file():
            raise ValueError("音频片段缺失或不在录音目录内：" + name)
        start = float(item["start"])
        if not math.isfinite(start) or not 0 <= start <= MAX_SECONDS:
            raise ValueError("音频片段的时间戳无效")
    return fragments, duration


def track_export(folder, fragments, track, output_path, ffmpeg, temporary):
    cursor = 0
    with wave.open(str(output_path), "wb") as output:
        output.setparams((1, 2, RATE, 0, "NONE", "not compressed"))
        for item in sorted((f for f in fragments if f["track"] == track), key=lambda f: f["start"]):
            decoded = temporary / "fragment.pcm"
            subprocess.run([ffmpeg, "-nostdin", "-v", "error", "-y", "-i", str(folder / item["file"]),
                            "-vn", "-ac", "1", "-ar", str(RATE), "-f", "s16le", str(decoded)],
                           check=True, capture_output=True, timeout=120)
            start = round(float(item["start"]) * RATE)
            if start > cursor:
                silence(output, start - cursor)
                cursor = start
            # Real decoded length is authoritative, including the last fragment
            # whose manifest checkpoint may predate an unexpected process exit.
            with decoded.open("rb") as source:
                source.seek(max(0, cursor - start) * 2)
                while data := source.read(128 * 1024):
                    if cursor + len(data) // 2 > MAX_SECONDS * RATE:
                        raise ValueError("导出支持最多 8 小时的录音")
                    output.writeframesraw(data)
                    cursor += len(data) // 2
    return cursor


def recording_start_stamp(folder, manifest):
    # The native folder stores the local start time, including for older recordings.
    match = re.match(r"^(\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2})(?:-|$)", folder.name)
    if match:
        datetime.strptime(match.group(1), "%Y-%m-%d_%H-%M-%S")
        return match.group(1)
    created = manifest.get("created")
    if not created:
        raise ValueError("录音缺少开始时间，无法按主题和时间命名")
    return datetime.fromisoformat(created.replace("Z", "+00:00")).astimezone().strftime("%Y-%m-%d_%H-%M-%S")


def recording_filename(title, started=None):
    cleaned = "".join("_" if c in '/\\:*?"<>|' or ord(c) < 32 else c for c in title).strip(" .")
    if cleaned.lower().endswith(".m4a"):
        cleaned = cleaned[:-4].rstrip(" .")
    while len(cleaned.encode("utf-8")) > 160:
        cleaned = cleaned[:-1]
    suffix = "_" + started if started and title.strip() else ""
    return (cleaned or "meeting") + suffix + ".m4a"


def speaker_labeler(folder):
    """Use per-recording mappings; never read the private cross-recording voice library."""
    metadata = folder / "speakers.json"
    timeline = folder / "speaker-turns.jsonl"
    if not metadata.exists() or not timeline.exists():
        return lambda track, start, end: "我" if track == "microphone" else "会议对方"
    record = json.loads(metadata.read_text())
    speakers = {item["id"]: item for item in record.get("speakers", [])}
    tracks = {"microphone": [], "system": []}
    for line in timeline.read_text().splitlines():
        try:
            item = json.loads(line)
            a, b = float(item["start"]), float(item["end"])
            if item["track"] in tracks and math.isfinite(a) and math.isfinite(b) and b > a:
                tracks[item["track"]].append(item)
        except (ValueError, KeyError, TypeError):
            continue  # A crash may leave one incomplete journal line.
    for items in tracks.values():
        items.sort(key=lambda item: item["start"])
    starts = {track: [item["start"] for item in items] for track, items in tracks.items()}
    longest = {track: max((item["end"] - item["start"] for item in items), default=0) for track, items in tracks.items()}

    def label(track, start, end):
        side = "我方" if track == "microphone" else "会议方"
        scores = {}
        first = bisect.bisect_left(starts[track], start - longest[track])
        last = bisect.bisect_left(starts[track], end)
        for item in tracks[track][first:last]:
            overlap = min(end, item["end"]) - max(start, item["start"])
            if overlap > 0:
                key = item["speakerID"]
                scores[key] = scores.get(key, 0) + overlap
        ranked = sorted(scores.items(), key=lambda item: item[1], reverse=True)
        if (not ranked or ranked[0][1] < min(0.3, (end - start) * 0.5)
                or len(ranked) > 1):
            return side + (" · 多人/待确认" if len(ranked) > 1 else " · 待识别")
        person = speakers.get(ranked[0][0])
        if not person:
            return side + " · 待识别"
        name = person.get("name") or "说话人%d" % person["number"]
        return side + " · " + " ".join(name.split())
    label.tracks = tracks
    return label


def split_by_speaker(cue, label):
    tokens = cue.get("tokens")
    if not isinstance(tokens, list) or not tokens:
        return [cue]
    previous_end = cue["start"]
    try:
        if "".join(token["text"] for token in tokens) != cue["text"]:
            return [cue]
        for token in tokens:
            a, b = token["start"], token["end"]
            if not (math.isfinite(a) and math.isfinite(b) and a >= previous_end and b > a and b <= cue["end"]):
                return [cue]
            previous_end = b
    except (KeyError, TypeError, ValueError):
        return [cue]
    turns = getattr(label, "tracks", {}).get(cue["track"], [])
    groups, previous = [], None
    for token in tokens:
        identities = frozenset(turn["speakerID"] for turn in turns
                               if min(token["end"], turn["end"]) > max(token["start"], turn["start"]))
        if identities == previous:
            groups[-1]["end"] = token["end"]
            groups[-1]["text"] += token["text"]
        else:
            groups.append(dict(track=cue["track"], start=token["start"], end=token["end"], text=token["text"]))
        previous = identities
    return groups


def subtitle_export(folder, destination, duration):
    """Use confirmed, capture-clock timestamps; render overlap as simultaneous lines."""
    journal = folder / "captions.jsonl"
    if not journal.exists():
        return None, []
    warnings = []
    status_path = folder / "captions-status.json"
    status = json.loads(status_path.read_text()) if status_path.exists() else {}
    if status.get("state") != "completed":
        warnings.append("字幕识别未完整结束，仅导出已确认文字；" + "；".join(status.get("errors", [])))
    label = speaker_labeler(folder)
    events = {}
    for index, line in enumerate(journal.read_text().splitlines()):
        if not line.strip():
            continue
        try:
            cue = json.loads(line)
        except json.JSONDecodeError:
            warnings.append("字幕记录第 %d 行损坏，未导出该行" % (index + 1))
            continue
        if cue.get("track") not in {"microphone", "system"} or not isinstance(cue.get("text"), str):
            raise ValueError("字幕记录无效")
        start, end = float(cue["start"]), float(cue["end"])
        if not math.isfinite(start) or not math.isfinite(end) or end <= start:
            raise ValueError("字幕时间戳无效")
        cue["start"], cue["end"] = start, end
        for part, cue in enumerate(split_by_speaker(cue, label)):
            start, end = round(max(0, cue["start"]) * 1000), round(min(duration, cue["end"]) * 1000)
            text = " ".join(cue["text"].split())
            if not text or end <= start:
                continue
            item = (cue["track"], text, label(cue["track"], start / 1000, end / 1000))
            events.setdefault(start, []).append(((index, part), item))
            events.setdefault(end, []).append(((index, part), None))
    active, intervals = {}, []
    times = sorted(events)
    for i, time in enumerate(times[:-1]):
        for index, item in events[time]:
            if item is None:
                active.pop(index, None)
            else:
                active[index] = item
        if not active:
            continue
        lines = []
        for track, speaker in [("microphone", "我"), ("system", "会议对方")]:
            by_speaker = {}
            for _, item in sorted(active.items()):
                if item[0] == track:
                    by_speaker.setdefault(item[2], []).append(item[1])
            for name, texts in by_speaker.items():
                lines.append(name + "：" + " ".join(texts))
        body = "\n".join(lines)
        if intervals and intervals[-1][1] == time and intervals[-1][2] == body:
            intervals[-1] = (intervals[-1][0], times[i + 1], body)
        else:
            intervals.append((time, times[i + 1], body))

    def stamp(milliseconds):
        seconds, ms = divmod(milliseconds, 1000)
        minutes, seconds = divmod(seconds, 60)
        hours, minutes = divmod(minutes, 60)
        return "%02d:%02d:%02d,%03d" % (hours, minutes, seconds, ms)

    destination.write_text("".join("%d\n%s --> %s\n%s\n\n" % (i, stamp(start), stamp(end), text)
                                 for i, (start, end, text) in enumerate(intervals, 1)), encoding="utf-8")
    if not intervals:
        warnings.append("未获得已确认文字，SRT 为空；请检查音源、识别语言或字幕错误提示")
    return len(intervals), warnings


def export(folder, ffmpeg=None, title=None):
    folder = Path(folder).resolve()
    ffmpeg = ffmpeg or shutil.which("ffmpeg") or "/opt/homebrew/bin/ffmpeg"
    if not Path(ffmpeg).is_file():
        raise ValueError("未找到 FFmpeg，请安装后重试")
    with (folder / "export.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        # The native recorder holds this lock throughout recording and pause.
        with (folder / "capture.lock").open("a") as capture_lock:
            fcntl.flock(capture_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            if title is None:
                previous = folder / "export.json"
                title = json.loads(previous.read_text()).get("title", "") if previous.exists() else ""
            title = title.strip()
            manifest = json.loads((folder / "meeting.json").read_text())
            started = recording_start_stamp(folder, manifest) if title else None
            filename = recording_filename(title, started)
            fragments, duration = validate(folder, manifest)
            if shutil.disk_usage(folder).free < max(512 * 1024**2, duration * RATE * 2 * 4):
                raise ValueError("磁盘可用空间不足以导出，请保留原始片段并清理空间")
            with tempfile.TemporaryDirectory(prefix=".export-", dir=folder) as tmp:
                temporary = Path(tmp)
                counts = {}
                for track in ("microphone", "system"):
                    counts[track] = track_export(folder, fragments, track, temporary / (track + ".wav"), ffmpeg, temporary)
                if not any(counts.values()):
                    raise ValueError("音频片段没有可解码的采样")
                total = max(round(duration * RATE), *counts.values())
                # Pad each track to the same end time; do not compact pauses.
                for track, count in counts.items():
                    source_path = temporary / (track + ".wav")
                    padded = temporary / (track + "-padded.wav")
                    with wave.open(str(source_path), "rb") as source, wave.open(str(padded), "wb") as target:
                        target.setparams(source.getparams())
                        while data := source.readframes(RATE * 4):
                            target.writeframesraw(data)
                        silence(target, total - count)
                    padded.replace(source_path)
                subprocess.run([ffmpeg, "-nostdin", "-v", "error", "-y",
                                "-i", str(temporary / "microphone.wav"), "-i", str(temporary / "system.wav"),
                                "-filter_complex", "[0:a:0][1:a:0]amix=inputs=2:duration=longest:normalize=1[out]",
                                "-map", "[out]", "-c:a", "alac",
                                "-metadata:s:a:0", "handler_name=Meeting mix",
                                "-movflags", "+faststart", str(temporary / "meeting.m4a")],
                               check=True, capture_output=True, timeout=600)
                warnings = []
                for track, count in counts.items():
                    if count == 0:
                        warnings.append("未收到音轨：" + track + "；请检查权限与输入设备")
                if manifest["state"] != "completed":
                    warnings.append("这是中断录音的恢复导出，请试听最后一个片段")
                subtitle_name = str(Path(filename).with_suffix(".srt"))
                subtitle_count = None
                subtitle_error = None
                try:
                    subtitle_count, subtitle_warnings = subtitle_export(folder, temporary / subtitle_name, total / RATE)
                    warnings.extend(subtitle_warnings)
                except (ValueError, OSError, KeyError, TypeError) as error:
                    subtitle_error = str(error)
                    warnings.append("字幕导出失败，录音仍保存；保留原始字幕记录供重试：" + subtitle_error)
                report = {"duration": total / RATE, "warnings": warnings,
                          "tracks": counts, "source_state": manifest["state"],
                          "file": filename, "title": title, "audio_tracks": ["mixed"],
                          "subtitle_file": subtitle_name if subtitle_count is not None else None,
                          "subtitle_count": subtitle_count, "subtitle_error": subtitle_error}
                (temporary / "export.json").write_text(json.dumps(report, ensure_ascii=False, indent=2))
                os.replace(temporary / "meeting.m4a", folder / filename)
                if subtitle_count is not None:
                    os.replace(temporary / subtitle_name, folder / subtitle_name)
                os.replace(temporary / "export.json", folder / "export.json")
                return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("folder", type=Path)
    parser.add_argument("--title", help="会议名称；留空使用 meeting.m4a，省略则沿用上次名称")
    args = parser.parse_args()
    try:
        result = export(args.folder, title=args.title)
        for warning in result["warnings"]:
            print(warning)
        if result.get("subtitle_file"):
            print("字幕已保存：" + str(args.folder / result["subtitle_file"]))
        print("录音时长：%.1f 秒" % result["duration"])
    except (ValueError, OSError, KeyError, subprocess.SubprocessError) as error:
        detail = getattr(error, "stderr", None)
        raise SystemExit((detail.decode(errors="replace") if detail else str(error))[:2000])


if __name__ == "__main__":
    main()
