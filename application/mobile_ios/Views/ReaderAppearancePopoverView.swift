import SwiftUI
import UIKit

struct ReaderAppearancePopoverView: View {
    let effectiveFontId: String
    let effectiveThemeId: String
    let bookDefaultFontId: String
    let bookDefaultThemeId: String
    let hasUserOverride: Bool
    let isSavingDefault: Bool
    let a4Status: ReaderA4Status

    let onSelectFont: (String) -> Void
    let onSelectTheme: (String) -> Void
    let onResetToBookDefault: () -> Void
    let onSaveAsBookDefault: () -> Void
    let onClose: () -> Void

    private var desc: ReaderThemeDescriptor {
        ReaderAppearance.parseThemeDescriptor(effectiveThemeId)
    }

    private var currentFont: ReaderFontOption {
        ReaderAppearance.getFont(effectiveFontId)
    }

    private var currentTheme: ReaderThemeOption {
        ReaderAppearance.getTheme(effectiveThemeId)
    }

    private var currentTexture: ReaderTextureOption {
        ReaderAppearance.textures.first(where: { $0.id == desc.textureId }) ?? ReaderAppearance.textures[0]
    }

    private var isAtBookDefault: Bool {
        !hasUserOverride && effectiveFontId == bookDefaultFontId && effectiveThemeId == bookDefaultThemeId
    }

    private var isAlreadySavedAsBookDefault: Bool {
        effectiveFontId == bookDefaultFontId && effectiveThemeId == bookDefaultThemeId
    }

    private func updateDescriptor(_ mutate: (inout ReaderThemeDescriptor) -> Void) {
        var next = desc
        mutate(&next)
        onSelectTheme(ReaderAppearance.serializeThemeDescriptor(next))
    }

    private func hexString(from color: Color) -> String {
        let uiColor = UIColor(color)
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        guard uiColor.getRed(&r, green: &g, blue: &b, alpha: &a) else {
            return "#374151"
        }
        return String(
            format: "#%02x%02x%02x",
            Int(round(max(0, min(1, r)) * 255)),
            Int(round(max(0, min(1, g)) * 255)),
            Int(round(max(0, min(1, b)) * 255))
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Text("Giao diện & Phông chữ")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(Color(hex: "f8fafc"))

                if hasUserOverride {
                    Text("Tùy chỉnh")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color(hex: "7dd3fc"))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(hex: "38bdf8").opacity(0.16))
                        .overlay(
                            Capsule().stroke(Color(hex: "38bdf8").opacity(0.35), lineWidth: 1)
                        )
                        .clipShape(Capsule())
                }

                Spacer()

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Color(hex: "94a3b8"))
                        .frame(width: 24, height: 24)
                        .background(Color.white.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.02))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 1)
            }

            // Compact Settings List
            ScrollView {
                VStack(spacing: 0) {
                    // 1. Cỡ chữ (Font Scale + A4 Guard)
                    settingRow {
                        HStack(spacing: 5) {
                            Text("Cỡ chữ")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(Color(hex: "cbd5e1"))

                            if a4Status.atMaxA4Scale || a4Status.clampedByA4 {
                                Text("Max A4")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(Color(hex: "fbbf24"))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1.5)
                                    .background(Color(hex: "f59e0b").opacity(0.18))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 4)
                                            .stroke(Color(hex: "f59e0b").opacity(0.38), lineWidth: 1)
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                        }

                        Spacer()

                        let shownScale = a4Status.appliedFontScale
                        HStack(spacing: 0) {
                            Button(action: {
                                updateDescriptor { $0.fontScale = max(80, shownScale - 5) }
                            }) {
                                Text("A−")
                                    .font(.system(size: 11.5, weight: .bold))
                                    .foregroundColor(shownScale <= 80 ? Color.gray.opacity(0.4) : Color(hex: "cbd5e1"))
                                    .frame(width: 34, height: 26)
                            }
                            .disabled(shownScale <= 80)

                            Button(action: {
                                updateDescriptor { $0.fontScale = 100 }
                            }) {
                                Text("\(shownScale)%")
                                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                                    .foregroundColor(Color(hex: "f1f5f9"))
                                    .frame(minWidth: 46, minHeight: 26)
                            }

                            let disablePlus = a4Status.atMaxA4Scale || desc.fontScale >= 140
                            Button(action: {
                                updateDescriptor { $0.fontScale = min(140, shownScale + 5) }
                            }) {
                                Text("A+")
                                    .font(.system(size: 11.5, weight: .bold))
                                    .foregroundColor(disablePlus ? Color.gray.opacity(0.4) : Color(hex: "cbd5e1"))
                                    .frame(width: 34, height: 26)
                            }
                            .disabled(disablePlus)
                        }
                        .background(Color.white.opacity(0.05))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.white.opacity(0.1), lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }

                    // 2. Giãn dòng
                    settingRow {
                        Text("Giãn dòng")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Color(hex: "cbd5e1"))

                        Spacer(minLength: 8)

                        segmentedButtons(
                            options: ReaderAppearance.lineHeightOptions,
                            selected: desc.lineHeight,
                            onSelect: { val in
                                updateDescriptor { $0.lineHeight = val }
                            }
                        )
                    }

                    // 3. Phông chữ
                    settingRow {
                        Text("Phông chữ")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Color(hex: "cbd5e1"))

                        Spacer(minLength: 8)

                        Menu {
                            ForEach(ReaderFontCategory.allCases, id: \.rawValue) { category in
                                let fonts = ReaderAppearance.fonts.filter { $0.category == category }
                                if !fonts.isEmpty {
                                    Section(header: Text(category.groupLabel)) {
                                        ForEach(fonts) { font in
                                            Button(action: {
                                                onSelectFont(font.id)
                                            }) {
                                                HStack {
                                                    Text("\(font.label) — \(font.sublabel)")
                                                    if font.id == effectiveFontId {
                                                        Image(systemName: "checkmark")
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Text(currentFont.label)
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundColor(Color(hex: "f1f5f9"))
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(Color(hex: "94a3b8"))
                            }
                            .padding(.leading, 9)
                            .padding(.trailing, 9)
                            .frame(height: 27)
                            .frame(maxWidth: 195)
                            .background(Color.white.opacity(0.05))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.white.opacity(0.11), lineWidth: 1)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }

                    // 4. Lề trang
                    settingRow {
                        Text("Lề trang")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Color(hex: "cbd5e1"))

                        Spacer(minLength: 8)

                        segmentedButtons(
                            options: ReaderAppearance.pageMarginOptions,
                            selected: desc.pageMargin,
                            onSelect: { val in
                                updateDescriptor { $0.pageMargin = val }
                            }
                        )
                    }

                    // 5. Màu chữ (Ink Color)
                    stackedSettingRow(
                        label: "Màu chữ",
                        hint: ReaderAppearance.inks.first(where: { $0.id == desc.inkColor })?.label
                            ?? (desc.inkColor == "auto" ? "Tự động" : desc.inkColor.uppercased())
                    ) {
                        HStack(spacing: 6) {
                            ForEach(ReaderAppearance.inks) { ink in
                                let isSelected = desc.inkColor == ink.id
                                Button(action: {
                                    updateDescriptor { $0.inkColor = ink.id }
                                }) {
                                    ZStack {
                                        if ink.id == "auto" {
                                            Circle()
                                                .fill(
                                                    LinearGradient(
                                                        colors: [Color(hex: "1e293b"), Color(hex: "475569")],
                                                        startPoint: .topLeading,
                                                        endPoint: .bottomTrailing
                                                    )
                                                )
                                            Text("Auto")
                                                .font(.system(size: 7.5, weight: .bold))
                                                .foregroundColor(.white)
                                        } else {
                                            Circle()
                                                .fill(Color(hex: String(ink.color.dropFirst())))
                                        }
                                    }
                                    .frame(width: 22, height: 22)
                                    .overlay(
                                        Circle()
                                            .stroke(
                                                isSelected ? Color(hex: "38bdf8") : Color.white.opacity(0.28),
                                                lineWidth: isSelected ? 2 : 1.2
                                            )
                                    )
                                }
                                .buttonStyle(.plain)
                            }

                            ColorPicker(
                                "",
                                selection: Binding(
                                    get: {
                                        let hex = ReaderAppearance.isValidHexColor(desc.inkColor)
                                            ? desc.inkColor
                                            : (currentTheme.ink.isEmpty ? "#111827" : currentTheme.ink)
                                        return Color(hex: String(hex.dropFirst()))
                                    },
                                    set: { newColor in
                                        let hex = hexString(from: newColor)
                                        updateDescriptor { $0.inkColor = hex }
                                    }
                                ),
                                supportsOpacity: false
                            )
                            .labelsHidden()
                            .scaleEffect(0.82)
                            .frame(width: 24, height: 24)
                        }
                    }

                    // 6. Màu giấy (Paper Color)
                    stackedSettingRow(
                        label: "Màu giấy",
                        hint: currentTheme.label
                    ) {
                        HStack(spacing: 6) {
                            ForEach(ReaderAppearance.themes) { t in
                                let isSelected = desc.themeId == t.id
                                Button(action: {
                                    updateDescriptor { $0.themeId = t.id }
                                }) {
                                    ZStack {
                                        if t.id == "default" {
                                            Circle()
                                                .fill(
                                                    LinearGradient(
                                                        colors: [Color(hex: "1e293b"), Color(hex: "475569")],
                                                        startPoint: .topLeading,
                                                        endPoint: .bottomTrailing
                                                    )
                                                )
                                            Text("Gốc")
                                                .font(.system(size: 7.5, weight: .bold))
                                                .foregroundColor(.white)
                                        } else {
                                            Circle()
                                                .fill(Color(hex: String(t.paper.dropFirst())))
                                        }
                                    }
                                    .frame(width: 22, height: 22)
                                    .overlay(
                                        Circle()
                                            .stroke(
                                                isSelected ? Color(hex: "38bdf8") : Color.white.opacity(0.28),
                                                lineWidth: isSelected ? 2 : 1.2
                                            )
                                    )
                                }
                                .buttonStyle(.plain)
                            }

                            ColorPicker(
                                "",
                                selection: Binding(
                                    get: {
                                        let hex = ReaderAppearance.isValidHexColor(desc.themeId)
                                            ? desc.themeId
                                            : (currentTheme.paper.isEmpty ? "#fdf8ee" : currentTheme.paper)
                                        return Color(hex: String(hex.dropFirst()))
                                    },
                                    set: { newColor in
                                        let hex = hexString(from: newColor)
                                        updateDescriptor { $0.themeId = hex }
                                    }
                                ),
                                supportsOpacity: false
                            )
                            .labelsHidden()
                            .scaleEffect(0.82)
                            .frame(width: 24, height: 24)
                        }
                    }

                    // 7. Chất liệu giấy (Paper Texture)
                    settingRow {
                        Text("Chất liệu giấy")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Color(hex: "cbd5e1"))

                        Spacer(minLength: 8)

                        Menu {
                            ForEach(ReaderAppearance.textures) { tex in
                                Button(action: {
                                    updateDescriptor { $0.textureId = tex.id }
                                }) {
                                    HStack {
                                        Text("\(tex.label) — \(tex.sublabel)")
                                        if tex.id == desc.textureId {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Text(currentTexture.label)
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundColor(Color(hex: "f1f5f9"))
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(Color(hex: "94a3b8"))
                            }
                            .padding(.leading, 9)
                            .padding(.trailing, 9)
                            .frame(height: 27)
                            .frame(maxWidth: 195)
                            .background(Color.white.opacity(0.05))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.white.opacity(0.11), lineWidth: 1)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
            }
            .frame(maxHeight: 380)

            // Footer
            HStack(spacing: 8) {
                Button(action: onResetToBookDefault) {
                    Text("Về mặc định")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(isAtBookDefault ? Color.gray.opacity(0.45) : Color(hex: "cbd5e1"))
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(Color.white.opacity(0.05))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.white.opacity(0.12), lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .disabled(isAtBookDefault)
                .buttonStyle(.plain)

                Button(action: onSaveAsBookDefault) {
                    Text(
                        isSavingDefault
                            ? "Đang lưu…"
                            : isAlreadySavedAsBookDefault
                                ? "✓ Mặc định sách"
                                : "Lưu mặc định sách"
                    )
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(isAlreadySavedAsBookDefault ? Color.white.opacity(0.55) : .white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 28)
                    .background(
                        LinearGradient(
                            colors: [Color(hex: "0284c7"), Color(hex: "2563eb")],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        .opacity(isAlreadySavedAsBookDefault ? 0.45 : 1.0)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(hex: "38bdf8").opacity(0.4), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .disabled(isSavingDefault || isAlreadySavedAsBookDefault)
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.black.opacity(0.25))
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 1)
            }
        }
        .frame(width: UIDevice.current.userInterfaceIdiom == .phone ? nil : 330)
        .background(Color(hex: "0d1321"))
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func settingRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            content()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.055))
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private func stackedSettingRow<Content: View>(
        label: String,
        hint: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(hex: "cbd5e1"))
                Spacer()
                Text(hint)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(Color(hex: "38bdf8"))
                    .lineLimit(1)
            }
            content()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.055))
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private func segmentedButtons(
        options: [(id: String, label: String)],
        selected: String,
        onSelect: @escaping (String) -> Void
    ) -> some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.id) { opt in
                let active = selected == opt.id
                Button(action: { onSelect(opt.id) }) {
                    Text(opt.label)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(active ? Color(hex: "38bdf8") : Color(hex: "94a3b8"))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 4.5)
                                .fill(active ? Color(hex: "38bdf8").opacity(0.2) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Color.white.opacity(0.05))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.white.opacity(0.09), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

