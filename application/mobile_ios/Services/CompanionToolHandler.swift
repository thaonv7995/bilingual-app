import Foundation

/// Handles tool calls from the AI companion and dispatches them to the reader UI.
///
/// Each tool call is received as a JSON string from the Realtime API.
/// The handler parses the arguments, executes the action via callbacks,
/// and returns a result dictionary for the AI.
@MainActor
final class CompanionToolHandler {
    // MARK: - Callbacks (set by ReaderView to wire into existing functionality)

    /// Highlight a word/phrase on the current page. Parameters: (text, color hex).
    var onHighlightText: ((String, String) async -> Bool)?
    /// Remove highlight for a word/phrase.
    var onRemoveHighlight: ((String) async -> Bool)?
    /// Look up a word in Voca dictionary. Returns definition string or nil.
    var onLookupWord: ((String) async -> String?)?
    /// Add a word to user's Voca collection.
    var onAddWordToVoca: ((String) async -> Bool)?
    /// Navigate to a specific page.
    var onGoToPage: ((Int) -> Void)?
    /// Go to next page.
    var onNextPage: (() -> Void)?
    /// Go to previous page.
    var onPreviousPage: (() -> Void)?
    /// Get page text content. Parameters: (page?, lang?) → returns text.
    var getPageContent: ((Int?, String?) async -> String)?
    /// Get current reading context (page, viewMode, book info).
    var getCurrentContext: (() -> [String: Any])?

    /// Called when a tool produces user-visible feedback (for UI toast).
    var onToolFeedback: ((String) -> Void)?

    // MARK: - Tool Definitions (for Realtime session config)

    static let toolDefinitions: [[String: Any]] = [
        [
            "type": "function",
            "name": "highlight_text",
            "description": "Highlight a word or phrase on the current page with a color. Use when the user asks to mark, highlight, or annotate text.",
            "parameters": [
                "type": "object",
                "properties": [
                    "text": [
                        "type": "string",
                        "description": "The exact word or phrase to highlight on the page"
                    ],
                    "color": [
                        "type": "string",
                        "enum": ["yellow", "blue", "pink", "green"],
                        "description": "The highlight color. Default is yellow."
                    ]
                ],
                "required": ["text"]
            ] as [String: Any]
        ],
        [
            "type": "function",
            "name": "remove_highlight",
            "description": "Remove a highlight from the current page.",
            "parameters": [
                "type": "object",
                "properties": [
                    "text": [
                        "type": "string",
                        "description": "The highlighted text to remove"
                    ]
                ],
                "required": ["text"]
            ] as [String: Any]
        ],
        [
            "type": "function",
            "name": "lookup_word",
            "description": "Look up an English word in the Voca dictionary and show its definition panel to the user.",
            "parameters": [
                "type": "object",
                "properties": [
                    "word": [
                        "type": "string",
                        "description": "The English word to look up"
                    ]
                ],
                "required": ["word"]
            ] as [String: Any]
        ],
        [
            "type": "function",
            "name": "add_word_to_voca",
            "description": "Add a new English word to the user's Voca vocabulary collection for later review.",
            "parameters": [
                "type": "object",
                "properties": [
                    "word": [
                        "type": "string",
                        "description": "The English word to add"
                    ]
                ],
                "required": ["word"]
            ] as [String: Any]
        ],
        [
            "type": "function",
            "name": "go_to_page",
            "description": "Navigate to a specific page number in the book.",
            "parameters": [
                "type": "object",
                "properties": [
                    "page": [
                        "type": "integer",
                        "description": "The page number to navigate to"
                    ]
                ],
                "required": ["page"]
            ] as [String: Any]
        ],
        [
            "type": "function",
            "name": "next_page",
            "description": "Go to the next page.",
            "parameters": [
                "type": "object",
                "properties": [:] as [String: Any]
            ] as [String: Any]
        ],
        [
            "type": "function",
            "name": "previous_page",
            "description": "Go to the previous page.",
            "parameters": [
                "type": "object",
                "properties": [:] as [String: Any]
            ] as [String: Any]
        ],
        [
            "type": "function",
            "name": "get_page_content",
            "description": "Get the text content of a page. If page is not specified, returns the current page. If lang is not specified, returns both English and Vietnamese.",
            "parameters": [
                "type": "object",
                "properties": [
                    "page": [
                        "type": "integer",
                        "description": "Page number (optional, defaults to current page)"
                    ],
                    "lang": [
                        "type": "string",
                        "enum": ["en", "vi"],
                        "description": "Language (optional, defaults to both)"
                    ]
                ]
            ] as [String: Any]
        ],
        [
            "type": "function",
            "name": "get_current_context",
            "description": "Get information about what the user is currently reading: page number, view mode, book title.",
            "parameters": [
                "type": "object",
                "properties": [:] as [String: Any]
            ] as [String: Any]
        ],
    ]

    // MARK: - Color mapping

    private static let colorMap: [String: String] = [
        "yellow": "#fde68a",
        "blue": "#93c5fd",
        "pink": "#f9a8d4",
        "green": "#86efac",
    ]

    private static let colorNameVi: [String: String] = [
        "yellow": "vàng",
        "blue": "xanh dương",
        "pink": "hồng",
        "green": "xanh lá",
    ]

    // MARK: - Handle Tool Call

    /// Process a tool call from the AI and return the result as a JSON string.
    func handleToolCall(name: String, argumentsJSON: String) async -> String {
        let args = parseArgs(argumentsJSON)
        let result: [String: Any]

        switch name {
        case "highlight_text":
            result = await handleHighlightText(args)
        case "remove_highlight":
            result = await handleRemoveHighlight(args)
        case "lookup_word":
            result = await handleLookupWord(args)
        case "add_word_to_voca":
            result = await handleAddWordToVoca(args)
        case "go_to_page":
            result = handleGoToPage(args)
        case "next_page":
            result = handleNextPage()
        case "previous_page":
            result = handlePreviousPage()
        case "get_page_content":
            result = await handleGetPageContent(args)
        case "get_current_context":
            result = handleGetCurrentContext()
        default:
            result = ["success": false, "error": "Unknown tool: \(name)"]
        }

        if let data = try? JSONSerialization.data(withJSONObject: result),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        return "{\"success\": false, \"error\": \"Failed to serialize result\"}"
    }

    // MARK: - Individual Handlers

    private func handleHighlightText(_ args: [String: Any]) async -> [String: Any] {
        guard let text = args["text"] as? String, !text.isEmpty else {
            return ["success": false, "error": "Missing 'text' parameter"]
        }
        let colorName = (args["color"] as? String) ?? "yellow"
        let colorHex = Self.colorMap[colorName] ?? "#fde68a"
        let colorVi = Self.colorNameVi[colorName] ?? colorName

        guard let handler = onHighlightText else {
            return ["success": false, "error": "Highlight not available"]
        }
        // Fire-and-forget: return immediately, run in background
        let feedback = onToolFeedback
        Task { @MainActor in
            let success = await handler(text, colorHex)
            if success {
                feedback?("✅ Đã highlight '\(text)' màu \(colorVi)")
            }
        }
        return ["success": true, "message": "Highlighting '\(text)' in \(colorName)"]
    }

    private func handleRemoveHighlight(_ args: [String: Any]) async -> [String: Any] {
        guard let text = args["text"] as? String, !text.isEmpty else {
            return ["success": false, "error": "Missing 'text' parameter"]
        }
        guard let handler = onRemoveHighlight else {
            return ["success": false, "error": "Remove highlight not available"]
        }
        // Fire-and-forget
        let feedback = onToolFeedback
        Task { @MainActor in
            let success = await handler(text)
            if success {
                feedback?("🗑️ Đã xóa highlight '\(text)'")
            }
        }
        return ["success": true, "message": "Removing highlight for '\(text)'"]
    }

    // lookup_word stays synchronous — AI needs the definition to read back
    private func handleLookupWord(_ args: [String: Any]) async -> [String: Any] {
        guard let word = args["word"] as? String, !word.isEmpty else {
            return ["success": false, "error": "Missing 'word' parameter"]
        }
        if let handler = onLookupWord {
            if let definition = await handler(word) {
                onToolFeedback?("📖 Tra từ '\(word)'")
                return ["success": true, "word": word, "definition": definition]
            } else {
                return ["success": false, "error": "Word '\(word)' not found in Voca"]
            }
        }
        return ["success": false, "error": "Voca lookup not available"]
    }

    private func handleAddWordToVoca(_ args: [String: Any]) async -> [String: Any] {
        guard let word = args["word"] as? String, !word.isEmpty else {
            return ["success": false, "error": "Missing 'word' parameter"]
        }
        guard let handler = onAddWordToVoca else {
            return ["success": false, "error": "Voca add not available"]
        }
        // Fire-and-forget
        let feedback = onToolFeedback
        Task { @MainActor in
            let success = await handler(word)
            if success {
                feedback?("📚 Đã thêm '\(word)' vào Voca")
            }
        }
        return ["success": true, "message": "Adding '\(word)' to Voca collection"]
    }

    private func handleGoToPage(_ args: [String: Any]) -> [String: Any] {
        guard let page = args["page"] as? Int else {
            return ["success": false, "error": "Missing 'page' parameter"]
        }
        onGoToPage?(page)
        onToolFeedback?("📄 Chuyển sang trang \(page)")
        return ["success": true, "message": "Navigated to page \(page)"]
    }

    private func handleNextPage() -> [String: Any] {
        onNextPage?()
        onToolFeedback?("📄 Trang tiếp theo")
        return ["success": true, "message": "Navigated to next page"]
    }

    private func handlePreviousPage() -> [String: Any] {
        onPreviousPage?()
        onToolFeedback?("📄 Trang trước")
        return ["success": true, "message": "Navigated to previous page"]
    }

    private func handleGetPageContent(_ args: [String: Any]) async -> [String: Any] {
        let page = args["page"] as? Int
        let lang = args["lang"] as? String
        if let handler = getPageContent {
            let content = await handler(page, lang)
            return ["success": true, "content": content]
        }
        return ["success": false, "error": "Page content not available"]
    }

    private func handleGetCurrentContext() -> [String: Any] {
        if let handler = getCurrentContext {
            let context = handler()
            var result: [String: Any] = ["success": true]
            for (key, value) in context {
                result[key] = value
            }
            return result
        }
        return ["success": false, "error": "Context not available"]
    }

    // MARK: - Helpers

    private func parseArgs(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return dict
    }
}
