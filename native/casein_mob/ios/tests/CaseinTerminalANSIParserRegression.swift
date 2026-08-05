import Foundation

@main
struct CaseinTerminalANSIParserRegression {
    static func main() {
        expect("\u{001B}]0;private title\u{0007}visible", renders: "visible")
        expect("\u{001B}]52;c;c2VjcmV0\u{001B}\\safe", renders: "safe")
        expect("prefix\u{001B}]52;c;unterminated", renders: "prefix")
        expect("\u{001B}7saved", renders: "saved")
        expect("\u{001B}(Bvisible", renders: "visible")
        expect("prefix\u{001B}(", renders: "prefix")
        expect("a\u{007F}\u{0085}b", renders: "ab")
        expect("\u{009D}0;c1 title\u{009C}done", renders: "done")
        expect("\u{001B}Pprivate DCS\u{001B}\\done", renders: "done")
        expect(
            Data([0x9D]) + Data("0;raw c1 title".utf8) + Data([0x9C]) + Data("done".utf8),
            renders: "done"
        )

        let oversized = Data(String(repeating: "x", count: 70_000).utf8)
        precondition(CaseinTerminalANSIParser().glyphs(for: oversized, columns: 80).count == 65_536)
    }

    private static func expect(_ input: String, renders expected: String) {
        expect(Data(input.utf8), renders: expected)
    }

    private static func expect(_ input: Data, renders expected: String) {
        let glyphs = CaseinTerminalANSIParser().glyphs(for: input, columns: 80)
        precondition(String(glyphs.map(\.character)) == expected)
    }
}
