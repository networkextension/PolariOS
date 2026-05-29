import SwiftUI
import AppKit

/// Markdown renderer for chat bubbles. Block parsing is custom (so we
/// can give code blocks their own copy button and language label);
/// inline runs go through Apple's AttributedString parser the same way
/// iOS's `renderMarkdown(_:color:)` does, so headers / bold / italic /
/// inline code / links land identically on both platforms. Partial
/// markup mid-stream (e.g. unterminated `**bold`) degrades to raw
/// characters rather than throwing.

enum MarkdownBlock {
    case paragraph(String)
    case header(level: Int, text: String)
    case unorderedListItem(String)
    case orderedListItem(number: Int, text: String)
    case codeBlock(language: String?, content: String)
    case blockquote(String)
}

struct MarkdownView: View {
    let text: String
    /// Base body font size. Headers scale up relative to this.
    let baseFontSize: CGFloat

    init(text: String, baseFontSize: CGFloat = AppEnvironment.chatFontSizeDefault) {
        self.text = text
        self.baseFontSize = baseFontSize
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { idx, block in
                blockView(block).id(idx)
            }
        }
    }

    private var blocks: [MarkdownBlock] { parseMarkdownBlocks(text) }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let s):
            inlineText(s)
                .font(.system(size: baseFontSize))
                .fixedSize(horizontal: false, vertical: true)
        case .header(let level, let text):
            inlineText(text)
                .font(headerFont(level: level))
                .padding(.top, level <= 2 ? 4 : 2)
        case .unorderedListItem(let s):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•")
                    .font(.system(size: baseFontSize))
                    .foregroundStyle(.secondary)
                inlineText(s)
                    .font(.system(size: baseFontSize))
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .orderedListItem(let n, let s):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(n).")
                    .font(.system(size: baseFontSize))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                inlineText(s)
                    .font(.system(size: baseFontSize))
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .codeBlock(let lang, let content):
            CodeBlockView(language: lang, content: content, fontSize: baseFontSize)
        case .blockquote(let s):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(.secondary.opacity(0.5))
                    .frame(width: 3)
                inlineText(s)
                    .font(.system(size: baseFontSize))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 2)
        }
    }

    private func inlineText(_ s: String) -> Text {
        // Match iOS — AttributedString(markdown:options:.full) preserves
        // bold/italic/inline-code/link runs; we already split block-level
        // structure ourselves so .inlineOnly is the right call here.
        if let attr = try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attr)
        }
        return Text(s)
    }

    private func headerFont(level: Int) -> Font {
        // Scale relative to baseFontSize so zoom moves headers too.
        switch level {
        case 1: return .system(size: baseFontSize * 1.5, weight: .bold)
        case 2: return .system(size: baseFontSize * 1.3, weight: .bold)
        case 3: return .system(size: baseFontSize * 1.15, weight: .bold)
        default: return .system(size: baseFontSize, weight: .semibold)
        }
    }
}

private struct CodeBlockView: View {
    let language: String?
    let content: String
    let fontSize: CGFloat
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if let lang = language, !lang.isEmpty {
                    Text(lang)
                        .font(.system(size: max(10, fontSize - 4), design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: copyToClipboard) {
                    Label(copied ? "已复制" : "复制",
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: max(10, fontSize - 4)))
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.secondary.opacity(0.12))

            ScrollView(.horizontal, showsIndicators: false) {
                Text(content)
                    .font(.system(size: fontSize, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.2)))
    }

    private func copyToClipboard() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(content, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            copied = false
        }
    }
}

// MARK: - Block parser

func parseMarkdownBlocks(_ md: String) -> [MarkdownBlock] {
    var blocks: [MarkdownBlock] = []
    let lines = md.components(separatedBy: "\n")
    var paraBuf: [String] = []
    var i = 0

    func flushParagraph() {
        let joined = paraBuf.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !joined.isEmpty {
            blocks.append(.paragraph(joined))
        }
        paraBuf.removeAll()
    }

    while i < lines.count {
        let line = lines[i]
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // Fenced code block: ``` opens, ``` closes. Language goes after
        // the opening fence. Unterminated fence (mid-stream) consumes
        // to EOF — desirable during streaming so the code appears live.
        if trimmed.hasPrefix("```") {
            flushParagraph()
            let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            var body: [String] = []
            i += 1
            while i < lines.count {
                if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    i += 1
                    break
                }
                body.append(lines[i])
                i += 1
            }
            blocks.append(.codeBlock(language: lang.isEmpty ? nil : lang,
                                     content: body.joined(separator: "\n")))
            continue
        }

        // ATX header: 1-6 # then space then text.
        if trimmed.hasPrefix("#") {
            let level = trimmed.prefix(while: { $0 == "#" }).count
            if level <= 6,
               trimmed.count > level,
               trimmed[trimmed.index(trimmed.startIndex, offsetBy: level)] == " " {
                flushParagraph()
                let text = String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                blocks.append(.header(level: level, text: text))
                i += 1
                continue
            }
        }

        // Unordered list item: -, *, + then space.
        if let first = trimmed.first, "-*+".contains(first),
           trimmed.count >= 2,
           trimmed[trimmed.index(after: trimmed.startIndex)] == " " {
            flushParagraph()
            let text = String(trimmed.dropFirst(2))
            blocks.append(.unorderedListItem(text))
            i += 1
            continue
        }

        // Ordered list item: digits then "." then space.
        if let dotIdx = trimmed.firstIndex(of: "."),
           dotIdx > trimmed.startIndex,
           trimmed[..<dotIdx].allSatisfy({ $0.isNumber }),
           let afterDot = trimmed.index(dotIdx, offsetBy: 1, limitedBy: trimmed.endIndex),
           afterDot < trimmed.endIndex,
           trimmed[afterDot] == " " {
            flushParagraph()
            let num = Int(trimmed[..<dotIdx]) ?? 1
            let text = String(trimmed[trimmed.index(after: afterDot)...])
            blocks.append(.orderedListItem(number: num, text: text))
            i += 1
            continue
        }

        // Blockquote: "> text" (require space after >).
        if trimmed.hasPrefix("> ") {
            flushParagraph()
            blocks.append(.blockquote(String(trimmed.dropFirst(2))))
            i += 1
            continue
        }
        if trimmed == ">" {
            flushParagraph()
            blocks.append(.blockquote(""))
            i += 1
            continue
        }

        // Blank line ends the current paragraph.
        if trimmed.isEmpty {
            flushParagraph()
            i += 1
            continue
        }

        paraBuf.append(line)
        i += 1
    }
    flushParagraph()
    return blocks
}

