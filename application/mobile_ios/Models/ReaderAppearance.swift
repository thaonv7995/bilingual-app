import Foundation
import UIKit

enum ReaderFontCategory: String, CaseIterable {
    case `default` = "default"
    case serif = "serif"
    case sans = "sans"
    case handwriting = "handwriting"
    case mono = "mono"

    var groupLabel: String {
        switch self {
        case .default: return "Mặc định"
        case .serif: return "Có chân (Serif)"
        case .sans: return "Không chân (Sans)"
        case .handwriting: return "Chữ viết tay (Handwriting)"
        case .mono: return "Đơn cách (Monospace)"
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
    let accent: String
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
    var customPaperColor: String = ""
    var fontScale: Int = 100
    var lineHeight: String = "default"
    var pageMargin: String = "default"
    var inkColor: String = "auto"
    var textureId: String = "default"
    var interlinear: Bool = false
    var interlinearOpacity: Int = 55
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
            sublabel: "Theo thiết kế gốc của sách",
            category: .default,
            family: "",
            googleFontUrl: nil
        ),
        // Serif
        ReaderFontOption(
            id: "literata",
            label: "Literata",
            sublabel: "Serif chuyên dụng đọc sách",
            category: .serif,
            family: "'Literata', Georgia, 'Times New Roman', serif",
            googleFontUrl: "https://fonts.googleapis.com/css2?family=Literata:ital,opsz,wght@0,7..72,400..700;1,7..72,400..700&display=swap"
        ),
        ReaderFontOption(
            id: "merriweather",
            label: "Merriweather",
            sublabel: "Cổ điển, đậm nét",
            category: .serif,
            family: "'Merriweather', Georgia, 'Times New Roman', serif",
            googleFontUrl: "https://fonts.googleapis.com/css2?family=Merriweather:ital,wght@0,400;0,700;1,400;1,700&display=swap"
        ),
        ReaderFontOption(
            id: "lora",
            label: "Lora",
            sublabel: "Văn học, thanh lịch",
            category: .serif,
            family: "'Lora', Georgia, 'Times New Roman', serif",
            googleFontUrl: "https://fonts.googleapis.com/css2?family=Lora:ital,wght@0,400..700;1,400..700&display=swap"
        ),
        ReaderFontOption(
            id: "noto-serif",
            label: "Noto Serif",
            sublabel: "Học thuật, dấu tiếng Việt chuẩn",
            category: .serif,
            family: "'Noto Serif', Georgia, 'Times New Roman', serif",
            googleFontUrl: "https://fonts.googleapis.com/css2?family=Noto+Serif:ital,wght@0,400..700;1,400..700&display=swap"
        ),
        ReaderFontOption(
            id: "playfair",
            label: "Playfair Display",
            sublabel: "Tiêu đề & văn chương cổ điển",
            category: .serif,
            family: "'Playfair Display', Georgia, 'Times New Roman', serif",
            googleFontUrl: "https://fonts.googleapis.com/css2?family=Playfair+Display:ital,wght@0,400..700;1,400..700&display=swap"
        ),
        ReaderFontOption(
            id: "charter",
            label: "Charter / Georgia",
            sublabel: "Sách in truyền thống",
            category: .serif,
            family: "Charter, 'Bitstream Charter', Georgia, 'Times New Roman', serif",
            googleFontUrl: nil
        ),
        // Sans
        ReaderFontOption(
            id: "inter",
            label: "Inter",
            sublabel: "Sans hiện đại, sách kỹ thuật",
            category: .sans,
            family: "'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif",
            googleFontUrl: "https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap"
        ),
        ReaderFontOption(
            id: "plus-jakarta",
            label: "Plus Jakarta Sans",
            sublabel: "Sans mềm mại, dễ đọc",
            category: .sans,
            family: "'Plus Jakarta Sans', -apple-system, BlinkMacSystemFont, sans-serif",
            googleFontUrl: "https://fonts.googleapis.com/css2?family=Plus+Jakarta+Sans:ital,wght@0,400..700;1,400..700&display=swap"
        ),
        ReaderFontOption(
            id: "be-vietnam",
            label: "Be Vietnam Pro",
            sublabel: "Sans tối ưu tiếng Việt",
            category: .sans,
            family: "'Be Vietnam Pro', -apple-system, BlinkMacSystemFont, sans-serif",
            googleFontUrl: "https://fonts.googleapis.com/css2?family=Be+Vietnam+Pro:ital,wght@0,400;0,500;0,600;0,700;1,400&display=swap"
        ),
        ReaderFontOption(
            id: "system-sans",
            label: "System Sans",
            sublabel: "SF Pro hệ thống",
            category: .sans,
            family: "-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Helvetica Neue', sans-serif",
            googleFontUrl: nil
        ),
        // Handwriting
        ReaderFontOption(
            id: "playpen-sans",
            label: "Playpen Sans",
            sublabel: "Viết tay hiện đại, rõ chữ",
            category: .handwriting,
            family: "'Playpen Sans', cursive, sans-serif",
            googleFontUrl: "https://fonts.googleapis.com/css2?family=Playpen+Sans:wght@400;500;600;700&display=swap"
        ),
        ReaderFontOption(
            id: "patrick-hand",
            label: "Patrick Hand",
            sublabel: "Chữ viết tay gọn gàng, rõ nét",
            category: .handwriting,
            family: "'Patrick Hand', 'Bradley Hand', cursive, sans-serif",
            googleFontUrl: "https://fonts.googleapis.com/css2?family=Patrick+Hand&subset=vietnamese&display=swap"
        ),
        ReaderFontOption(
            id: "caveat",
            label: "Caveat",
            sublabel: "Phóng khoáng như sổ tay",
            category: .handwriting,
            family: "'Caveat', 'Snell Roundhand', cursive",
            googleFontUrl: "https://fonts.googleapis.com/css2?family=Caveat:wght@400..700&display=swap"
        ),
        ReaderFontOption(
            id: "mali",
            label: "Mali",
            sublabel: "Nét viết tay tròn trịa, thân thiện",
            category: .handwriting,
            family: "'Mali', cursive, sans-serif",
            googleFontUrl: "https://fonts.googleapis.com/css2?family=Mali:ital,wght@0,400;0,500;0,600;1,400&display=swap"
        ),
        ReaderFontOption(
            id: "itim",
            label: "Itim",
            sublabel: "Viết tay bút bi thanh thoát",
            category: .handwriting,
            family: "'Itim', cursive, sans-serif",
            googleFontUrl: "https://fonts.googleapis.com/css2?family=Itim&display=swap"
        ),
        ReaderFontOption(
            id: "dancing-script",
            label: "Dancing Script",
            sublabel: "Chữ viết tay mềm mại, bay bổng",
            category: .handwriting,
            family: "'Dancing Script', 'Snell Roundhand', cursive",
            googleFontUrl: "https://fonts.googleapis.com/css2?family=Dancing+Script:wght@400..700&display=swap"
        ),
        ReaderFontOption(
            id: "kalam",
            label: "Kalam",
            sublabel: "Nét bút mực tự nhiên",
            category: .handwriting,
            family: "'Kalam', cursive, sans-serif",
            googleFontUrl: "https://fonts.googleapis.com/css2?family=Kalam:wght@300;400;700&display=swap"
        ),
        // Monospace
        ReaderFontOption(
            id: "jetbrains-mono",
            label: "JetBrains Mono",
            sublabel: "Monospace sắc nét, hiện đại",
            category: .mono,
            family: "'JetBrains Mono', 'SF Mono', Menlo, monospace",
            googleFontUrl: "https://fonts.googleapis.com/css2?family=JetBrains+Mono:ital,wght@0,400..700;1,400..700&display=swap"
        ),
        ReaderFontOption(
            id: "courier-prime",
            label: "Courier Prime",
            sublabel: "Phong cách máy đánh chữ cổ điển",
            category: .mono,
            family: "'Courier Prime', 'Courier New', Courier, monospace",
            googleFontUrl: "https://fonts.googleapis.com/css2?family=Courier+Prime:ital,wght@0,400;0,700;1,400;1,700&display=swap"
        ),
    ]

    /// Theme IDs match Web (`READER_THEMES` in `readerAppearance.ts`) 1:1 so settings sync seamlessly via the server.
    static let themes: [ReaderThemeOption] = [
        ReaderThemeOption(
            id: "default",
            label: "Gốc",
            sublabel: "Theo màu gốc của sách",
            paper: "#f4f1ea",
            canvas: "#f4f1ea",
            ink: "#111111",
            mutedInk: "#57534e",
            accent: "#1e4088",
            ruleColor: "#d6d3d1",
            codeBg: "#ebe6dc",
            isDark: false
        ),
        ReaderThemeOption(
            id: "paper-white",
            label: "Trắng sáng",
            sublabel: "Giấy trắng tinh khiết",
            paper: "#ffffff",
            canvas: "#f1f5f9",
            ink: "#18181b",
            mutedInk: "#52525b",
            accent: "#1d4ed8",
            ruleColor: "#e4e4e7",
            codeBg: "#f4f4f5",
            isDark: false
        ),
        ReaderThemeOption(
            id: "paper-cream",
            label: "Kem ấm",
            sublabel: "Dịu mắt khi đọc lâu",
            paper: "#fdf9f0",
            canvas: "#f3ede0",
            ink: "#26211c",
            mutedInk: "#6b5e51",
            accent: "#1e4088",
            ruleColor: "#e5dec9",
            codeBg: "#f4eee1",
            isDark: false
        ),
        ReaderThemeOption(
            id: "paper-sepia",
            label: "Sepia cổ điển",
            sublabel: "Màu giấy sách xưa",
            paper: "#f2e7cf",
            canvas: "#e6d8bc",
            ink: "#3b2e22",
            mutedInk: "#6e5a47",
            accent: "#854d0e",
            ruleColor: "#d9c8ad",
            codeBg: "#e8d9bc",
            isDark: false
        ),
        ReaderThemeOption(
            id: "paper-oat",
            label: "Giấy lụa",
            sublabel: "Nền giấy ngà tự nhiên",
            paper: "#eae4d7",
            canvas: "#ded7c8",
            ink: "#272421",
            mutedInk: "#57534e",
            accent: "#1e3a8a",
            ruleColor: "#d1c9b8",
            codeBg: "#e0d8c7",
            isDark: false
        ),
        ReaderThemeOption(
            id: "paper-rose",
            label: "Hồng phấn",
            sublabel: "Ánh hồng pastel ấm áp",
            paper: "#fbf0f2",
            canvas: "#f2dfe3",
            ink: "#2d1c22",
            mutedInk: "#6e4f58",
            accent: "#9d174d",
            ruleColor: "#e8d0d6",
            codeBg: "#f3e2e6",
            isDark: false
        ),
        ReaderThemeOption(
            id: "paper-sage",
            label: "Xanh dịu mắt",
            sublabel: "Chống mỏi mắt",
            paper: "#e6efe7",
            canvas: "#d8e6db",
            ink: "#1b2b21",
            mutedInk: "#4a6352",
            accent: "#166534",
            ruleColor: "#c5d9c8",
            codeBg: "#dae6dc",
            isDark: false
        ),
        ReaderThemeOption(
            id: "paper-mist",
            label: "Xanh sương",
            sublabel: "Mát dịu ban ngày",
            paper: "#edf2f7",
            canvas: "#dde6f0",
            ink: "#1e293b",
            mutedInk: "#475569",
            accent: "#0369a1",
            ruleColor: "#cbd5e1",
            codeBg: "#e2e8f0",
            isDark: false
        ),
        ReaderThemeOption(
            id: "paper-dark",
            label: "Tối dịu",
            sublabel: "Đọc buổi tối",
            paper: "#1a202c",
            canvas: "#141821",
            ink: "#e2e8f0",
            mutedInk: "#94a3b8",
            accent: "#60a5fa",
            ruleColor: "#334155",
            codeBg: "#111621",
            isDark: true
        ),
        ReaderThemeOption(
            id: "paper-oled",
            label: "Đen đêm",
            sublabel: "Tương phản dịu",
            paper: "#101216",
            canvas: "#090a0c",
            ink: "#d4d4d8",
            mutedInk: "#8e8e93",
            accent: "#38bdf8",
            ruleColor: "#27272a",
            codeBg: "#181b22",
            isDark: true
        ),
    ]

    private static let legacyThemeAliases: [String: String] = [
        "white": "paper-white",
        "warm-cream": "paper-cream",
        "classic-sepia": "paper-sepia",
        "silk-paper": "paper-oat",
        "rose-tint": "paper-rose",
        "sage-green": "paper-sage",
        "nordic-mist": "paper-mist",
        "slate-dark": "paper-dark",
        "oled-night": "paper-oled",
    ]

    static let inks: [ReaderInkOption] = [
        ReaderInkOption(id: "auto", label: "Tự động theo giấy", color: "auto"),
        ReaderInkOption(id: "#111111", label: "Đen mực (Classic)", color: "#111111"),
        ReaderInkOption(id: "#334155", label: "Than chì (Slate)", color: "#334155"),
        ReaderInkOption(id: "#3b2818", label: "Nâu trầm (Espresso)", color: "#3b2818"),
        ReaderInkOption(id: "#172554", label: "Xanh mực (Navy)", color: "#172554"),
        ReaderInkOption(id: "#143323", label: "Xanh rêu (Forest)", color: "#143323"),
        ReaderInkOption(id: "#e2e8f0", label: "Trắng dịu (Light)", color: "#e2e8f0"),
        ReaderInkOption(id: "#fde68a", label: "Hổ phách (Amber)", color: "#fde68a"),
    ]

    static let textures: [ReaderTextureOption] = [
        ReaderTextureOption(id: "default", label: "Trơn (Mặc định)", sublabel: "Không hiệu ứng vân giấy"),
        ReaderTextureOption(id: "paper-grain", label: "Giấy in sách (Grain)", sublabel: "Hạt giấy tự nhiên"),
        ReaderTextureOption(id: "vintage", label: "Giấy cổ điển (Vintage)", sublabel: "Viền bóng ấm hoài cổ"),
        ReaderTextureOption(id: "linen", label: "Vân vải lanh (Linen)", sublabel: "Sợi dệt ngang dọc"),
        ReaderTextureOption(id: "parchment", label: "Giấy da cừu (Parchment)", sublabel: "Loang màu cổ xưa"),
        ReaderTextureOption(id: "dot-grid", label: "Sổ chấm bi (Dot Grid)", sublabel: "Sổ tay chấm bi"),
        ReaderTextureOption(id: "ruled", label: "Sổ kẻ ngang (Ruled)", sublabel: "Dòng kẻ sổ ghi chép"),
    ]

    static let lineHeightOptions: [(id: String, label: String)] = [
        ("default", "Gốc"),
        ("1.35", "1.35"),
        ("1.5", "1.5"),
        ("1.65", "1.65"),
        ("1.8", "1.8"),
    ]

    static let pageMarginOptions: [(id: String, label: String)] = [
        ("default", "Gốc"),
        ("compact", "Hẹp"),
        ("normal", "Vừa"),
        ("wide", "Rộng"),
    ]

    static let interlinearOpacityOptions: [(id: Int, label: String)] = [
        (35, "Mờ 35%"),
        (55, "Dịu 55%"),
        (80, "Rõ 80%"),
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
            id: "custom",
            label: "Tuỳ chọn (\(normalized.uppercased()))",
            sublabel: normalized.uppercased(),
            paper: normalized,
            canvas: normalized,
            ink: dark ? "#e2e8f0" : "#18181b",
            mutedInk: dark ? "#94a3b8" : "#52525b",
            accent: dark ? "#60a5fa" : "#1d4ed8",
            ruleColor: dark ? "#334155" : "#d4d4d8",
            codeBg: dark ? "#111621" : "#f4f4f5",
            isDark: dark
        )
    }

    /// Parses both the canonical Web/Server `;` + `=` format
    /// (`paper-sepia;ink=#3b2818;tex=vintage;scale=110;lh=1.5;margin=compact`)
    /// and legacy `|` + `:` descriptors.
    static func parseThemeDescriptor(_ raw: String?) -> ReaderThemeDescriptor {
        var result = ReaderThemeDescriptor()
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "default" else { return result }

        let separator: Character = trimmed.contains(";") ? ";" : "|"
        let parts = trimmed
            .split(separator: separator)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return result }

        let first = parts[0]
        var startIdx = 0
        if !first.contains("=") && !first.contains(":") {
            let mapped = legacyThemeAliases[first] ?? first
            if mapped == "custom" {
                result.themeId = "custom"
            } else if themes.contains(where: { $0.id == mapped }) {
                result.themeId = mapped
            } else if isValidHexColor(mapped) {
                result.themeId = "custom"
                result.customPaperColor = mapped.lowercased()
            }
            startIdx = 1
        }

        for i in startIdx..<parts.count {
            let token = parts[i]
            let kvSep: Character? = token.contains("=") ? "=" : (token.contains(":") ? ":" : nil)
            guard let sep = kvSep, let sepIdx = token.firstIndex(of: sep) else { continue }
            let key = String(token[..<sepIdx]).trimmingCharacters(in: .whitespaces)
            let val = String(token[token.index(after: sepIdx)...]).trimmingCharacters(in: .whitespaces)
            guard !val.isEmpty else { continue }

            switch key {
            case "paper":
                if isValidHexColor(val) {
                    result.themeId = "custom"
                    result.customPaperColor = val.lowercased()
                }
            case "ink":
                if val == "auto" || isValidHexColor(val) {
                    result.inkColor = val.lowercased()
                }
            case "tex":
                if textures.contains(where: { $0.id == val }) {
                    result.textureId = val
                }
            case "scale":
                if let n = Int(val) {
                    result.fontScale = max(60, min(200, n))
                }
            case "lh":
                if ["default", "1.35", "1.5", "1.65", "1.8"].contains(val) {
                    result.lineHeight = val
                }
            case "margin":
                if ["default", "compact", "normal", "wide"].contains(val) {
                    result.pageMargin = val
                }
            case "il":
                result.interlinear = (val == "1" || val == "true")
            case "ilop":
                if let n = Int(val), [35, 55, 80].contains(n) {
                    result.interlinearOpacity = n
                }
            default:
                break
            }
        }

        if result.themeId == "custom" && !isValidHexColor(result.customPaperColor) {
            result.themeId = "default"
            result.customPaperColor = ""
        }
        return result
    }

    /// Serializes into the exact same `;` + `=` format as Web (`readerAppearance.ts`)
    /// so server-stored `readerTheme` and `defaultTheme` sync identically across Web, iPhone, and iPad.
    static func serializeThemeDescriptor(_ desc: ReaderThemeDescriptor) -> String {
        var normalized = desc
        if isValidHexColor(normalized.themeId) {
            normalized.customPaperColor = normalized.themeId.lowercased()
            normalized.themeId = "custom"
        } else if let mapped = legacyThemeAliases[normalized.themeId] {
            normalized.themeId = mapped
        }

        let base: String
        if normalized.themeId == "custom" && isValidHexColor(normalized.customPaperColor) {
            base = "custom"
        } else if themes.contains(where: { $0.id == normalized.themeId }) {
            base = normalized.themeId
        } else {
            base = "default"
        }

        var segments: [String] = [base]
        if base == "custom" && isValidHexColor(normalized.customPaperColor) {
            segments.append("paper=\(normalized.customPaperColor.lowercased())")
        }
        if !normalized.inkColor.isEmpty && normalized.inkColor != "auto" && isValidHexColor(normalized.inkColor) {
            segments.append("ink=\(normalized.inkColor.lowercased())")
        }
        if !normalized.textureId.isEmpty && normalized.textureId != "default" {
            segments.append("tex=\(normalized.textureId)")
        }
        if normalized.fontScale != 100 {
            segments.append("scale=\(max(60, min(200, normalized.fontScale)))")
        }
        if !normalized.lineHeight.isEmpty && normalized.lineHeight != "default" {
            segments.append("lh=\(normalized.lineHeight)")
        }
        if !normalized.pageMargin.isEmpty && normalized.pageMargin != "default" {
            segments.append("margin=\(normalized.pageMargin)")
        }
        if normalized.interlinear {
            segments.append("il=1")
        }
        if normalized.interlinearOpacity != 55 && [35, 55, 80].contains(normalized.interlinearOpacity) {
            segments.append("ilop=\(normalized.interlinearOpacity)")
        }

        return segments.joined(separator: ";")
    }

    static func getTheme(_ themeIdOrDescriptor: String?) -> ReaderThemeOption {
        let desc = parseThemeDescriptor(themeIdOrDescriptor)
        if desc.themeId == "custom" && isValidHexColor(desc.customPaperColor) {
            return buildCustomThemeFromHex(desc.customPaperColor)
        }
        if let found = themes.first(where: { $0.id == desc.themeId }) {
            return found
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
        viewMode: String,
        topOverlayInset: CGFloat = 0
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
            const accentColor = "\(theme.accent)";
            const ruleColor = "\(theme.ruleColor)";
            const codeBg = "\(theme.codeBg)";
            const isDarkSurface = \(isDarkSurface ? "true" : "false");
            const textureId = "\(desc.textureId)";
            const interlinear = \(desc.interlinear ? "true" : "false");
            const interlinearOpacity = \(desc.interlinearOpacity);
            const isPhone = \(isPhone ? "true" : "false");
            const viewMode = "\(viewMode)";
            const topOverlayInset = \(Int(topOverlayInset));

            document.documentElement.setAttribute('data-bkb-reader', '1');
            document.documentElement.style.setProperty('--bkb-top-inset', topOverlayInset + 'px');
            const legacyDyn = document.getElementById('phone-dyn-style');
            if (legacyDyn) legacyDyn.remove();

            // 1. Google Font link (non-render-blocking so WebKit never stalls applying CSS)
            let fontLink = document.getElementById(FONT_LINK_ID);
            if (fontId !== 'default' && googleFontUrl) {
                if (!fontLink) {
                    fontLink = document.createElement('link');
                    fontLink.id = FONT_LINK_ID;
                    fontLink.rel = 'stylesheet';
                    fontLink.media = 'print';
                    fontLink.onload = function() { fontLink.media = 'all'; };
                    head.appendChild(fontLink);
                }
                if (fontLink.href !== googleFontUrl) {
                    fontLink.media = 'print';
                    fontLink.onload = function() { fontLink.media = 'all'; };
                    fontLink.href = googleFontUrl;
                }
            } else if (fontLink) {
                fontLink.remove();
            }

            const SVG_NOISE_DATA_URI = 'url("data:image/svg+xml,%3Csvg xmlns=\\'http://www.w3.org/2000/svg\\' width=\\'160\\' height=\\'160\\'%3E%3Cfilter id=\\'n\\'%3E%3CfeTurbulence type=\\'fractalNoise\\' baseFrequency=\\'0.82\\' numOctaves=\\'4\\' stitchTiles=\\'stitch\\'/%3E%3C/filter%3E%3Crect width=\\'100%25\\' height=\\'100%25\\' filter=\\'url(%23n)\\' opacity=\\'0.065\\'/%3E%3C/svg%3E")';

            function buildTextureCss(tex, isDark) {
                if (!tex || tex === 'default') return '';
                const lineAlpha = isDark ? 'rgba(255, 255, 255, 0.055)' : 'rgba(60, 42, 24, 0.075)';
                const dotAlpha = isDark ? 'rgba(255, 255, 255, 0.10)' : 'rgba(60, 42, 24, 0.14)';

                let bgImage = '';
                let bgSize = '';
                let boxShadow = '';

                switch (tex) {
                    case 'paper-grain':
                        bgImage = SVG_NOISE_DATA_URI;
                        bgSize = '160px 160px';
                        break;
                    case 'vintage':
                        bgImage = `radial-gradient(ellipse at center, transparent 52%, ${isDark ? 'rgba(0, 0, 0, 0.42)' : 'rgba(120, 82, 38, 0.16)'} 100%), ${SVG_NOISE_DATA_URI}`;
                        bgSize = '100% 100%, 160px 160px';
                        boxShadow = isDark
                            ? 'inset 0 0 36px rgba(0, 0, 0, 0.48)'
                            : 'inset 0 0 38px rgba(110, 74, 32, 0.18)';
                        break;
                    case 'linen':
                        bgImage = `repeating-linear-gradient(0deg, ${lineAlpha} 0px, ${lineAlpha} 1px, transparent 1px, transparent 4px), repeating-linear-gradient(90deg, ${lineAlpha} 0px, ${lineAlpha} 1px, transparent 1px, transparent 4px)`;
                        bgSize = '4px 4px';
                        break;
                    case 'parchment':
                        bgImage = `radial-gradient(circle at 20% 25%, ${isDark ? 'rgba(255, 215, 150, 0.04)' : 'rgba(180, 130, 65, 0.10)'} 0%, transparent 55%), radial-gradient(circle at 80% 75%, ${isDark ? 'rgba(0, 0, 0, 0.35)' : 'rgba(145, 98, 42, 0.13)'} 0%, transparent 60%), ${SVG_NOISE_DATA_URI}`;
                        bgSize = '100% 100%, 100% 100%, 160px 160px';
                        boxShadow = isDark
                            ? 'inset 0 0 42px rgba(0, 0, 0, 0.5)'
                            : 'inset 0 0 42px rgba(120, 80, 30, 0.18)';
                        break;
                    case 'dot-grid':
                        bgImage = `radial-gradient(${dotAlpha} 1.1px, transparent 1.1px)`;
                        bgSize = '18px 18px';
                        break;
                    case 'ruled':
                        bgImage = `repeating-linear-gradient(to bottom, transparent 0px, transparent 25px, ${lineAlpha} 25px, ${lineAlpha} 26px)`;
                        bgSize = '100% 26px';
                        break;
                    default:
                        return '';
                }

                // Render texture on a single full-viewport fixed overlay (`body::before`)
                // and make inner `.book-page` containers transparent so the page is NEVER
                // split into two regions when `.book-page` is shorter than the screen height.
                return `
                    html, body, body.book-standalone {
                        min-height: 100vh !important;
                    }
                    .book-page, .book-page--sheet, .sheet-flow, .prose-page, .toc-page, .title-page, main, article {
                        background: transparent !important;
                        background-color: transparent !important;
                        background-image: none !important;
                        box-shadow: none !important;
                        position: relative !important;
                        z-index: 2 !important;
                    }
                    .book-page--sheet::after {
                        display: none !important;
                        content: none !important;
                    }
                    body::before {
                        content: '' !important;
                        position: fixed !important;
                        inset: 0 !important;
                        width: 100vw !important;
                        height: 100vh !important;
                        pointer-events: none !important;
                        z-index: 1 !important;
                        background-image: ${bgImage} !important;
                        ${bgSize ? `background-size: ${bgSize} !important;` : ''}
                        ${boxShadow ? `box-shadow: ${boxShadow} !important;` : ''}
                    }
                `;
            }

            function buildCss(scalePct, lhVal, marginVal) {
                const blocks = [];
                const R = 'html[data-bkb-reader="1"][data-bkb-reader="1"][data-bkb-reader="1"][data-bkb-reader="1"]';
                const R_EXCL = `${R}[data-bkb-reader="1"]`;
                const isCoverOrTitlePage = Boolean(
                    document.querySelector(
                        'article.cover, article.title-page, article.half-title, .prose-page.cover, .prose-page.title-page, .prose-page.half-title, .sheet-flow.cover, .sheet-flow.title-page, .title-page-container, .cover-wrap, .cover-content'
                    )
                );

                if (fontId !== 'default' && fontFamily) {
                    blocks.push(`
                        :root {
                            --font-display: ${fontFamily} !important;
                            --font-ui: ${fontFamily} !important;
                            --font-serif: ${fontFamily} !important;
                            --font-sans: ${fontFamily} !important;
                        }
                        ${R} body,
                        ${R} .book-page,
                        ${R} .prose-page,
                        ${R} .sheet-flow,
                        ${R} .toc-page,
                        ${R} .title-book,
                        ${R} .subtitle-book,
                        ${R} .author-book,
                        ${R} .toc-title,
                        ${R} .toc-row,
                        ${R} .book-page :is(p, li, div, blockquote, dd, dt, td, th, figcaption, caption, span, a, em, strong, b, i, u, s, small, sub, sup, mark, label, h1, h2, h3, h4, h5, h6, .running-head, .chapter-running-head, .section-title, .section-number, .chapter-opener, .chapter-title, .preface-title, .exercise-instruction, .exercises-title, .unit-title, .title-book, .subtitle-book, .author-book, .toc-title, .toc-row, .toc-item, .dialogue-line, .idiom-def, .entry-text, .callout-text, .callout-note),
                        ${R} body :is(p, li, blockquote, dd, dt, td, th, figcaption, caption, h1, h2, h3, h4, h5, h6, .running-head, .chapter-running-head, .section-title, .section-number, .chapter-opener, .chapter-title, .preface-title, .exercise-instruction, .exercises-title, .unit-title, .dialogue-line, .idiom-def, .entry-text, .callout-text, .callout-note) {
                            font-family: ${fontFamily} !important;
                        }
                        ${R_EXCL} .book-page :is(pre, code, kbd, samp, pre *, code *, .code-block, .code-block *, .ascii-figure, .ascii-figure *),
                        ${R_EXCL} :is(pre, code, kbd, samp, pre *, code *, .code-block, .code-block *, .ascii-figure, .ascii-figure *) {
                            font-family: var(--font-mono, ui-monospace, "SF Mono", "Courier New", Courier, monospace) !important;
                        }
                        ${R_EXCL} .book-page :is(.math, .math *, .formula, .formula *, .formula-display, .formula-display *),
                        ${R_EXCL} :is(.math, .math *, .formula, .formula *, .formula-display, .formula-display *) {
                            font-family: Georgia, "Times New Roman", serif !important;
                        }
                        ${R_EXCL} .bilingual-subline,
                        ${R_EXCL} .book-page .bilingual-subline {
                            font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif !important;
                        }
                        ${R_EXCL} .voca-lookup-panel,
                        ${R_EXCL} .voca-lookup-panel * {
                            font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif !important;
                        }
                    `);
                } else if (!isCoverOrTitlePage) {
                    blocks.push(`
                        ${R} body,
                        ${R} .book-page:not(.toc):not(.toc-page):not(.copy):not(.copy-page),
                        ${R} .prose-page:not(.toc):not(.toc-page):not(.copy):not(.copy-page),
                        ${R} .sheet-flow,
                        ${R} .prose-page:not(.toc):not(.toc-page):not(.copy):not(.copy-page) :is(p, li, blockquote, dd, dt, td, th, .dialogue-line, .dialogue-row, .idiom-def, .idiom-meaning, .idiom-example, .entry-text, .exercise-instruction, .exercise-item, .matching-item, .definition-item, .term-description, .callout-text, .callout-note),
                        ${R} body :is(p, li, blockquote, dd, dt) {
                            font-family: var(--font-display, Georgia, "Times New Roman", serif) !important;
                        }
                        ${R_EXCL} .book-page :is(pre, code, kbd, samp, pre *, code *, .code-block, .code-block *, .ascii-figure, .ascii-figure *),
                        ${R_EXCL} :is(pre, code, kbd, samp, pre *, code *, .code-block, .code-block *, .ascii-figure, .ascii-figure *) {
                            font-family: var(--font-mono, ui-monospace, "SF Mono", "Courier New", Courier, monospace) !important;
                        }
                        ${R_EXCL} .bilingual-subline,
                        ${R_EXCL} .book-page .bilingual-subline {
                            font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif !important;
                        }
                        ${R_EXCL} .voca-lookup-panel,
                        ${R_EXCL} .voca-lookup-panel * {
                            font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif !important;
                        }
                    `);
                }

                if (!isCoverOrTitlePage) {
                    const fScale = scalePct / 100.0;
                    const bodySizeExpr = isPhone
                        ? (() => {
                              const hpad = viewMode === 'split' ? 28 : 32;
                              const minPt = (13.0 * fScale).toFixed(2);
                              const maxPt = (18.5 * fScale).toFixed(2);
                              const divisor = (18.5 / fScale).toFixed(2);
                              return `clamp(${minPt}pt, calc((100vw - ${hpad}px) / ${divisor}), ${maxPt}pt)`;
                          })()
                        : `calc(11pt * ${fScale.toFixed(3)})`;
                    const defaultLh = isPhone ? '1.7' : '1.45';
                    const lhRule = (lhVal && lhVal !== 'default') ? lhVal : defaultLh;

                    blocks.push(`
                        ${R} {
                            --bkb-body-size: ${bodySizeExpr};
                            --bkb-lh: ${lhRule};
                            font-size: var(--bkb-body-size) !important;
                        }
                        ${R} body,
                        ${R} .book-page,
                        ${R} .prose-page,
                        ${R} .sheet-flow,
                        ${R} .toc-page,
                        ${R} .prose-content,
                        ${R} .unit-page,
                        ${R} .main-content,
                        ${R} main,
                        ${R} article,
                        ${R} :is(p, li, blockquote, dd, dt, td, th),
                        ${R} .book-page :is(p, li, blockquote, dd, dt, td, th),
                        ${R} .prose-page :is(p, li, blockquote, dd, dt, td, th),
                        ${R} .sheet-flow :is(p, li, blockquote, dd, dt, td, th),
                        ${R} .prose-page :is(.exercise-list > li, .comp-box p, .comp-box li, .sidebar-note p, .sidebar-note li, .exercise-4-3-container p.story-paragraph, .listing-callout, .exercise-instruction, .exercise-item, .dialogue-row, .dialogue-line, .idiom-def, .idiom-meaning, .idiom-example, .entry-text, .matching-item, .definition-item, .term-description, .callout-text, .callout-note, .toc-row, .toc-item, .toc-unit-item),
                        ${R} :is(.exercise-list > li, .exercise-instruction, .exercise-item, .dialogue-row, .dialogue-line, .idiom-def, .idiom-meaning, .idiom-example, .entry-text, .matching-item, .definition-item, .term-description, .callout-text, .callout-note, .listing-callout, .toc-row, .toc-item, .toc-unit-item) {
                            font-size: var(--bkb-body-size) !important;
                            line-height: var(--bkb-lh) !important;
                        }
                        ${R_EXCL} :is(h1, .chapter-title, .part-title) {
                            font-size: calc(var(--bkb-body-size) * 1.45) !important;
                            line-height: 1.25 !important;
                        }
                        ${R_EXCL} :is(h2, .section-title, .preface-title, .chapter-opener h2) {
                            font-size: calc(var(--bkb-body-size) * 1.25) !important;
                            line-height: 1.3 !important;
                        }
                        ${R_EXCL} :is(h3, .subsection-title, .exercises-title, .unit-title, .section-title--sub, .section-title--minor, .sidebar-note h3) {
                            font-size: calc(var(--bkb-body-size) * 1.12) !important;
                            line-height: 1.35 !important;
                        }
                        ${R_EXCL} :is(h4, h5, h6) {
                            font-size: calc(var(--bkb-body-size) * 1.04) !important;
                            line-height: 1.38 !important;
                        }
                        ${R_EXCL} :is(.running-head, .chapter-running-head, .page-folio, .preface-folio, .toc-folio, .chapter-folio, .chapter-folio-left, .book-footer, .book-footer .rh-folio, .footnotes, .footnote, figcaption, .caption),
                        ${R_EXCL} :is(.footnotes, .footnote, figcaption, .caption) :is(p, li) {
                            font-size: calc(var(--bkb-body-size) * 0.85) !important;
                            line-height: 1.4 !important;
                        }
                        ${R_EXCL} .prose-page :is(pre, .code-block, .ascii-figure),
                        ${R_EXCL} :is(pre, .code-block, .ascii-figure) {
                            font-size: calc(var(--bkb-body-size) * 0.86) !important;
                            line-height: 1.45 !important;
                        }
                        ${R_EXCL} :is(pre *, .code-block *, .ascii-figure *) {
                            font-size: inherit !important;
                            line-height: inherit !important;
                        }
                        ${R_EXCL} :is(:not(pre) > code, kbd, samp) {
                            font-size: 0.9em !important;
                        }
                        ${R_EXCL} .bilingual-subline {
                            font-size: 0.74em !important;
                            line-height: 1.36 !important;
                        }
                    `);
                }

                if (marginVal && marginVal !== 'default') {
                    if (isPhone) {
                        const padMap = {
                            compact: ['10px', '8px', '28px'],
                            normal: ['16px', '16px', '32px'],
                            wide: ['20px', '26px', '36px']
                        };
                        const p = padMap[marginVal];
                        if (p) {
                            blocks.push(`
                                ${R} body, ${R} body.book-standalone {
                                    padding: calc(${p[0]} + var(--bkb-top-inset, 0px)) ${p[1]} ${p[2]} !important;
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
                                ${R} body, ${R} body.book-standalone {
                                    padding: ${pad} !important;
                                }
                            `);
                        }
                    }
                } else if (isPhone) {
                    const baseTop = viewMode === 'split' ? '12px' : '18px';
                    const hPad = viewMode === 'split' ? '14px' : '16px';
                    const bottom = viewMode === 'split' ? '28px' : '36px';
                    blocks.push(`
                        ${R} body, ${R} body.book-standalone {
                            padding: calc(${baseTop} + var(--bkb-top-inset, 0px)) ${hPad} ${bottom} !important;
                        }
                    `);
                }

                if (hasCustomPaper || hasCustomInk) {
                    blocks.push(`
                        :root {
                            ${hasCustomPaper ? `--book-paper: ${paperColor} !important; --paper: ${paperColor} !important; --canvas: ${paperColor} !important; --muted: ${mutedInk} !important; --book-accent: ${accentColor} !important; --accent: ${accentColor} !important; --book-rule: ${ruleColor} !important; --rule: ${ruleColor} !important; --rule-soft: ${ruleColor} !important; --code-bg: ${codeBg} !important;` : ''}
                            ${effectiveInk ? `--book-ink: ${effectiveInk} !important; --ink: ${effectiveInk} !important;` : ''}
                            ${mutedInk ? `--muted-ink: ${mutedInk} !important;` : ''}
                        }
                        ${hasCustomPaper ? `
                        html, body, body.book-standalone {
                            min-height: 100vh !important;
                            background-color: ${paperColor} !important;
                            background: ${paperColor} !important;
                        }
                        .book-page, .book-page--sheet, .sheet-flow, .prose-page, .toc-page, .title-page, main, article {
                            background-color: transparent !important;
                            background: transparent !important;
                            box-shadow: none !important;
                        }
                        .book-page--sheet::after {
                            display: none !important;
                            content: none !important;
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
                        blocks.push(texCss);
                    }
                }

                if (interlinear) {
                    const alpha = ((interlinearOpacity || 55) / 100.0).toFixed(2);
                    const subColor = isDarkSurface
                        ? `rgba(186, 198, 216, ${alpha})`
                        : `rgba(88, 78, 66, ${alpha})`;
                    const dotColor = isDarkSurface
                        ? 'rgba(148, 163, 184, 0.10)'
                        : 'rgba(120, 113, 108, 0.13)';
                    blocks.push(`
                        html, body, body.book-standalone,
                        .book-page, .book-page.book-page--sheet,
                        .sheet-flow, .prose-page, .prose-page.chapter-page,
                        .prose-page.chapter-body-page, .prose-page.manning-chapter-page,
                        .prose-page.ocp-chapter-page, .prose-page.copy,
                        .prose-page.preface-page, .sheet-flow.prose-page,
                        .toc-page, .unit-page, .prose-content, .toc-columns-container,
                        article.sheet-flow, article.prose-page {
                            height: auto !important;
                            max-height: none !important;
                            overflow: visible !important;
                        }
                        .book-page--sheet::after, .book-page::after {
                            display: none !important;
                            content: none !important;
                        }
                        .prose-page, .sheet-flow {
                            padding-bottom: 24mm !important;
                        }
                        .prose-page p, .prose-page li, .prose-page blockquote, .prose-page dd p {
                            text-align: left !important;
                        }
                        .bilingual-subline {
                            display: block !important;
                            font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif !important;
                            font-size: 0.74em !important;
                            line-height: 1.36 !important;
                            font-weight: 400 !important;
                            font-style: normal !important;
                            color: ${subColor} !important;
                            background: transparent !important;
                            margin: 1.5px 0 7px 0 !important;
                            padding: 0 0 3px 0 !important;
                            text-indent: 0 !important;
                            text-align: left !important;
                            letter-spacing: normal !important;
                            user-select: none !important;
                            -webkit-user-select: none !important;
                            pointer-events: none !important;
                            border-bottom: 1px dotted ${dotColor} !important;
                        }
                        .bilingual-subline::before {
                            content: attr(data-subtext);
                        }
                    `);
                }

                return blocks.join('\\n');
            }

            if (!document.documentElement.dataset.bkbOriginalPaper) {
                const rootCs = getComputedStyle(document.documentElement);
                const tokenPaper = (rootCs.getPropertyValue('--book-paper') || rootCs.getPropertyValue('--paper') || '').trim();
                const bodyBg = document.body ? getComputedStyle(document.body).backgroundColor : '';
                document.documentElement.dataset.bkbOriginalPaper = tokenPaper || bodyBg || '#f4f1ea';
            }

            if (!hasCustomPaper) {
                const origPaper = document.documentElement.dataset.bkbOriginalPaper || '#f4f1ea';
                document.documentElement.style.setProperty('background-color', origPaper, 'important');
                if (document.body) {
                    document.body.style.setProperty('background-color', origPaper, 'important');
                }
            } else {
                document.documentElement.style.setProperty('background-color', paperColor, 'important');
                if (document.body) {
                    document.body.style.setProperty('background-color', paperColor, 'important');
                }
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
                } else if (styleEl.parentNode !== head || styleEl.nextElementSibling) {
                    head.appendChild(styleEl);
                }
                styleEl.textContent = cssText;
            };

            const appliedScale = requestedScale || 100;
            const appliedLh = requestedLh;
            const appliedMargin = requestedMargin;
            ensureStyle(buildCss(appliedScale, appliedLh, appliedMargin));

            // Compute effective background RGBA for WKWebView native canvas
            let rgba = null;
            const candidates = [
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
                rgba = [Number(match[1]), Number(match[2]), Number(match[3]), alpha];
                break;
            }

            return {
                appliedFontScale: appliedScale,
                clampedByA4: false,
                atMaxA4Scale: false,
                rgba: rgba
            };
        })();
        """
    }
}
