import Foundation
import SwiftUI

enum ReaderFontCategory: String, CaseIterable {
    case `default` = "default"
    case serif = "serif"
    case sans = "sans"
    case handwriting = "handwriting"
    case mono = "mono"

    var groupLabel: String {
        switch self {
        case .default: return "Mặc định"
        case .serif: return "Serif (Có chân)"
        case .sans: return "Sans-serif (Không chân)"
        case .handwriting: return "Handwriting (Viết tay)"
        case .mono: return "Monospace (Kỹ thuật)"
        }
    }
}

struct ReaderFontOption: Identifiable, Equatable {
    let id: String
    let label: String
    let sublabel: String
    let category: ReaderFontCategory
    let family: String
    let googleFontUrl: String?
}

struct ReaderThemeOption: Identifiable, Equatable {
    let id: String
    let label: String
    let sublabel: String
    let paper: String
    let canvas: String
    let ink: String
    let mutedInk: String
    let ruleColor: String
    let codeBg: String
    let isDark: Bool
}

struct ReaderInkOption: Identifiable, Equatable {
    let id: String
    let label: String
    let color: String
}

struct ReaderTextureOption: Identifiable, Equatable {
    let id: String
    let label: String
    let sublabel: String
}

struct ReaderThemeDescriptor: Equatable {
    var themeId: String = "default"
    var fontScale: Int = 100
    var lineHeight: String = "default"
    var pageMargin: String = "default"
    var inkColor: String = "auto"
    var textureId: String = "default"
}

struct ReaderA4Status: Equatable {
    var appliedFontScale: Int = 100
    var clampedByA4: Bool = false
    var atMaxA4Scale: Bool = false
}

enum ReaderAppearance {
    static let fonts: [ReaderFontOption] = [
        ReaderFontOption(
            id: "default",
            label: "Mặc định sách",
            sublabel: "Theo thiết kế gốc",
            category: .default,
            family: "",
            googleFontUrl: nil
        ),
        // Serif
        ReaderFontOption(
            id: "literata",
            label: "Literata",
            sublabel: "Serif chuyên đọc sách",
            category: .serif,
            family: "'Literata', Georgia, 'Times New Roman', serif",
            googleFontUrl: "https://fonts.googleapis.com/css2?family=Literata:ital,opsz,wght@0,7..72,400..700;1,7..72,400..700&display=swap"
        ),
        ReaderFontOption(
            id: "merriweather",
            label: "Merriweather",
            sublabel: "Cổ điển, đậm nét",
            category: .serif,
            family: "'Merriweather', Georgia, serif",
            googleFontUrl: "https://fonts.googleapis.com/css2?family=Merriweather:ital,wght@0,400;0,700;1,400;1,700&display=swap"
        ),
        ReaderFontOption(
            id: "lora",
            label: "Lora",
            sublabel: "Văn học, thanh lịch",
            category: .serif,
            family: "'Lora', Georgia, serif",
            googleFontUrl: "https://fonts.googleapis.com/css2?family=Lora:ital,wght@0,400..700;1,400..700&display=swap"
        ),
        ReaderFontOption(
            id: "crimson-pro",
            label: "Crimson Pro",
            sublabel: "Sách in học thuật",
            category: .serif,
            family: "'Crimson Pro', Georgia, serif",
            googleFontUrl: "https://fonts.googleapis.com/css2?family=Crimson+Pro:ital,wght@0,400..700;1,400..700&display=swap"
        ),
        ReaderFontOption(
            id: "noto-serif",
            label: "Noto Serif",
            sublabel: "Chuẩn dấu tiếng Việt",
            category: .serif,
            family: "'Noto Serif', Georgia, serif",
            googleFontUrl: "https://fonts.googleapis.com/css2?family=Noto+Serif:ital,wght@0,400..700;1,400..700&display=swap"
        ),
        ReaderFontOption(
            id: "charter",
            label: "Charter / Georgia",
            sublabel: "Sách in truyền thống",
            category: .serif,
            family: "Charter, 'Bitstream Charter', 'Sitka Text', Georgia, serif",
            googleFontUrl: nil
        ),
        // Sans
        ReaderFontOption(
            id: "inter",
            label: "Inter",
            sublabel: "Hiện đại, sắc nét",
            category: .sans,
            family: "'Inter', -apple-system, BlinkMacSystemFont, sans-serif",
            googleFontUrl: "https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap"
        ),
        ReaderFontOption(
            id: "plus-jakarta",
            label: "Plus Jakarta Sans",
            sublabel: "Mềm mại, dễ đọc",
            category: .sans,
            family: "'Plus Jakarta Sans', -apple-system, BlinkMacSystemFont, sans-serif",
            googleFontUrl: "https://fonts.googleapis.com/css2?family=Plus+Jakarta+Sans:ital,wght@0,400..700;1,400..700&display=swap"
        ),
        ReaderFontOption(
            id: "be-vietnam-pro",
            label: "Be Vietnam Pro",
            sublabel: "Tối ưu tiếng Việt",
            category: .sans,
            family: "'Be Vietnam Pro', -apple-system, BlinkMacSystemFont, sans-serif",
            googleFontUrl: "https://fonts.googleapis.com/css2?family=Be+Vietnam+Pro:ital,wght@0,400;0,500;0,600;0,700;1,400&display=swap"
        ),
        ReaderFontOption(
            id: "system-sans",
            label: "System Sans",
            sublabel: "SF Pro hệ thống",
            category: .sans,
            family: "-apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif",
            googleFontUrl: nil
        ),
        // Handwriting
        ReaderFontOption(
            id: "playpen-sans",
            label: "Playpen Sans",
            sublabel: "Viết tay tự nhiên, dễ đọc",
            category: .handwriting,
            family: "'Playpen Sans', cursive, sans-serif",
            googleFontUrl: "https://fonts.googleapis.com/css2?family=Playpen+Sans:wght@400;500;600;700&display=swap"
        ),
        ReaderFontOption(
            id: "patrick-hand",
            label: "Patrick Hand",
            sublabel: "Chữ viết tay sổ ghi chép",
            category: .handwriting,
            family: "'Patrick Hand', cursive, sans-serif",
            googleFontUrl: "https://fonts.googleapis.com/css2?family=Patrick+Hand&display=swap"
        ),
        ReaderFontOption(
            id: "caveat",
            label: "Caveat",
            sublabel: "Bút mực phóng khoáng",
            category: .handwriting,
            family: "'Caveat', cursive, sans-serif",
            googleFontUrl: "https://fonts.googleapis.com/css2?family=Caveat:wght@400..700&display=swap"
        ),
        ReaderFontOption(
            id: "mali",
            label: "Mali",
            sublabel: "Viết tay tròn trịa, ấm áp",
            category: .handwriting,
            family: "'Mali', cursive, sans-serif",
            googleFontUrl: "https://fonts.googleapis.com/css2?family=Mali:ital,wght@0,400;0,500;0,600;0,700;1,400&display=swap"
        ),
        ReaderFontOption(
            id: "itim",
            label: "Itim",
            sublabel: "Bút bi học trò",
            category: .handwriting,
            family: "'Itim', cursive, sans-serif",
            googleFontUrl: "https://fonts.googleapis.com/css2?family=Itim&display=swap"
        ),
        ReaderFontOption(
            id: "dancing-script",
            label: "Dancing Script",
            sublabel: "Thư pháp mềm mại",
            category: .handwriting,
            family: "'Dancing Script', cursive, serif",
            googleFontUrl: "https://fonts.googleapis.com/css2?family=Dancing+Script:wght@500;600;700&display=swap"
        ),
        // Monospace
        ReaderFontOption(
            id: "jetbrains-mono",
            label: "JetBrains Mono",
            sublabel: "Monospace kỹ thuật",
            category: .mono,
            family: "'JetBrains Mono', 'SF Mono', Menlo, monospace",
            googleFontUrl: "https://fonts.googleapis.com/css2?family=JetBrains+Mono:ital,wght@0,400;0,600;1,400&display=swap"
        ),
    ]

    static let themes: [ReaderThemeOption] = [
        ReaderThemeOption(
            id: "default",
            label: "Mặc định",
            sublabel: "Màu gốc",
            paper: "",
            canvas: "",
            ink: "",
            mutedInk: "",
            ruleColor: "",
            codeBg: "",
            isDark: false
        ),
        ReaderThemeOption(
            id: "paper-white",
            label: "Trắng sáng",
            sublabel: "Giấy trắng tinh",
            paper: "#ffffff",
            canvas: "#f1f5f9",
            ink: "#111827",
            mutedInk: "#4b5563",
            ruleColor: "#d1d5db",
            codeBg: "#f3f4f6",
            isDark: false
        ),
        ReaderThemeOption(
            id: "warm-cream",
            label: "Kem ấm",
            sublabel: "Giấy kem dịu mắt",
            paper: "#fdf8ee",
            canvas: "#efe6d5",
            ink: "#231f20",
            mutedInk: "#5c5346",
            ruleColor: "#dccmb2".replacingOccurrences(of: "m", with: "f"),
            codeBg: "#f5ebd6",
            isDark: false
        ),
        ReaderThemeOption(
            id: "sepia",
            label: "Sepia cổ điển",
            sublabel: "Vàng nâu sách cổ",
            paper: "#f4ecd8",
            canvas: "#e4d8bc",
            ink: "#3c2f23",
            mutedInk: "#6b5744",
            ruleColor: "#d3c29f",
            codeBg: "#eadec3",
            isDark: false
        ),
        ReaderThemeOption(
            id: "vintage-kraft",
            label: "Giấy Kraft",
            sublabel: "Giấy tái chế trầm",
            paper: "#e6d7be",
            canvas: "#d4c3a6",
            ink: "#2c2218",
            mutedInk: "#5c4938",
            ruleColor: "#c4b090",
            codeBg: "#dccaa9",
            isDark: false
        ),
        ReaderThemeOption(
            id: "rose-blush",
            label: "Hồng phấn",
            sublabel: "Giấy hồng dịu",
            paper: "#fdf2f4",
            canvas: "#f3e1e5",
            ink: "#2d1e24",
            mutedInk: "#684f58",
            ruleColor: "#e5cad1",
            codeBg: "#f7e6ea",
            isDark: false
        ),
        ReaderThemeOption(
            id: "sage-green",
            label: "Xanh dịu mắt",
            sublabel: "Chống mỏi mắt",
            paper: "#eaf3ec",
            canvas: "#d8e6db",
            ink: "#1c2d24",
            mutedInk: "#486353",
            ruleColor: "#bfd6c5",
            codeBg: "#dfece2",
            isDark: false
        ),
        ReaderThemeOption(
            id: "nordic-mist",
            label: "Xanh sương",
            sublabel: "Mát dịu ban ngày",
            paper: "#eef3f8",
            canvas: "#dde6f0",
            ink: "#1a2533",
            mutedInk: "#4c5d73",
            ruleColor: "#c5d3e3",
            codeBg: "#e3ebf3",
            isDark: false
        ),
        ReaderThemeOption(
            id: "slate-dark",
            label: "Tối dịu",
            sublabel: "Đọc buổi tối",
            paper: "#1e2430",
            canvas: "#141821",
            ink: "#e2e8f0",
            mutedInk: "#94a3b8",
            ruleColor: "#334155",
            codeBg: "#151a24",
            isDark: true
        ),
        ReaderThemeOption(
            id: "oled-night",
            label: "Đen đêm",
            sublabel: "Tương phản dịu",
            paper: "#121316",
            canvas: "#090a0c",
            ink: "#d4d4d8",
            mutedInk: "#8e8e96",
            ruleColor: "#27272a",
            codeBg: "#1a1c20",
            isDark: true
        ),
    ]

    static let inks: [ReaderInkOption] = [
        ReaderInkOption(id: "auto", label: "Tự động", color: ""),
        ReaderInkOption(id: "#111827", label: "Đen mực", color: "#111827"),
        ReaderInkOption(id: "#374151", label: "Xám than", color: "#374151"),
        ReaderInkOption(id: "#3c2f23", label: "Nâu Espresso", color: "#3c2f23"),
        ReaderInkOption(id: "#1e3a5f", label: "Xanh bút máy", color: "#1e3a5f"),
        ReaderInkOption(id: "#1c3b2b", label: "Xanh rừng", color: "#1c3b2b"),
        ReaderInkOption(id: "#4c1d3d", label: "Đỏ rượu vang", color: "#4c1d3d"),
        ReaderInkOption(id: "#e2e8f0", label: "Trắng bạc", color: "#e2e8f0"),
    ]

    static let textures: [ReaderTextureOption] = [
        ReaderTextureOption(id: "default", label: "Mặc định (Trơn)", sublabel: "Không hiệu ứng vân giấy"),
        ReaderTextureOption(id: "paper-grain", label: "Vân giấy mịn", sublabel: "Hạt giấy tự nhiên"),
        ReaderTextureOption(id: "vintage", label: "Giấy cổ điển", sublabel: "Viền bóng ấm hoài cổ"),
        ReaderTextureOption(id: "linen", label: "Vải lanh (Linen)", sublabel: "Sợi dệt ngang dọc"),
        ReaderTextureOption(id: "parchment", label: "Giấy da (Parchment)", sublabel: "Loang màu cổ xưa"),
        ReaderTextureOption(id: "dot-grid", label: "Chấm bi (Dot Grid)", sublabel: "Sổ tay chấm bi"),
        ReaderTextureOption(id: "ruled", label: "Kẻ ngang (Ruled)", sublabel: "Dòng kẻ sổ ghi chép"),
    ]

    static let lineHeightOptions: [(id: String, label: String)] = [
        ("default", "Gốc"),
        ("1.35", "Chặt"),
        ("1.5", "Vừa"),
        ("1.65", "Thoáng"),
        ("1.8", "Rộng"),
    ]

    static let pageMarginOptions: [(id: String, label: String)] = [
        ("default", "Gốc"),
        ("compact", "Hẹp"),
        ("normal", "Vừa"),
        ("wide", "Rộng"),
    ]

    static func getFont(_ fontId: String?) -> ReaderFontOption {
        let trimmed = (fontId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return fonts.first(where: { $0.id == trimmed }) ?? fonts[0]
    }

    static func isValidHexColor(_ str: String) -> Bool {
        let pattern = "^#[0-9a-fA-F]{6}$"
        return str.range(of: pattern, options: .regularExpression) != nil
    }

    static func isHexColorDark(_ hex: String) -> Bool {
        guard isValidHexColor(hex) else { return false }
        let start = hex.index(hex.startIndex, offsetBy: 1)
        guard let rgb = Int(hex[start...], radix: 16) else { return false }
        let r = Double((rgb >> 16) & 0xff)
        let g = Double((rgb >> 8) & 0xff)
        let b = Double(rgb & 0xff)
        let luminance = (0.299 * r + 0.587 * g + 0.114 * b) / 255.0
        return luminance < 0.45
    }

    static func buildCustomThemeFromHex(_ hex: String) -> ReaderThemeOption {
        let normalized = hex.lowercased()
        let dark = isHexColorDark(normalized)
        return ReaderThemeOption(
            id: normalized,
            label: "Tùy chỉnh (\(normalized.uppercased()))",
            sublabel: "Màu giấy tự chọn",
            paper: normalized,
            canvas: normalized,
            ink: dark ? "#e2e8f0" : "#1f2937",
            mutedInk: dark ? "#94a3b8" : "#4b5563",
            ruleColor: dark ? "rgba(255,255,255,0.16)" : "rgba(0,0,0,0.15)",
            codeBg: dark ? "rgba(0,0,0,0.28)" : "rgba(0,0,0,0.05)",
            isDark: dark
        )
    }

    static func parseThemeDescriptor(_ raw: String?) -> ReaderThemeDescriptor {
        var result = ReaderThemeDescriptor()
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "default" else { return result }

        let parts = trimmed.split(separator: "|").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { return result }

        let first = parts[0]
        var startIdx = 0
        if !first.contains(":") {
            if themes.contains(where: { $0.id == first }) || isValidHexColor(first) {
                result.themeId = isValidHexColor(first) ? first.lowercased() : first
            }
            startIdx = 1
        }

        for i in startIdx..<parts.count {
            let token = parts[i]
            guard let colonIdx = token.firstIndex(of: ":") else { continue }
            let key = String(token[..<colonIdx])
            let val = String(token[token.index(after: colonIdx)...])
            switch key {
            case "scale":
                if let n = Int(val) {
                    result.fontScale = max(80, min(140, n))
                }
            case "lh":
                if ["default", "1.35", "1.5", "1.65", "1.8"].contains(val) {
                    result.lineHeight = val
                }
            case "margin":
                if ["default", "compact", "normal", "wide"].contains(val) {
                    result.pageMargin = val
                }
            case "ink":
                if val == "auto" || isValidHexColor(val) {
                    result.inkColor = val.lowercased()
                }
            case "tex":
                if textures.contains(where: { $0.id == val }) {
                    result.textureId = val
                }
            default:
                break
            }
        }
        return result
    }

    static func serializeThemeDescriptor(_ desc: ReaderThemeDescriptor) -> String {
        let base = desc.themeId.isEmpty ? "default" : desc.themeId
        var tokens: [String] = [base]
        if desc.fontScale != 100 {
            tokens.append("scale:\(max(80, min(140, desc.fontScale)))")
        }
        if !desc.lineHeight.isEmpty && desc.lineHeight != "default" {
            tokens.append("lh:\(desc.lineHeight)")
        }
        if !desc.pageMargin.isEmpty && desc.pageMargin != "default" {
            tokens.append("margin:\(desc.pageMargin)")
        }
        if !desc.inkColor.isEmpty && desc.inkColor != "auto" {
            tokens.append("ink:\(desc.inkColor.lowercased())")
        }
        if !desc.textureId.isEmpty && desc.textureId != "default" {
            tokens.append("tex:\(desc.textureId)")
        }
        if tokens.count == 1 && tokens[0] == "default" {
            return "default"
        }
        return tokens.joined(separator: "|")
    }

    static func getTheme(_ themeIdOrDescriptor: String?) -> ReaderThemeOption {
        let desc = parseThemeDescriptor(themeIdOrDescriptor)
        if let found = themes.first(where: { $0.id == desc.themeId }) {
            return found
        }
        if isValidHexColor(desc.themeId) {
            return buildCustomThemeFromHex(desc.themeId)
        }
        return themes[0]
    }

    // MARK: - Per-Book Local Storage

    private static func storageKey(for slug: String) -> String {
        "bilingual.bookAppearance.\(slug)"
    }

    static func loadLocalOverride(slug: String) -> (readerFont: String, readerTheme: String) {
        guard let dict = UserDefaults.standard.dictionary(forKey: storageKey(for: slug)) else {
            return ("", "")
        }
        let f = (dict["readerFont"] as? String) ?? ""
        let t = (dict["readerTheme"] as? String) ?? ""
        return (f, t)
    }

    static func saveLocalOverride(slug: String, readerFont: String, readerTheme: String) {
        UserDefaults.standard.set([
            "readerFont": readerFont,
            "readerTheme": readerTheme,
        ], forKey: storageKey(for: slug))
    }

    static func resolveEffectiveAppearance(
        book: Book,
        localOverride: (readerFont: String, readerTheme: String)
    ) -> (
        effectiveFontId: String,
        effectiveThemeId: String,
        bookDefaultFontId: String,
        bookDefaultThemeId: String,
        hasUserOverride: Bool
    ) {
        let bookDefaultFont = getFont(book.defaultFont).id
        let bookDefaultTheme = serializeThemeDescriptor(parseThemeDescriptor(book.defaultTheme))
        let userFont = !localOverride.readerFont.isEmpty ? localOverride.readerFont : (book.readerFont ?? "")
        let userTheme = !localOverride.readerTheme.isEmpty ? localOverride.readerTheme : (book.readerTheme ?? "")

        let effectiveFontId = !userFont.isEmpty ? getFont(userFont).id : bookDefaultFont
        let effectiveThemeId = !userTheme.isEmpty
            ? serializeThemeDescriptor(parseThemeDescriptor(userTheme))
            : bookDefaultTheme

        let hasUserOverride = (!userFont.isEmpty && effectiveFontId != bookDefaultFont)
            || (!userTheme.isEmpty && effectiveThemeId != bookDefaultTheme)

        return (effectiveFontId, effectiveThemeId, bookDefaultFont, bookDefaultTheme, hasUserOverride)
    }

    // MARK: - JavaScript Injection for WKWebView

    static func buildApplyAppearanceJS(
        fontId: String,
        themeId: String,
        isPhone: Bool,
        viewMode: String
    ) -> String {
        let font = getFont(fontId)
        let desc = parseThemeDescriptor(themeId)
        let theme = getTheme(themeId)
        let hasCustomPaper = desc.themeId != "default"
        let hasCustomInk = !desc.inkColor.isEmpty && desc.inkColor != "auto"
        let effectiveInk = hasCustomInk ? desc.inkColor : theme.ink
        let isDarkSurface = hasCustomPaper
            ? theme.isDark
            : (hasCustomInk ? !isHexColorDark(desc.inkColor) : false)

        let fontFamilyEscaped = font.family
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let googleUrlEscaped = (font.googleFontUrl ?? "")
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        return """
        (function() {
            const FONT_LINK_ID = 'bilingual-reader-appearance-font';
            const STYLE_ID = 'bilingual-reader-appearance-style';
            const head = document.head || document.documentElement;
            if (!head) return null;

            const fontId = "\(font.id)";
            const fontFamily = "\(fontFamilyEscaped)";
            const googleFontUrl = "\(googleUrlEscaped)";
            const requestedScale = \(desc.fontScale);
            const requestedLh = "\(desc.lineHeight)";
            const requestedMargin = "\(desc.pageMargin)";
            const hasCustomPaper = \(hasCustomPaper ? "true" : "false");
            const hasCustomInk = \(hasCustomInk ? "true" : "false");
            const paperColor = "\(theme.paper)";
            const effectiveInk = "\(effectiveInk)";
            const mutedInk = "\(theme.mutedInk)";
            const ruleColor = "\(theme.ruleColor)";
            const codeBg = "\(theme.codeBg)";
            const isDarkSurface = \(isDarkSurface ? "true" : "false");
            const textureId = "\(desc.textureId)";
            const isPhone = \(isPhone ? "true" : "false");
            const viewMode = "\(viewMode)";

            // 1. Google Font link
            let fontLink = document.getElementById(FONT_LINK_ID);
            if (fontId !== 'default' && googleFontUrl) {
                if (!fontLink) {
                    fontLink = document.createElement('link');
                    fontLink.id = FONT_LINK_ID;
                    fontLink.rel = 'stylesheet';
                    head.appendChild(fontLink);
                }
                if (fontLink.href !== googleFontUrl) {
                    fontLink.href = googleFontUrl;
                }
            } else if (fontLink) {
                fontLink.remove();
            }

            function buildTextureCss(tex, isDark) {
                const lineAlpha = isDark ? 'rgba(255,255,255,0.06)' : 'rgba(0,0,0,0.06)';
                const dotAlpha = isDark ? 'rgba(255,255,255,0.11)' : 'rgba(0,0,0,0.11)';
                switch (tex) {
                    case 'paper-grain':
                        return `background-image: radial-gradient(${isDark ? 'rgba(255,255,255,0.035)' : 'rgba(0,0,0,0.035)'} 1px, transparent 0), radial-gradient(${isDark ? 'rgba(255,255,255,0.025)' : 'rgba(0,0,0,0.025)'} 1px, transparent 0) !important; background-size: 16px 16px, 23px 23px !important; background-position: 0 0, 7px 11px !important;`;
                    case 'vintage':
                        return `box-shadow: inset 0 0 54px ${isDark ? 'rgba(0,0,0,0.55)' : 'rgba(120,82,40,0.18)'}, inset 0 0 14px ${isDark ? 'rgba(0,0,0,0.35)' : 'rgba(120,82,40,0.1)'} !important;`;
                    case 'linen':
                        return `background-image: repeating-linear-gradient(0deg, ${lineAlpha} 0px, ${lineAlpha} 1px, transparent 1px, transparent 6px), repeating-linear-gradient(90deg, ${lineAlpha} 0px, ${lineAlpha} 1px, transparent 1px, transparent 6px) !important;`;
                    case 'parchment':
                        return `background-image: radial-gradient(ellipse at 20% 15%, ${isDark ? 'rgba(255,255,255,0.03)' : 'rgba(160,115,60,0.1)'} 0%, transparent 55%), radial-gradient(ellipse at 80% 85%, ${isDark ? 'rgba(0,0,0,0.25)' : 'rgba(135,95,45,0.12)'} 0%, transparent 60%) !important; box-shadow: inset 0 0 42px ${isDark ? 'rgba(0,0,0,0.45)' : 'rgba(125,85,35,0.14)'} !important;`;
                    case 'dot-grid':
                        return `background-image: radial-gradient(${dotAlpha} 1px, transparent 1px) !important; background-size: 18px 18px !important;`;
                    case 'ruled':
                        return `background-image: repeating-linear-gradient(to bottom, transparent 0px, transparent 25px, ${lineAlpha} 25px, ${lineAlpha} 26px) !important;`;
                    default:
                        return '';
                }
            }

            function buildCss(scalePct, lhVal, marginVal) {
                const blocks = [];
                if (fontId !== 'default' && fontFamily) {
                    blocks.push(`
                        :root {
                            --font-display: ${fontFamily} !important;
                            --font-ui: ${fontFamily} !important;
                        }
                        body, .book-page, .prose-page, .toc-page,
                        .prose-page p, .prose-page li, .prose-page blockquote,
                        .prose-page td, .prose-page th, .prose-page figcaption,
                        .prose-page h1, .prose-page h2, .prose-page h3, .prose-page h4, .prose-page h5, .prose-page h6,
                        .prose-page .running-head, .prose-page .section-title, .prose-page .section-number,
                        .prose-page .chapter-opener, .prose-page .chapter-title, .prose-page .preface-title,
                        .prose-page .exercise-instruction, .prose-page .exercises-title,
                        .title-book, .subtitle-book, .author-book, .toc-title, .toc-row {
                            font-family: ${fontFamily} !important;
                        }
                        .prose-page pre, .prose-page code, .prose-page pre *, .prose-page code *,
                        .prose-page .code-block, .prose-page .ascii-figure {
                            font-family: var(--font-mono, "Courier New", Courier, monospace) !important;
                        }
                    `);
                }

                if (isPhone) {
                    const fScale = scalePct / 100.0;
                    const hpad = viewMode === 'split' ? 28 : 32;
                    const minPt = (13.0 * fScale).toFixed(1);
                    const maxPt = (18.5 * fScale).toFixed(1);
                    const divisor = (18.5 / fScale).toFixed(2);
                    const lhRule = (lhVal && lhVal !== 'default') ? lhVal : '1.7';
                    blocks.push(`
                        body, p, li, blockquote, .prose-page, .sheet-flow {
                            font-size: clamp(${minPt}pt, calc((100vw - ${hpad}px) / ${divisor}), ${maxPt}pt) !important;
                            line-height: ${lhRule} !important;
                        }
                    `);
                } else {
                    if (scalePct !== 100) {
                        const ratio = (scalePct / 100.0).toFixed(3);
                        blocks.push(`
                            .prose-page,
                            .prose-page p,
                            .prose-page li,
                            .prose-page blockquote,
                            .prose-page .exercise-instruction,
                            .toc-page .toc-row {
                                font-size: calc(11pt * ${ratio}) !important;
                            }
                        `);
                    }
                    if (lhVal && lhVal !== 'default') {
                        blocks.push(`
                            .prose-page,
                            .prose-page p,
                            .prose-page li,
                            .prose-page blockquote {
                                line-height: ${lhVal} !important;
                            }
                        `);
                    }
                }

                if (marginVal && marginVal !== 'default') {
                    if (isPhone) {
                        const padMap = {
                            compact: '10px 8px 28px',
                            normal: '16px 16px 32px',
                            wide: '20px 26px 36px'
                        };
                        const pad = padMap[marginVal];
                        if (pad) {
                            blocks.push(`
                                body, body.book-standalone {
                                    padding: ${pad} !important;
                                }
                            `);
                        }
                    } else {
                        const padMap = {
                            compact: '14px 16px',
                            normal: '24px 32px',
                            wide: '28px 48px'
                        };
                        const pad = padMap[marginVal];
                        if (pad) {
                            blocks.push(`
                                body, body.book-standalone {
                                    padding: ${pad} !important;
                                }
                            `);
                        }
                    }
                }

                if (hasCustomPaper || hasCustomInk) {
                    blocks.push(`
                        :root {
                            ${hasCustomPaper ? `--paper: ${paperColor} !important; --canvas: ${paperColor} !important; --rule: ${ruleColor} !important; --rule-soft: ${ruleColor} !important; --code-bg: ${codeBg} !important;` : ''}
                            ${effectiveInk ? `--ink: ${effectiveInk} !important;` : ''}
                            ${mutedInk ? `--muted-ink: ${mutedInk} !important;` : ''}
                        }
                        ${hasCustomPaper ? `
                        html, body, body.book-standalone, .book-page, .book-page--sheet, .sheet-flow, .prose-page, .toc-page, .title-page {
                            background-color: ${paperColor} !important;
                        }
                        ` : ''}
                        ${effectiveInk ? `
                        body, .book-page, .prose-page, .toc-page,
                        .prose-page p, .prose-page li, .prose-page td, .prose-page th,
                        .prose-page h1, .prose-page h2, .prose-page h3, .prose-page h4, .prose-page h5, .prose-page h6,
                        .prose-page .section-title, .prose-page .section-number,
                        .prose-page .chapter-opener, .prose-page .chapter-title, .prose-page .preface-title,
                        .prose-page .exercise-instruction, .prose-page .exercises-title,
                        .title-book, .subtitle-book, .author-book, .toc-title, .toc-row {
                            color: ${effectiveInk} !important;
                        }
                        ` : ''}
                        ${isDarkSurface ? `
                        mark.reader-highlight {
                            color: #0f172a !important;
                        }
                        ` : ''}
                    `);
                }

                if (textureId && textureId !== 'default') {
                    const texCss = buildTextureCss(textureId, isDarkSurface);
                    if (texCss) {
                        blocks.push(`
                            body, body.book-standalone, .book-page, .book-page--sheet {
                                ${texCss}
                            }
                        `);
                    }
                }

                return blocks.join('\\n');
            }

            function doesOverflowA4() {
                if (isPhone) return false;
                const docEl = document.documentElement;
                const bodyEl = document.body;
                if (!docEl || !bodyEl) return false;
                const vh = window.innerHeight || docEl.clientHeight || 0;
                if (vh <= 0) return false;
                return Math.max(docEl.scrollHeight, bodyEl.scrollHeight) > vh + 6;
            }

            let styleEl = document.getElementById(STYLE_ID);
            const ensureStyle = (cssText) => {
                if (!cssText.trim()) {
                    if (styleEl) styleEl.remove();
                    styleEl = null;
                    return;
                }
                if (!styleEl) {
                    styleEl = document.createElement('style');
                    styleEl.id = STYLE_ID;
                    head.appendChild(styleEl);
                }
                styleEl.textContent = cssText;
            };

            let appliedScale = requestedScale || 100;
            let appliedLh = requestedLh;
            let appliedMargin = requestedMargin;
            let clampedByA4 = false;

            ensureStyle(buildCss(appliedScale, appliedLh, appliedMargin));

            if (!isPhone && (appliedScale > 100 || (appliedLh && appliedLh !== 'default') || appliedMargin === 'wide')) {
                while (appliedScale > 80 && doesOverflowA4()) {
                    appliedScale -= 5;
                    clampedByA4 = true;
                    ensureStyle(buildCss(appliedScale, appliedLh, appliedMargin));
                }
                if (doesOverflowA4() && appliedLh && appliedLh !== 'default') {
                    appliedLh = 'default';
                    clampedByA4 = true;
                    ensureStyle(buildCss(appliedScale, appliedLh, appliedMargin));
                }
                if (doesOverflowA4() && appliedMargin === 'wide') {
                    appliedMargin = 'default';
                    clampedByA4 = true;
                    ensureStyle(buildCss(appliedScale, appliedLh, appliedMargin));
                }
            }

            let atMaxA4Scale = appliedScale >= 140;
            if (!isPhone && !atMaxA4Scale) {
                if (clampedByA4 && appliedScale < requestedScale) {
                    atMaxA4Scale = true;
                } else {
                    const nextScale = Math.min(140, appliedScale + 5);
                    ensureStyle(buildCss(nextScale, appliedLh, appliedMargin));
                    if (doesOverflowA4()) {
                        atMaxA4Scale = true;
                    }
                    ensureStyle(buildCss(appliedScale, appliedLh, appliedMargin));
                }
            }

            // Compute effective background RGBA for WKWebView native canvas
            let rgba = null;
            const candidates = [
                document.querySelector('.book-page'),
                document.querySelector('article'),
                document.body,
                document.documentElement
            ];
            for (const element of candidates) {
                if (!element) continue;
                const value = getComputedStyle(element).backgroundColor;
                const match = value && value.match(/^rgba?\\(\\s*([\\d.]+)[, ]+\\s*([\\d.]+)[, ]+\\s*([\\d.]+)(?:\\s*[,/]\\s*([\\d.]+))?\\s*\\)$/i);
                if (!match) continue;
                const alpha = match[4] == null ? 1 : Number(match[4]);
                if (alpha <= 0) continue;
                document.documentElement.style.setProperty('background-color', value, 'important');
                if (document.body) {
                    document.body.style.setProperty('background-color', value, 'important');
                }
                rgba = [Number(match[1]), Number(match[2]), Number(match[3]), alpha];
                break;
            }

            return {
                appliedFontScale: appliedScale,
                clampedByA4: clampedByA4,
                atMaxA4Scale: atMaxA4Scale,
                rgba: rgba
            };
        })();
        """
    }
}

