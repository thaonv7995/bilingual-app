import SwiftUI

struct AudiobookPlayerBar: View {
    @ObservedObject var manager = AudiobookManager.shared
    var onMinimize: () -> Void = {}
    var onClose: () -> Void = {}

    var body: some View {
        VStack(spacing: 6) {
            if let err = manager.errorMessage {
                Text(err)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.red.opacity(0.85))
                    .cornerRadius(8)
                    .transition(.opacity)
            }

            HStack(spacing: 8) {
                // Collapse action owns the left curved cap of the player. It is
                // part of the layout, so it never overlaps the waveform or any
                // other control.
                Button(action: onMinimize) {
                    Image(systemName: "pip.exit")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color(hex: "cbd5e1"))
                        .frame(width: 24, height: 24)
                        .background(Color.white.opacity(0.08))
                        .clipShape(Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(.leading, 4)
                .accessibilityLabel("Thu nhỏ trình phát")

                // Audio Status Icon
                ZStack {
                    if manager.isPlaying {
                        Image(systemName: "waveform")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Color(hex: "38bdf8"))
                    } else {
                        Image(systemName: "headphones")
                            .font(.system(size: 11))
                            .foregroundColor(.gray)
                    }
                }
                .frame(width: 24, height: 24)
                .background(Color.white.opacity(0.08))
                .clipShape(Circle())

                // Navigation & Play Controls
                HStack(spacing: 6) {
                    Button(action: {
                        manager.prevSentence()
                    }) {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 12))
                            .foregroundColor(manager.currentSentenceIndex > 0 ? .white : .gray.opacity(0.5))
                            .frame(width: 28, height: 28)
                            .background(Color.white.opacity(0.06))
                            .clipShape(Circle())
                    }
                    .disabled(manager.currentSentenceIndex == 0)

                    Button(action: {
                        if manager.isPlaying {
                            manager.pause()
                        } else {
                            manager.play()
                        }
                    }) {
                        Image(systemName: manager.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 36, height: 36)
                            .background(Color(hex: "2563eb"))
                            .clipShape(Circle())
                            .shadow(color: Color(hex: "2563eb").opacity(0.4), radius: 6, x: 0, y: 3)
                    }

                    Button(action: {
                        manager.nextSentence()
                    }) {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 12))
                            .foregroundColor(manager.currentSentenceIndex < manager.sentences.count - 1 ? .white : .gray.opacity(0.5))
                            .frame(width: 28, height: 28)
                            .background(Color.white.opacity(0.06))
                            .clipShape(Circle())
                    }
                    .disabled(manager.currentSentenceIndex >= manager.sentences.count - 1)
                }

                // Mode Menu
                Menu {
                    Button(action: { manager.changeMode(.en) }) {
                        HStack {
                            Text("EN (Tiếng Anh)")
                            if manager.mode == .en { Image(systemName: "checkmark") }
                        }
                    }
                    Button(action: { manager.changeMode(.vi) }) {
                        HStack {
                            Text("VI (Tiếng Việt)")
                            if manager.mode == .vi { Image(systemName: "checkmark") }
                        }
                    }
                } label: {
                    Text(manager.mode == .en ? "EN" : "VI")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(minWidth: 22)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(6)
                }
                .layoutPriority(1)

                // Speed Menu
                Menu {
                    ForEach(["0.8", "1.0", "1.25", "1.5"], id: \.self) { sp in
                        Button(action: {
                            manager.speed = sp
                        }) {
                            HStack {
                                Text("\(sp)x")
                                if manager.speed == sp {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Text("\(manager.speed)x")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(minWidth: 32)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 3)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(6)
                }
                .layoutPriority(1)

                // Keep the single close action inside the player.
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(Color(hex: "94a3b8"))
                        .frame(width: 24, height: 24)
                        .background(Color.white.opacity(0.08))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Đóng trình phát")
            }
            // The mini button starts exactly at the leading edge and occupies
            // the player's curved cap. The outer clip supplies the same border
            // and corner radius as the rest of the player.
            .padding(.leading, 0)
            .padding(.trailing, 10)
            .frame(minHeight: 52)
            .background(
                RoundedRectangle(cornerRadius: 30)
                    .fill(Color(hex: "0f172a").opacity(0.88))
                    .overlay(
                        RoundedRectangle(cornerRadius: 30)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.35), radius: 16, x: 0, y: 8)
            )
            .clipShape(RoundedRectangle(cornerRadius: 30))
            .overlay(alignment: .top) {
                GeometryReader { proxy in
                    let total = max(manager.sentences.count, 1)
                    let completed = manager.sentences.isEmpty
                        ? 0
                        : min(manager.currentSentenceIndex + 1, total)
                    let progress = CGFloat(completed) / CGFloat(total)

                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.10))

                        Capsule()
                            .fill(Color(hex: "38bdf8"))
                            .frame(width: proxy.size.width * progress)
                    }
                }
                .frame(height: 2)
                .padding(.horizontal, 24)
                .padding(.top, 4)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .padding(.bottom, 16)
    }
}
