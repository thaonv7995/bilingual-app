import SwiftUI

enum VocaLookupPanelMode: Equatable {
    case single(VocaCard)
    case multi(query: String, cards: [VocaCard])
    case notFound(query: String)
}

struct VocaLookupOverlay: View {
    let mode: VocaLookupPanelMode
    let anchor: CGRect
    let containerSize: CGSize
    @Binding var isPlayingAudio: Bool
    let onDismiss: () -> Void
    let onSelectCard: (VocaCard) -> Void
    let onAddToVoca: () -> Void
    let onPlayAudio: (VocaCard) -> Void

    private var anchorX: CGFloat {
        let halfWidth = min(150, max(110, containerSize.width / 2 - 12))
        return min(max(anchor.midX, halfWidth + 12), containerSize.width - halfWidth - 12)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.001)
                .frame(width: containerSize.width, height: containerSize.height)
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }

            Color.clear
                .frame(width: 1, height: 1)
                .position(x: anchorX, y: max(12, anchor.minY))
                .overlay(alignment: .bottom) {
                    panel
                        .fixedSize(horizontal: false, vertical: true)
                        .offset(y: -10)
                }
        }
        .frame(width: containerSize.width, height: containerSize.height)
    }

    @ViewBuilder
    private var panel: some View {
        switch mode {
        case .single(let card):
            singleCardPanel(card)
        case .multi(let query, let cards):
            multiCardPanel(query: query, cards: cards)
        case .notFound(let query):
            notFoundPanel(query: query)
        }
    }

    private func panelChrome<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            content()
        }
        .padding(12)
        .frame(minWidth: 220, maxWidth: min(300, containerSize.width - 24))
        .background(Color.white.opacity(0.97))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.black.opacity(0.1), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 16, x: 0, y: 8)
    }

    private func singleCardPanel(_ card: VocaCard) -> some View {
        panelChrome {
            HStack(alignment: .top) {
                Text(card.word)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(Color(hex: "0f172a"))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(action: { onPlayAudio(card) }) {
                    if isPlayingAudio {
                        ProgressView().scaleEffect(0.8)
                    } else {
                        Text("🔊").font(.system(size: 16))
                    }
                }
                .frame(width: 30, height: 30)
                .background(Color(hex: "e0f2fe"))
                .cornerRadius(8)
                .disabled(isPlayingAudio)
            }

            if !card.displayIpa.isEmpty {
                Text(card.displayIpa)
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "475569"))
            }

            if !card.meaningVi.isEmpty {
                Text(card.meaningVi)
                    .font(.system(size: 13))
                    .foregroundColor(Color(hex: "1e293b"))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func multiCardPanel(query: String, cards: [VocaCard]) -> some View {
        panelChrome {
            Text(query)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(Color(hex: "0f172a"))

            Text("\(cards.count) kết quả trong từ điển")
                .font(.system(size: 12))
                .foregroundColor(Color(hex: "64748b"))

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(cards) { card in
                        Button(action: { onSelectCard(card) }) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(card.word)
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(Color(hex: "0f172a"))
                                    .multilineTextAlignment(.leading)
                                if !card.meaningVi.isEmpty {
                                    Text(card.meaningVi)
                                        .font(.system(size: 11))
                                        .foregroundColor(Color(hex: "475569"))
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(Color(hex: "f8fafc"))
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.black.opacity(0.08), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 220)
        }
    }

    private func notFoundPanel(query: String) -> some View {
        panelChrome {
            Text(query)
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(Color(hex: "0f172a"))

            Text("Chưa có trong từ điển")
                .font(.system(size: 12))
                .foregroundColor(Color(hex: "64748b"))

            Button(action: onAddToVoca) {
                Text("Thêm vào Voca")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color(hex: "2563eb"))
                    .cornerRadius(8)
            }
        }
    }
}
