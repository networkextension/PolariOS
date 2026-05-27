import SwiftUI
import AppKit

/// Lightweight markdown renderer tuned for chat bubbles.
/// Handles: ATX headers (# .. ######), unordered / ordered lists, fenced
/// code blocks, blockquotes, paragraphs. Inline formatting (bold, italic,
/// inline code, links) goes through Apple's AttributedString markdown
/// parser. Things we deliberately don't do: tables, nested lists,
/// embedded HTML — chat bubbles rarely need them and they balloon
/// complexity. Partial markup (mid-stream `**bold`) degrades gracefully
/// to the raw characters.

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
            inlineText(s).fixedSize(horizontal: false, vertical: true)
        case .header(let level, let text):
            inlineText(text)
                .font(headerFont(level: level))
                .padding(.top, level <= 2 ? 4 : 2)
        case .unorderedListItem(let s):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•").foregroundStyle(.secondary)
                inlineText(s).fixedSize(horizontal: false, vertical: true)
            }
        case .orderedListItem(let n, let s):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(n).").foregroundStyle(.secondary).monospacedDigit()
                inlineText(s).fixedSize(horizontal: false, vertical: true)
            }
        case .codeBlock(let lang, let content):
            CodeBlockView(language: lang, content: content)
        case .blockquote(let s):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(.secondary.opacity(0.5))
                    .frame(width: 3)
                inlineText(s)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 2)
        }
    }

    private func inlineText(_ s: String) -> Text {
        if let attr = try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attr)
        }
        return Text(s)
    }

    private func headerFont(level: Int) -> Font {
        switch level {
        case 1: return .system(size: 20, weight: .bold)
        case 2: return .system(size: 17, weight: .bold)
        case 3: return .system(size: 15, weight: .bold)
        default: return .system(size: 13, weight: .semibold)
        }
    }
}

private struct CodeBlockView: View {
    let language: String?
    let content: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if let lang = language, !lang.isEmpty {
                    Text(lang)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: copyToClipboard) {
                    Label(copied ? "已复制" : "复制",
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption2)
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.secondary.opacity(0.12))

            ScrollView(.horizontal, showsIndicators: false) {
                Text(content)
                    .font(.system(.callout, design: .monospaced))
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
