import SwiftUI
import AppKit

struct ReaderAppearancePopoverMac: View {
    let effectiveFontId: String
    let effectiveThemeId: String
    let bookDefaultFontId: String
    let bookDefaultThemeId: String
    let hasUserOverride: Bool
    let isSavingDefault: Bool

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

    private var saveDefaultButtonTitle: String {
        if isSavingDefault { return "Đang lưu…" }
        if isAlreadySavedAsBookDefault { return "✓ Mặc định sách" }
        return "Lưu mặc định sách"
    }

    private func updateDescriptor(_ mutate: (inout ReaderThemeDescriptor) -> Void) {
        var next = desc
        mutate(&next)
        onSelectTheme(ReaderAppearance.serializeThemeDescriptor(next))
    }

    private func hexString(from color: Color) -> String {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return "#374151" }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rgb.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(
            format: "#%02x%02x%02x",
            Int(round(max(0, min(1, r)) * 255)),
            Int(round(max(0, min(1, g)) * 255)),
            Int(round(max(0, min(1, b)) * 255))
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView

            ScrollView {
                VStack(spacing: 0) {
                    interlinearRow
                    fontScaleRow
                    lineHeightRow
                    fontFamilyRow
                    pageMarginRow
                    inkColorRow
                    paperColorRow
                    textureRow
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 500)

            footerView
        }
        .frame(width: 392)
        .background(Color(hex: "0d1321"))
        .preferredColorScheme(.dark)
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 10) {
            Text("Giao diện & Phông chữ")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color(hex: "f8fafc"))

            if hasUserOverride {
                Text("Tùy chỉnh")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color(hex: "7dd3fc"))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color(hex: "38bdf8").opacity(0.16))
                    .overlay(Capsule().stroke(Color(hex: "38bdf8").opacity(0.35), lineWidth: 1))
                    .clipShape(Capsule())
            }

            Spacer()

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(Color(hex: "94a3b8"))
                    .frame(width: 30, height: 30)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.macInteractive(cornerRadius: 7))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color.white.opacity(0.02))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
        }
    }

    // MARK: - Rows

    private var interlinearRow: some View {
        VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Dịch xen dòng (Interlinear)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(hex: "cbd5e1"))
                    Text("Hiện bản dịch mờ ngay dưới mỗi đoạn")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color(hex: "64748b"))
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { desc.interlinear },
                    set: { enabled in updateDescriptor { $0.interlinear = enabled } }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Color(hex: "38bdf8"))
            }

            if desc.interlinear {
                HStack {
                    Text("Độ đậm dòng dịch")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(hex: "94a3b8"))
                    Spacer()
                    segmentedButtons(
                        options: ReaderAppearance.interlinearOpacityOptions.map { ("\($0.id)", $0.label) },
                        selected: "\(desc.interlinearOpacity)",
                        onSelect: { val in
                            if let n = Int(val) {
                                updateDescriptor { $0.interlinearOpacity = n }
                            }
                        }
                    )
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
        }
    }

    private var fontScaleRow: some View {
        let shownScale = desc.fontScale
        let disableMinus = shownScale <= 60
        let disablePlus = shownScale >= 200

        return settingRow {
            Text("Cỡ chữ")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(hex: "cbd5e1"))

            Spacer()

            HStack(spacing: 0) {
                Button {
                    updateDescriptor { $0.fontScale = max(60, shownScale - 5) }
                } label: {
                    Text("A−")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(disableMinus ? Color.gray.opacity(0.4) : Color(hex: "cbd5e1"))
                        .frame(width: 42, height: 32)
                }
                .buttonStyle(.macRect())
                .disabled(disableMinus)

                Button {
                    updateDescriptor { $0.fontScale = 100 }
                } label: {
                    Text("\(shownScale)%")
                        .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Color(hex: "f1f5f9"))
                        .frame(minWidth: 56, minHeight: 32)
                }
                .buttonStyle(.macRect())

                Button {
                    updateDescriptor { $0.fontScale = min(200, shownScale + 5) }
                } label: {
                    Text("A+")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(disablePlus ? Color.gray.opacity(0.4) : Color(hex: "cbd5e1"))
                        .frame(width: 42, height: 32)
                }
                .buttonStyle(.macRect())
                .disabled(disablePlus)
            }
            .background(Color.white.opacity(0.05))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.1), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
    }

    private var lineHeightRow: some View {
        settingRow {
            Text("Giãn dòng")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(hex: "cbd5e1"))

            Spacer(minLength: 10)

            segmentedButtons(
                options: ReaderAppearance.lineHeightOptions,
                selected: desc.lineHeight,
                onSelect: { val in updateDescriptor { $0.lineHeight = val } }
            )
        }
    }

    private var fontFamilyRow: some View {
        settingRow {
            Text("Phông chữ")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(hex: "cbd5e1"))

            Spacer(minLength: 10)

            Menu {
                ForEach(ReaderFontCategory.allCases, id: \.rawValue) { category in
                    let fonts = ReaderAppearance.fonts.filter { $0.category == category }
                    if !fonts.isEmpty {
                        Section(header: Text(category.groupLabel)) {
                            ForEach(fonts) { font in
                                Button {
                                    onSelectFont(font.id)
                                } label: {
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
                HStack(spacing: 8) {
                    Text(currentFont.label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(hex: "f1f5f9"))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color(hex: "94a3b8"))
                }
                .padding(.horizontal, 11)
                .frame(width: 196, height: 32)
                .background(Color.white.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.11), lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .macHoverHighlight(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 196)
        }
    }

    private var pageMarginRow: some View {
        settingRow {
            Text("Lề trang")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(hex: "cbd5e1"))

            Spacer(minLength: 10)

            segmentedButtons(
                options: ReaderAppearance.pageMarginOptions,
                selected: desc.pageMargin,
                onSelect: { val in updateDescriptor { $0.pageMargin = val } }
            )
        }
    }

    private var inkColorRow: some View {
        let hintText = ReaderAppearance.inks.first(where: { $0.id == desc.inkColor })?.label
            ?? (desc.inkColor == "auto" ? "Tự động" : desc.inkColor.uppercased())

        return stackedSettingRow(label: "Màu chữ", hint: hintText) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ReaderAppearance.inks) { ink in
                        let isSelected = desc.inkColor == ink.id
                        Button {
                            updateDescriptor { $0.inkColor = ink.id }
                        } label: {
                            ZStack {
                                if ink.id == "auto" {
                                    Circle()
                                        .fill(LinearGradient(colors: [Color(hex: "1e293b"), Color(hex: "475569")], startPoint: .topLeading, endPoint: .bottomTrailing))
                                        .frame(width: 26, height: 26)
                                    Text("Auto")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(.white)
                                } else {
                                    Circle()
                                        .fill(Color(hex: String(ink.color.dropFirst())))
                                        .frame(width: 26, height: 26)
                                }
                            }
                            .overlay(
                                Circle()
                                    .stroke(isSelected ? Color(hex: "38bdf8") : Color.white.opacity(0.28), lineWidth: isSelected ? 2.2 : 1.2)
                                    .frame(width: 26, height: 26)
                            )
                            .frame(width: 30, height: 30)
                        }
                        .buttonStyle(.macCircle())
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
                    .frame(width: 28, height: 28)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var paperColorRow: some View {
        stackedSettingRow(label: "Màu giấy", hint: currentTheme.label) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ReaderAppearance.themes) { t in
                        let isSelected = desc.themeId == t.id
                        Button {
                            updateDescriptor {
                                $0.themeId = t.id
                                $0.customPaperColor = ""
                            }
                        } label: {
                            ZStack {
                                if t.id == "default" {
                                    Circle()
                                        .fill(LinearGradient(colors: [Color(hex: "1e293b"), Color(hex: "475569")], startPoint: .topLeading, endPoint: .bottomTrailing))
                                        .frame(width: 26, height: 26)
                                    Text("Gốc")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(.white)
                                } else {
                                    Circle()
                                        .fill(Color(hex: String(t.paper.dropFirst())))
                                        .frame(width: 26, height: 26)
                                }
                            }
                            .overlay(
                                Circle()
                                    .stroke(isSelected ? Color(hex: "38bdf8") : Color.white.opacity(0.28), lineWidth: isSelected ? 2.2 : 1.2)
                                    .frame(width: 26, height: 26)
                            )
                            .frame(width: 30, height: 30)
                        }
                        .buttonStyle(.macCircle())
                    }

                    ColorPicker(
                        "",
                        selection: Binding(
                            get: {
                                let hex = (desc.themeId == "custom" && ReaderAppearance.isValidHexColor(desc.customPaperColor))
                                    ? desc.customPaperColor
                                    : (currentTheme.paper.isEmpty ? "#fdf8ee" : currentTheme.paper)
                                return Color(hex: String(hex.dropFirst()))
                            },
                            set: { newColor in
                                let hex = hexString(from: newColor)
                                updateDescriptor {
                                    $0.themeId = "custom"
                                    $0.customPaperColor = hex
                                }
                            }
                        ),
                        supportsOpacity: false
                    )
                    .labelsHidden()
                    .frame(width: 28, height: 28)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var textureRow: some View {
        settingRow {
            Text("Chất liệu giấy")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(hex: "cbd5e1"))

            Spacer(minLength: 10)

            Menu {
                ForEach(ReaderAppearance.textures) { tex in
                    Button {
                        updateDescriptor { $0.textureId = tex.id }
                    } label: {
                        HStack {
                            Text("\(tex.label) — \(tex.sublabel)")
                            if tex.id == desc.textureId {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Text(currentTexture.label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(hex: "f1f5f9"))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color(hex: "94a3b8"))
                }
                .padding(.horizontal, 11)
                .frame(width: 196, height: 32)
                .background(Color.white.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.11), lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .macHoverHighlight(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 196)
        }
    }

    // MARK: - Footer

    private var footerView: some View {
        let saveTextColor: Color = isAlreadySavedAsBookDefault ? Color.white.opacity(0.55) : .white
        let saveBgOpacity: Double = isAlreadySavedAsBookDefault ? 0.45 : 1.0

        return HStack(spacing: 10) {
            Button(action: onResetToBookDefault) {
                Text("Về mặc định")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isAtBookDefault ? Color.gray.opacity(0.45) : Color(hex: "cbd5e1"))
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .background(Color.white.opacity(0.05))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.12), lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
            }
            .disabled(isAtBookDefault)
            .buttonStyle(.macInteractive(cornerRadius: 7))

            Button(action: onSaveAsBookDefault) {
                Text(saveDefaultButtonTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(saveTextColor)
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    .background(
                        LinearGradient(colors: [Color(hex: "0284c7"), Color(hex: "2563eb")], startPoint: .topLeading, endPoint: .bottomTrailing)
                            .opacity(saveBgOpacity)
                    )
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color(hex: "38bdf8").opacity(0.4), lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
            }
            .disabled(isSavingDefault || isAlreadySavedAsBookDefault)
            .buttonStyle(.macInteractive(cornerRadius: 7))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color.black.opacity(0.25))
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
        }
    }

    // MARK: - Layout Builders

    @ViewBuilder
    private func settingRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            content()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
        }
    }

    @ViewBuilder
    private func stackedSettingRow<Content: View>(label: String, hint: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(hex: "cbd5e1"))
                Spacer()
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(hex: "94a3b8"))
            }
            content()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
        }
    }

    @ViewBuilder
    private func segmentedButtons(options: [(id: String, label: String)], selected: String, onSelect: @escaping (String) -> Void) -> some View {
        HStack(spacing: 3) {
            ForEach(options, id: \.id) { opt in
                let isSelected = opt.id == selected
                Button {
                    onSelect(opt.id)
                } label: {
                    Text(opt.label)
                        .font(.system(size: 11, weight: isSelected ? .bold : .medium))
                        .foregroundStyle(isSelected ? Color(hex: "7dd3fc") : Color(hex: "cbd5e1"))
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(isSelected ? Color(hex: "38bdf8").opacity(0.18) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.macInteractive(cornerRadius: 5))
            }
        }
        .padding(3)
        .background(Color.white.opacity(0.05))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.1), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}
