import SwiftUI

struct RecordingPlaybackView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var playback: RecordingPlayback
    let title: String

    init(audio: URL, title: String) {
        self.title = title
        _playback = StateObject(wrappedValue: RecordingPlayback(audio: audio))
    }

    var body: some View {
        VStack(spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: "waveform").font(.title2).foregroundStyle(.blue)
                    .frame(width: 44, height: 44).background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.title2.bold()).lineLimit(1).help(title)
                    Text("录音回听 · 点击字幕可跳转到对应位置").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("当前字幕", systemImage: "captions.bubble").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("字幕字号").font(.caption).foregroundStyle(.secondary)
                    Slider(value: $playback.fontSize, in: 20...36, step: 1).frame(width: 90).accessibilityLabel("回听字幕字号")
                }
                ScrollView {
                    Text(currentCaption).font(.system(size: playback.fontSize, weight: .medium)).lineSpacing(8)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(playback.activeCues.isEmpty ? .secondary : .primary)
                }.frame(height: 115)
            }.padding(20).background(.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))

            VStack(spacing: 10) {
                Slider(value: $playback.position, in: 0...max(1, playback.duration), onEditingChanged: { editing in
                    playback.scrubbing = editing
                    if !editing { playback.seek(to: playback.position) }
                }).accessibilityLabel("播放进度").disabled(!playback.ready)
                HStack {
                    Text(PlaybackTranscript.time(playback.position))
                    Spacer()
                    Text(PlaybackTranscript.time(playback.duration))
                }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                HStack(spacing: 24) {
                    Color.clear.frame(width: 108, height: 1).accessibilityHidden(true)
                    Spacer(minLength: 0)
                    Button { playback.seek(to: playback.position - 10) } label: {
                        Image(systemName: "gobackward.10").font(.title2)
                    }.help("后退 10 秒 · ←").keyboardShortcut(.leftArrow, modifiers: [])
                        .accessibilityLabel("后退十秒")
                    Button { playback.toggle() } label: {
                        Image(systemName: playback.playing ? "pause.fill" : "play.fill")
                            .font(.system(size: 22, weight: .semibold)).frame(width: 54, height: 54)
                            .foregroundStyle(.white).background(.blue, in: Circle())
                    }.keyboardShortcut(.space, modifiers: [])
                        .accessibilityLabel(playback.playing ? "暂停播放" : "继续播放")
                    Button { playback.seek(to: playback.position + 10) } label: {
                        Image(systemName: "goforward.10").font(.title2)
                    }.help("前进 10 秒 · →").keyboardShortcut(.rightArrow, modifiers: [])
                        .accessibilityLabel("前进十秒")
                    Spacer(minLength: 0)
                    Picker("倍速", selection: $playback.speed) {
                        Text("0.75×").tag(Float(0.75))
                        Text("1×").tag(Float(1))
                        Text("1.25×").tag(Float(1.25))
                        Text("1.5×").tag(Float(1.5))
                        Text("2×").tag(Float(2))
                    }.frame(width: 108)
                }.buttonStyle(.plain).disabled(!playback.ready)
            }

            Divider()
            HStack {
                Text("完整字幕").font(.headline)
                Text("\(playback.cues.count) 条").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Toggle("跟随播放", isOn: $playback.followPlayback).toggleStyle(.switch).controlSize(.small)
            }
            if !playback.error.isEmpty {
                Label(playback.error, systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            if playback.cues.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "text.bubble").font(.title).foregroundStyle(.tertiary)
                    Text(playback.ready ? "这场录音暂无可用字幕" : "正在读取录音……").foregroundStyle(.secondary)
                    Text(playback.captionWarning.isEmpty ? "可使用进度条和前后跳转回听音频" : playback.captionWarning)
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                transcript
            }
        }.padding(24).frame(width: 780, height: 720)
            .task { await playback.load() }
            .onDisappear { playback.close() }
    }

    private var currentCaption: String {
        let active = playback.activeCues
        if !active.isEmpty { return active.map(\.text).joined(separator: "\n") }
        if !playback.ready { return playback.error.isEmpty ? "正在准备录音……" : "录音暂时无法播放" }
        if playback.cues.isEmpty { return "专心回听，随时暂停" }
        return playback.position >= playback.duration - 0.1 ? "播放结束，可点击字幕重新回听" : "此处没有字幕，继续聆听…"
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(playback.cues) { cue in
                        let active = cue.start <= playback.position && playback.position < cue.end
                        Button { playback.seek(to: cue.start) } label: {
                            HStack(alignment: .top, spacing: 14) {
                                Text(PlaybackTranscript.time(cue.start)).font(.caption.monospacedDigit())
                                    .foregroundStyle(active ? .blue : .secondary).frame(width: 56, alignment: .leading).padding(.top, 3)
                                Text(cue.text).font(.system(size: 16)).lineSpacing(4)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: active ? "waveform" : "play.circle").foregroundStyle(active ? .blue : .secondary)
                            }.padding(12).contentShape(Rectangle())
                                .background(active ? Color.blue.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain).id(cue.id)
                            .accessibilityLabel("\(PlaybackTranscript.time(cue.start))，\(cue.text)，点击跳转")
                    }
                }
            }
            .onScrollPhaseChange { _, phase in
                if phase == .tracking || phase == .interacting { playback.followPlayback = false }
            }
            .onChange(of: playback.focusedCue?.id) {
                if playback.followPlayback, let id = playback.focusedCue?.id { proxy.scrollTo(id, anchor: .center) }
            }
            .onChange(of: playback.followPlayback) {
                if playback.followPlayback, let id = playback.focusedCue?.id { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }
}
