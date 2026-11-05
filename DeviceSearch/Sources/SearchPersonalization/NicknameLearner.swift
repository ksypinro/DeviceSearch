/// Learned nicknames (design doc §15, U06; decision D09).
///
/// When the same device is picked three times for the same query and no lexical evidence connected them
/// (no exact, prefix, keyword, trigram, phonetic or facet match), the query becomes an alias of the device,
/// indexed like a name at 0.8 of the name weight. Nicknames come only from the person's own picks — never
/// from the model — are listed in Settings and can be removed; a removed nickname is never learned again.
public struct NicknameLearner: Sendable {
    public let threshold: Int

    public init(threshold: Int = 3) {
        self.threshold = threshold
    }

    /// Short, wordy or numeric queries make poor nicknames.
    public func isCandidate(_ key: String) -> Bool {
        let words = key.split(separator: " ")
        return key.count >= 3 && key.count <= 40 && (1...4).contains(words.count)
            && !key.allSatisfy { $0.isNumber || $0 == " " }
    }

    /// Adds a vote; returns true when this vote learns the nickname.
    public func vote(_ key: String, device: String, in state: inout PersonalizationState) -> Bool {
        guard isCandidate(key) else { return false }
        let votes = (state.nicknameVotes[key]?[device] ?? 0) + 1
        state.nicknameVotes[key, default: [:]][device] = votes
        guard votes >= threshold,
              !state.removedNicknames.contains(Self.pair(device, key)),
              !(state.nicknames[device] ?? []).contains(key) else { return false }
        state.nicknames[device, default: []].append(key)
        return true
    }

    public static func pair(_ device: String, _ nickname: String) -> String { device + "|" + nickname }
}
