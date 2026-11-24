import AVFoundation
import SwiftUI

/// Present directly in a sheet. Swiping and previewing only change the draft.
struct ReferenceVoiceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("standalone.speech.voiceID") private var voiceID = ""
    @State private var reader = SpeechReader()
    @State private var draftID = ""
    @State private var options: [Option] = [.systemDefault]

    var body: some View {
        VStack(spacing: 0) {
            Text("朗读音色")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, 26)

            TabView(selection: $draftID) {
                ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                    voicePage(option, palette: palettes[index])
                        .tag(option.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(maxHeight: .infinity)

            pageDots
                .padding(.bottom, 4)

            Button {
                voiceID = draftID
                close()
            } label: {
                Text("确认")
                    .font(.body.weight(.semibold))
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .foregroundStyle(.white)
                    .background(confirmColor, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings.voice.confirm")
            .padding(.horizontal, 24)
            .padding(.bottom, 10)
        }
        .foregroundStyle(ChatTheme.text)
        .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.height(436)])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(38)
        .presentationBackground(colorScheme == .dark ? Color(white: 0.17) : ChatTheme.canvas)
        .onAppear(perform: loadOptions)
        .onChange(of: draftID) { _, _ in reader.stop() }
        .onDisappear { reader.stop() }
        .accessibilityAction(.escape) { close() }
    }

    private func voicePage(_ option: Option, palette: Palette) -> some View {
        ViewThatFits(in: .vertical) {
            voiceCard(option, palette: palette).padding(.top, typeSize.isAccessibilitySize ? 0 : 76)
            voiceCard(option, palette: palette)
            ScrollView {
                voiceCard(option, palette: palette).padding(.vertical, 8)
            }
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func voiceCard(_ option: Option, palette: Palette) -> some View {
        VStack(spacing: 7) {
            Button {
                reader.read(option.sample, voiceID: option.id)
            } label: {
                Capsule()
                    .fill(palette.mid)
                    .overlay {
                        MeshGradient(width: 3, height: 3, points: [
                            .init(0, 0), .init(0.58, 0), .init(1, 0),
                            .init(0, 0.44), .init(0.40, 0.59), .init(1, 0.55),
                            .init(0, 1), .init(0.59, 1), .init(1, 1)
                        ], colors: [
                            palette.light, palette.mid, palette.light,
                            palette.mid, palette.light, palette.mid,
                            palette.light, palette.deep, palette.light
                        ])
                        .clipShape(Capsule())
                    }
                    .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1))
                    .shadow(color: palette.mid.opacity(0.25), radius: 18, y: 4)
                    .overlay {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Color.black.opacity(0.64))
                    }
                    .frame(width: 162, height: 90)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("试听")
            .accessibilityHint("播放系统朗读示例，不更改设置")
            .accessibilityIdentifier("settings.voice.preview")
            .padding(.bottom, 12)

            Group {
                if let name = option.name { Text(verbatim: name) }
                else { Text("系统默认") }
            }
            .font(.headline)

            if let language = option.language {
                let label = locale.localizedString(forIdentifier: language) ?? language
                Group {
                    if option.id.isEmpty { Text("系统默认 · \(label)") }
                    else { Text("\(label) · iOS 系统音色") }
                }
                .font(.subheadline)
                .foregroundStyle(ChatTheme.muted)
            } else {
                Text("iOS 系统朗读")
                    .font(.subheadline)
                    .foregroundStyle(ChatTheme.muted)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    private var pageDots: some View {
        HStack(spacing: 0) {
            if options.count > 1 {
                ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                    Button {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
                            draftID = option.id
                        }
                    } label: {
                        Circle()
                            .fill(draftID == option.id ? ChatTheme.accent : ChatTheme.muted.opacity(0.55))
                            .frame(width: 6, height: 6)
                            .frame(width: typeSize.isAccessibilitySize ? 44 : 15, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("第 \(index + 1) 个音色，共 \(options.count) 个")
                    .accessibilityAddTraits(draftID == option.id ? .isSelected : [])
                }
            }
        }
        .frame(height: 44)
    }

    private func close() {
        reader.stop()
        dismiss()
    }

    private func loadOptions() {
        let installed = AVSpeechSynthesisVoice.speechVoices().filter {
            !$0.voiceTraits.contains(.isPersonalVoice) && !$0.voiceTraits.contains(.isNoveltyVoice)
        }
        // An empty ID uses SpeechReader's Mandarin-first system fallback. Only name
        // the fallback voice if the OS reports it in the available system catalog.
        let fallbackID = AVSpeechSynthesisVoice(language: "zh-CN")?.identifier
        let fallback = installed.first { $0.identifier == fallbackID }
        let system = Option(id: "", name: fallback?.name, language: fallback?.language)
        let candidates = installed.filter {
            $0.identifier == voiceID || $0.language.hasPrefix("zh") || $0.language.hasPrefix("en")
        }.sorted { lhs, rhs in
            if (lhs.identifier == voiceID) != (rhs.identifier == voiceID) { return lhs.identifier == voiceID }
            let left = languageRank(lhs.language), right = languageRank(rhs.language)
            if left != right { return left < right }
            if lhs.quality != rhs.quality { return lhs.quality.rawValue > rhs.quality.rawValue }
            let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
            return nameOrder == .orderedSame ? lhs.identifier < rhs.identifier : nameOrder == .orderedAscending
        }

        var choices = [system]
        var seen = Set<String>()
        if let fallback { seen.insert("\(fallback.name)|\(fallback.language)") }
        for voice in candidates where choices.count < 4 && voice.identifier != fallbackID {
            guard seen.insert("\(voice.name)|\(voice.language)").inserted else { continue }
            choices.append(Option(id: voice.identifier, name: voice.name, language: voice.language))
        }
        options = choices
        draftID = choices.contains { $0.id == voiceID } ? voiceID : ""
    }

    private func languageRank(_ identifier: String) -> Int {
        let preferred = locale.language.languageCode?.identifier ?? "zh"
        if identifier.caseInsensitiveCompare(locale.identifier.replacingOccurrences(of: "_", with: "-")) == .orderedSame { return 0 }
        if identifier.hasPrefix(preferred + "-") { return 1 }
        if identifier == "zh-CN" { return 2 }
        if identifier.hasPrefix("zh") { return 3 }
        if identifier.hasPrefix("en") { return 4 }
        return 5
    }

    private var confirmColor: Color {
        colorScheme == .dark ? Color(red: 0.25, green: 0.41, blue: 0.85) : ChatTheme.accent
    }

    private struct Option: Identifiable {
        let id: String
        let name: String?
        let language: String?

        static let systemDefault = Self(id: "", name: nil, language: nil)

        var sample: String {
            if language?.hasPrefix("en") == true { return "Hello. This is an AmoreChat read-aloud sample." }
            if language?.hasPrefix("zh") == false { return "AmoreChat." }
            return "你好，这是 AmoreChat 的系统朗读示例。"
        }
    }

    private struct Palette {
        let light: Color
        let mid: Color
        let deep: Color

        init(_ light: UInt32, _ mid: UInt32, _ deep: UInt32) {
            func rgb(_ value: UInt32) -> Color {
                Color(red: Double((value >> 16) & 255) / 255,
                      green: Double((value >> 8) & 255) / 255,
                      blue: Double(value & 255) / 255)
            }
            self.light = rgb(light)
            self.mid = rgb(mid)
            self.deep = rgb(deep)
        }
    }

    private let palettes = [
        Palette(0xD7EEFF, 0x8CB5D9, 0x95C4EC),
        Palette(0xCBDCFF, 0x7D9FE8, 0x5477C5),
        Palette(0xFFEACF, 0xF7C768, 0xF7CF82),
        Palette(0xA7CDD5, 0x527E8D, 0x34576A)
    ]
}
