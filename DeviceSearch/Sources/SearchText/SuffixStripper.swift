/// Strips inflection suffixes at the Unicode-scalar level (decision D16).
/// Callers accept a stripped form only when it is a known vocabulary word, so stripping can never invent a match.
///
/// Example: "বেডরুমের" (bedroom's) ends with the scalars "ে" + "র"; stripping gives "বেডরুম".
/// `String.hasSuffix` cannot do this because "মে" is one grapheme cluster.
public struct SuffixStripper: Sendable {
    /// Suffixes, longest first.
    public let suffixes: [[Unicode.Scalar]]
    /// Minimum number of scalars left after stripping.
    public let minimumStemLength: Int

    public init(suffixes: [String], minimumStemLength: Int = 2) {
        self.suffixes = suffixes
            .map { Array($0.unicodeScalars) }
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
        self.minimumStemLength = minimumStemLength
    }

    /// Every stripped form of `token`, longest suffix first.
    public func candidates(for token: String) -> [String] {
        let scalars = Array(token.unicodeScalars)
        var results: [String] = []
        for suffix in suffixes where scalars.count - suffix.count >= minimumStemLength {
            if Array(scalars.suffix(suffix.count)) == suffix {
                var view = String.UnicodeScalarView()
                view.append(contentsOf: scalars.prefix(scalars.count - suffix.count))
                let stem = String(view)
                if !results.contains(stem) { results.append(stem) }
            }
        }
        return results
    }
}
