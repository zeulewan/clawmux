import SwiftUI

// MARK: - Scroll Top Detector (auto-load older messages)

struct ScrollTopDetector: ViewModifier {
    @Binding var isLoadingOlder: Bool
    var hasOlderMessages: Bool
    var sessionId: String?
    var load: (String, @escaping () -> Void) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            // Use CGFloat so action fires on every scroll event — avoids Bool toggle dead zone
            // where nearTop stays true after a load and action never re-fires.
            content.onScrollGeometryChange(for: CGFloat.self) { geo in
                // Distance from top: 0 = at top, large positive = at bottom.
                // defaultScrollAnchor(.bottom) makes contentOffset.y negative near top, so
                // use this derived value instead of raw contentOffset.y.
                geo.contentOffset.y + geo.contentSize.height - geo.containerSize.height
            } action: { _, distanceFromTop in
                guard distanceFromTop < 200, !isLoadingOlder, hasOlderMessages, let sid = sessionId else { return }
                isLoadingOlder = true
                load(sid) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { isLoadingOlder = false }
                }
            }
        } else {
            content
        }
    }
}

// MARK: - Scroll Bottom Detector

struct ScrollBottomDetector: ViewModifier {
    @Binding var isAtBottom: Bool
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: Bool.self) { geo in
                geo.contentOffset.y >= geo.contentSize.height - geo.containerSize.height - 120
            } action: { _, atBottom in
                isAtBottom = atBottom
            }
        } else {
            content
        }
    }
}

// MARK: - Markdown Content View

struct MarkdownContentView: View {
    let text: String
    let foreground: Color
    var fontSize: CGFloat = 15

    /// Parses inline markdown (bold, italic, `code`) using AttributedString so
    /// backtick code spans render as monospaced — LocalizedStringKey does not handle `code`.
    private static func inlineMarkdown(_ str: String) -> AttributedString {
        (try? AttributedString(markdown: str,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(str)
    }

    private enum Block {
        case text(String)
        case header(Int, String)
        case bullet(String)
        case numbered(String, String)
        case code(String, String)   // (language, content)
        case blockquote(String)
        case rule
        case spacing
    }

    private func parse(_ raw: String) -> [Block] {
        var result: [Block] = []
        var lines  = raw.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i]
            // Code fence
            if line.hasPrefix("```") {
                let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                i += 1
                while i < lines.count && !lines[i].hasPrefix("```") {
                    codeLines.append(lines[i]); i += 1
                }
                if i < lines.count { i += 1 }
                result.append(.code(lang, codeLines.joined(separator: "\n")))
                continue
            }
            if line.hasPrefix("### ") { result.append(.header(3, String(line.dropFirst(4)))); i += 1; continue }
            if line.hasPrefix("## ")  { result.append(.header(2, String(line.dropFirst(3)))); i += 1; continue }
            if line.hasPrefix("# ")   { result.append(.header(1, String(line.dropFirst(2)))); i += 1; continue }
            if line.hasPrefix("> ") { result.append(.blockquote(String(line.dropFirst(2)))); i += 1; continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" || trimmed == "***" || trimmed == "___" { result.append(.rule); i += 1; continue }
            let stripped = line.drop(while: { $0 == " " || $0 == "\t" })
            if stripped.hasPrefix("- ") || stripped.hasPrefix("* ") || stripped.hasPrefix("+ ") {
                result.append(.bullet(String(stripped.dropFirst(2)))); i += 1; continue
            }
            if let m = stripped.firstMatch(of: /^(\d+)\. (.+)/) {
                result.append(.numbered(String(m.output.1), String(m.output.2))); i += 1; continue
            }
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if case .spacing? = result.last {} else { result.append(.spacing) }
                i += 1; continue
            }
            // Merge consecutive plain text lines into one paragraph — single newline = space
            // (standard markdown: only double newline creates a paragraph break)
            if case .text(let prev) = result.last {
                result[result.count - 1] = .text(prev + " " + line)
            } else {
                result.append(.text(line))
            }
            i += 1
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(parse(text).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        switch block {
        case .spacing:
            Color.clear.frame(height: 3)

        case .text(let str):
            Text(Self.inlineMarkdown(str))
                .font(.system(size: fontSize))
                .foregroundStyle(foreground)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)

        case .header(let level, let str):
            let sz: CGFloat = level == 1 ? fontSize + 4 : level == 2 ? fontSize + 1 : fontSize - 1
            let wt: Font.Weight = level <= 2 ? .bold : .semibold
            Text(Self.inlineMarkdown(str))
                .font(.system(size: sz, weight: wt))
                .foregroundStyle(foreground)
                .fixedSize(horizontal: false, vertical: true)

        case .bullet(let str):
            HStack(alignment: .top, spacing: 6) {
                Text("•")
                    .font(.system(size: fontSize))
                    .foregroundStyle(Color.cTextSec)
                    .frame(width: 10)
                Text(Self.inlineMarkdown(str))
                    .font(.system(size: fontSize))
                    .foregroundStyle(foreground)
                    .lineSpacing(1)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .numbered(let num, let str):
            HStack(alignment: .top, spacing: 6) {
                Text("\(num).")
                    .font(.system(size: fontSize))
                    .foregroundStyle(Color.cTextSec)
                    .frame(width: 22, alignment: .trailing)
                Text(Self.inlineMarkdown(str))
                    .font(.system(size: fontSize))
                    .foregroundStyle(foreground)
                    .lineSpacing(1)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .blockquote(let str):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2).fill(Color.cTextTer.opacity(0.5)).frame(width: 3)
                Text(Self.inlineMarkdown(str))
                    .font(.system(size: fontSize))
                    .foregroundStyle(foreground.opacity(0.75))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 2)

        case .rule:
            Divider().background(Color.cBorder)

        case .code(let lang, let content):
            VStack(alignment: .leading, spacing: 0) {
                // Header: language label + copy button (mirrors web .code-copy-btn)
                HStack {
                    Text(lang.isEmpty ? "code" : lang)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.cTextTer)
                    Spacer()
                    Button {
                        UIPasteboard.general.string = content
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.cTextTer)
                            .padding(4)
                    }
                }
                .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 2)

                ScrollView(.horizontal, showsIndicators: false) {
                    Text(content)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.cText)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 8)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.canvas2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.cBorder, lineWidth: 0.5))
        }
    }
}
