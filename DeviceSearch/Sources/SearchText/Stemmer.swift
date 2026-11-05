/// Light English plural stemmer (design doc §5, step 6). Applied identically to index and query tokens.
/// Brands and words that only look plural ("philips", "glass", "status") are protected.
public struct Stemmer: Sendable {
    public var protected: Set<String>

    public init(protected: Set<String> = Stemmer.defaultProtected) {
        self.protected = protected
    }

    public static let defaultProtected: Set<String> = [
        "philips", "sonos", "status", "gas", "glass", "always", "bus", "series", "asus", "lens", "christmas",
        "alexa", "ecovacs", "meross", "this", "his", "is", "was", "has", "its", "us", "plus", "yes", "xgimi",
    ]

    public func stem(_ token: String) -> String {
        let count = token.count
        guard count >= 3, !protected.contains(token), !token.contains(where: \.isNumber) else { return token }
        if count == 3 {
            // "acs", "tvs", "evs" → "ac", "tv", "ev"
            return ["acs", "tvs", "evs"].contains(token) ? String(token.dropLast()) : token
        }
        if token.hasSuffix("ies"), count > 4 { return String(token.dropLast(3)) + "y" }
        if token.hasSuffix("ss") || token.hasSuffix("us") || token.hasSuffix("is") { return token }
        if token.hasSuffix("ches") || token.hasSuffix("shes") || token.hasSuffix("xes") { return String(token.dropLast(2)) }
        if token.hasSuffix("s") { return String(token.dropLast()) }
        return token
    }
}
