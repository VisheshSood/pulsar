import Foundation

/// International Morse code → a timeline of (on, units) segments.
/// Standard timing: dot 1, dash 3, gap inside a letter 1, between letters 3, between words 7.
enum Morse {
    static let table: [Character: String] = [
        "A": ".-", "B": "-...", "C": "-.-.", "D": "-..", "E": ".", "F": "..-.", "G": "--.", "H": "....",
        "I": "..", "J": ".---", "K": "-.-", "L": ".-..", "M": "--", "N": "-.", "O": "---", "P": ".--.",
        "Q": "--.-", "R": ".-.", "S": "...", "T": "-", "U": "..-", "V": "...-", "W": ".--", "X": "-..-",
        "Y": "-.--", "Z": "--..",
        "0": "-----", "1": ".----", "2": "..---", "3": "...--", "4": "....-", "5": ".....",
        "6": "-....", "7": "--...", "8": "---..", "9": "----.",
        ".": ".-.-.-", ",": "--..--", "?": "..--..", "!": "-.-.--", "/": "-..-.", "@": ".--.-.",
        "&": ".-...", ":": "---...", "=": "-...-", "+": ".-.-.", "-": "-....-", "'": ".----.", "\"": ".-..-.",
    ]

    struct Segment { var on: Bool; var units: Int }

    static func segments(for text: String) -> [Segment] {
        var out: [Segment] = []
        func gap(_ u: Int) {
            if let last = out.last, !last.on { out[out.count - 1].units = max(last.units, u) }
            else if !out.isEmpty { out.append(Segment(on: false, units: u)) }
        }
        for word in text.uppercased().split(whereSeparator: \.isWhitespace) {
            gap(7)
            for ch in word {
                guard let code = table[ch] else { continue }
                gap(3)
                for (i, s) in code.enumerated() {
                    if i > 0 { gap(1) }
                    out.append(Segment(on: true, units: s == "." ? 1 : 3))
                }
            }
        }
        return out
    }

    /// Readable dots and dashes for the UI, e.g. "... --- ...".
    static func preview(_ text: String) -> String {
        text.uppercased().split(whereSeparator: \.isWhitespace)
            .map { $0.compactMap { table[$0] }.joined(separator: " ") }
            .joined(separator: "  /  ")
    }
}
