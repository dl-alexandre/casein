import Foundation

enum CaseinTerminalForeground: Equatable {
    case standard
    case green
    case cyan
}

struct CaseinTerminalGlyph: Equatable {
    let row: Int
    let column: Int
    let character: Character
    let foreground: CaseinTerminalForeground
    let bold: Bool
}

/// Bounded presentation parser for the Casein-owned mobile renderer. It emits
/// printable glyphs only. Unsupported control sequences, including terminal
/// string controls such as OSC 52, are consumed and never become pixels.
struct CaseinTerminalANSIParser {
    private let maximumFrameBytes = 65_536

    func glyphs(for bytes: Data, columns: Int) -> [CaseinTerminalGlyph] {
        let bounded = Data(bytes.prefix(maximumFrameBytes))
        return parse(String(decoding: normalizedUTF8(bounded), as: UTF8.self), columns: columns)
    }

    /// UTF-8 preserves C1 controls only when encoded as Unicode. PTYs may also
    /// emit their single-byte 8-bit forms. Normalize standalone C1 bytes while
    /// leaving valid UTF-8 sequences intact.
    private func normalizedUTF8(_ bytes: Data) -> Data {
        let input = Array(bytes)
        var output: [UInt8] = []
        output.reserveCapacity(input.count)
        var index = 0

        while index < input.count {
            let byte = input[index]
            let sequenceLength = utf8SequenceLength(byte)
            if sequenceLength > 1,
               index + sequenceLength <= input.count,
               input[(index + 1)..<(index + sequenceLength)].allSatisfy({ (0x80...0xBF).contains($0) }) {
                output.append(contentsOf: input[index..<(index + sequenceLength)])
                index += sequenceLength
            } else {
                if (0x80...0x9F).contains(byte) {
                    output.append(0xC2)
                }
                output.append(byte)
                index += 1
            }
        }
        return Data(output)
    }

    private func utf8SequenceLength(_ byte: UInt8) -> Int {
        switch byte {
        case 0xC2...0xDF: 2
        case 0xE0...0xEF: 3
        case 0xF0...0xF4: 4
        default: 1
        }
    }

    private func parse(_ value: String, columns: Int) -> [CaseinTerminalGlyph] {
        let boundedColumns = max(columns, 1)
        var glyphs: [CaseinTerminalGlyph] = []
        var row = 0
        var column = 0
        var foreground = CaseinTerminalForeground.standard
        var bold = false
        var index = value.startIndex

        while index < value.endIndex {
            let character = value[index]

            if character == "\u{001B}" {
                index = consumeEscape(
                    in: value,
                    at: index,
                    foreground: &foreground,
                    bold: &bold
                )
                continue
            }

            if character == "\u{009B}" {
                index = consumeCSI(
                    in: value,
                    after: value.index(after: index),
                    foreground: &foreground,
                    bold: &bold
                )
                continue
            }

            if Self.c1StringIntroducers.contains(character) {
                index = consumeControlString(in: value, after: value.index(after: index))
                continue
            }

            if character == "\r" {
                column = 0
            } else if character == "\n" {
                row += 1
                column = 0
            } else if !character.caseinIsTerminalControl {
                glyphs.append(
                    CaseinTerminalGlyph(
                        row: row,
                        column: column,
                        character: character,
                        foreground: foreground,
                        bold: bold
                    )
                )
                column += 1
                if column >= boundedColumns {
                    row += 1
                    column = 0
                }
            }
            index = value.index(after: index)
        }

        return glyphs
    }

    private func consumeEscape(
        in value: String,
        at escape: String.Index,
        foreground: inout CaseinTerminalForeground,
        bold: inout Bool
    ) -> String.Index {
        let introducer = value.index(after: escape)
        guard introducer < value.endIndex else { return value.endIndex }

        switch value[introducer] {
        case "[":
            return consumeCSI(
                in: value,
                after: value.index(after: introducer),
                foreground: &foreground,
                bold: &bold
            )
        case "]", "P", "_", "^", "X":
            return consumeControlString(in: value, after: value.index(after: introducer))
        default:
            return consumeEscapeFunction(in: value, at: introducer)
        }
    }

    private func consumeEscapeFunction(in value: String, at introducer: String.Index) -> String.Index {
        guard let scalar = value[introducer].unicodeScalars.first else {
            return value.index(after: introducer)
        }
        var cursor = value.index(after: introducer)

        // ESC functions may contain one or more 0x20–0x2F intermediate bytes
        // followed by one 0x30–0x7E final byte (for example ESC ( B). Consume
        // the whole unsupported function so its final never becomes a glyph.
        guard (0x20...0x2F).contains(scalar.value) else { return cursor }
        while cursor < value.endIndex {
            guard let candidate = value[cursor].unicodeScalars.first else {
                return value.index(after: cursor)
            }
            let next = value.index(after: cursor)
            if (0x30...0x7E).contains(candidate.value) { return next }
            guard (0x20...0x2F).contains(candidate.value) else { return next }
            cursor = next
        }
        return value.endIndex
    }

    private func consumeCSI(
        in value: String,
        after introducer: String.Index,
        foreground: inout CaseinTerminalForeground,
        bold: inout Bool
    ) -> String.Index {
        var cursor = introducer
        var parameters = ""

        while cursor < value.endIndex {
            let character = value[cursor]
            guard let scalar = character.unicodeScalars.first else { return value.index(after: cursor) }
            let next = value.index(after: cursor)

            if (0x40...0x7E).contains(scalar.value) {
                if character == "m" {
                    applySGR(parameters, foreground: &foreground, bold: &bold)
                }
                return next
            }

            if character.isNumber || character == ";" {
                parameters.append(character)
            }
            cursor = next
        }

        // A frame cut in the middle of a CSI is discarded through the bound.
        return value.endIndex
    }

    private func consumeControlString(in value: String, after introducer: String.Index) -> String.Index {
        var cursor = introducer
        while cursor < value.endIndex {
            let character = value[cursor]
            let next = value.index(after: cursor)

            if character == "\u{0007}" || character == "\u{009C}" {
                return next
            }

            if character == "\u{001B}", next < value.endIndex, value[next] == "\\" {
                return value.index(after: next)
            }
            cursor = next
        }

        // Unterminated strings are dropped through the bounded frame. Never
        // recover their payload as printable content.
        return value.endIndex
    }

    private func applySGR(
        _ raw: String,
        foreground: inout CaseinTerminalForeground,
        bold: inout Bool
    ) {
        let parameters = raw.isEmpty ? [0] : raw.split(separator: ";").compactMap { Int($0) }
        for parameter in parameters {
            switch parameter {
            case 0:
                foreground = .standard
                bold = false
            case 1: bold = true
            case 32: foreground = .green
            case 36: foreground = .cyan
            default: break
            }
        }
    }

    private static let c1StringIntroducers: Set<Character> = [
        "\u{0090}", // DCS
        "\u{0098}", // SOS
        "\u{009D}", // OSC
        "\u{009E}", // PM
        "\u{009F}"  // APC
    ]
}

private extension Character {
    var caseinIsTerminalControl: Bool {
        guard unicodeScalars.count == 1, let value = unicodeScalars.first?.value else { return false }
        return value <= 0x1F || (0x7F...0x9F).contains(value)
    }
}
