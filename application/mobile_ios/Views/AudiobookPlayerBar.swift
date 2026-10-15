import SwiftUI

struct AudiobookPlayerBar: View {
    @ObservedObject var manager = AudiobookManager.shared

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

            HStack(spacing: 12) {
                // Provider Badge
                HStack(spacing: 4) {
                    if manager.isPlaying {
                        Image(systemName: "waveform")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Color(hex: "38bdf8"))
                    } else {
                        Image(systemName: "headphones")
                            .font(.system(size: 11))
                            .foregroundColor(.gray)
                    }

                    Text(manager.provider == "device" ? "Offline" : manager.provider.capitalized)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.8))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.08))
                .cornerRadius(12)

                // Navigation & Play Controls
                HStack(spacing: 8) {
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

                // Sentence Progress
                Text(manager.sentences.isEmpty ? "0 / 0" : "\(manager.currentSentenceIndex + 1) / \(manager.sentences.count)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(Color(hex: "cbd5e1"))

                Divider()
                    .frame(height: 16)
                    .background(Color.white.opacity(0.15))

                // Mode Menu
                Menu {
                    ForEach(AudiobookLanguageMode.allCases, id: \.self) { m in
                        Button(action: {
                            manager.changeMode(m)
                        }) {
                            HStack {
                                Text(m.title)
                                if manager.mode == m {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Text(manager.mode.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(6)
                }

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
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(6)
                }

                // Close Button
                Button(action: {
                    manager.close()
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.gray)
                        .padding(6)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 30)
                    .fill(Color(hex: "0f172a").opacity(0.88))
                    .overlay(
                        RoundedRectangle(cornerRadius: 30)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.35), radius: 16, x: 0, y: 8)
            )
        }
        .padding(.bottom, 16)
    }
}
