/// Key positions on a QWERTY phone keyboard, used to make neighbouring-key substitutions cheap.
public enum KeyboardLayout {
    /// Row offsets mimic the stagger of a real keyboard.
    static let positions: [Character: (x: Double, y: Double)] = {
        let rows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
        let offsets = [0.0, 0.3, 0.8]
        var map: [Character: (x: Double, y: Double)] = [:]
        for (row, letters) in rows.enumerated() {
            for (column, letter) in letters.enumerated() {
                map[letter] = (Double(column) + offsets[row], Double(row))
            }
        }
        return map
    }()

    /// True when two different letters are adjacent on the keyboard (distance below 1.5 key widths).
    public static func areNeighbours(_ a: Character, _ b: Character) -> Bool {
        guard a != b, let p = positions[a], let q = positions[b] else { return false }
        let dx = p.x - q.x
        let dy = p.y - q.y
        return (dx * dx + dy * dy).squareRoot() < 1.5
    }
}

/// Weighted optimal-string-alignment distance tuned for thumb typing (design doc §5):
/// - neighbouring-key substitution 0.5, any other substitution 1
/// - swapping two adjacent letters 0.7
/// - adding or dropping a doubled letter 0.5, any other insertion or deletion 1
public enum TypingDistance {
    public static let neighbourCost = 0.5
    public static let swapCost = 0.7
    public static let doubledLetterCost = 0.5

    /// Distance from `typed` to `term`, or `.infinity` as soon as the result cannot fit `limit`.
    public static func distance(_ typed: String, _ term: String, limit: Double = .infinity) -> Double {
        distance(Array(typed), Array(term), limit: limit)
    }

    public static func distance(_ a: [Character], _ b: [Character], limit: Double = .infinity) -> Double {
        let n = a.count
        let m = b.count
        if n == 0 || m == 0 { return Double(max(n, m)) }
        // Every length difference costs at least one doubled-letter edit.
        if Double(abs(n - m)) * doubledLetterCost > limit { return .infinity }

        var d = Array(repeating: Array(repeating: 0.0, count: m + 1), count: n + 1)
        for i in 0...n { d[i][0] = Double(i) }
        for j in 0...m { d[0][j] = Double(j) }

        var previousRowMin = 0.0
        for i in 1...n {
            var rowMin = Double.infinity
            for j in 1...m {
                let x = a[i - 1]
                let y = b[j - 1]
                let substitution = x == y ? 0 : (KeyboardLayout.areNeighbours(x, y) ? neighbourCost : 1)
                let deletion = i > 1 && a[i - 2] == x ? doubledLetterCost : 1
                let insertion = j > 1 && b[j - 2] == y ? doubledLetterCost : 1
                var value = min(d[i - 1][j] + deletion, d[i][j - 1] + insertion, d[i - 1][j - 1] + substitution)
                if i > 1, j > 1, x != y, x == b[j - 2], a[i - 2] == y {
                    value = min(value, d[i - 2][j - 2] + swapCost)
                }
                d[i][j] = value
                rowMin = min(rowMin, value)
            }
            // Later rows cost at least the smaller of this row and the previous row plus a swap.
            if min(rowMin, previousRowMin + swapCost) > limit { return .infinity }
            previousRowMin = rowMin
        }
        return d[n][m]
    }

    /// Correction confidence for a cost: 1 - weight × cost, rounded to two decimals (design doc §5).
    public static func confidence(forCost cost: Double, weight: Double = 0.3) -> Double {
        ((1 - weight * cost) * 100).rounded() / 100
    }
}
