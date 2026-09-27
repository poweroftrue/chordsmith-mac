import Foundation
import NaturalLanguage

// MARK: - Laptop shorthand
//
// A laptop keyboard can't press four or five letter keys at once reliably
// (MacBook keyboards ghost at three), and holding keys back to detect chords
// makes every keystroke lag. So on the laptop a chord becomes a shorthand:
// type the chord's letters in any order, then Space or punctuation, and the
// letters are replaced by the chord's output. Keys are never delayed; only
// the trigger key is consumed when a shorthand matches.

/// How a Master Forge chord was turned into something a laptop can type.
public enum ShorthandKind: String, Codable, Sendable {
    /// The chord's own letters, in any order.
    case sameKeys
    /// The chord uses the M4G's DUP key: its letters with one of them doubled.
    case doubledLetter
    /// The chord's keys don't exist on a laptop (or every order of them is a
    /// real word), so a short, unused abbreviation was picked instead.
    case newShortcut
    /// Letters you chose yourself.
    case custom
    /// Every order of the keys is a real word, so only pressing them
    /// together works.
    case pressTogether

    public var displayName: String {
        switch self {
        case .sameKeys: return "Same keys"
        case .doubledLetter: return "DUP → double letter"
        case .newShortcut: return "New shortcut"
        case .custom: return "Your shortcut"
        case .pressTogether: return "Press together only"
        }
    }
}

/// Why a chord has no laptop shorthand.
public enum ShorthandSkipReason: String, Codable, Sendable {
    /// The chord's keys spell the word itself, so just type it.
    case typeTheWord
    /// Typing the shorthand would take as many keys as the word.
    case noSavings
    /// A macro, shortcut or other non-text output.
    case notText
    /// Another shorthand already uses these letters.
    case conflict
    /// You turned it off.
    case disabled

    public var displayName: String {
        switch self {
        case .typeTheWord: return "Its keys spell the word, so just type it"
        case .noSavings: return "No keys saved"
        case .notText: return "Macro or shortcut, not text"
        case .conflict: return "Another shorthand uses these letters"
        case .disabled: return "Turned off"
        }
    }
}

public struct LaptopShorthand: Identifiable, Hashable, Sendable {
    public var id: UUID { chordID }
    public let chordID: UUID
    /// The text that replaces the letters, without a trailing space.
    public let output: String
    /// Lowercased output, for usage lookups.
    public let word: String
    /// The chord's keys on the Master Forge, for reference.
    public let chordKeys: [String]
    /// The suggested order to type, e.g. `abt` for about. Any order of the
    /// same letters works unless it spells a real word.
    public let letters: String
    public let kind: ShorthandKind
    /// Sorted letter multisets that trigger this shorthand.
    public let signatures: [String]
    /// The chord's own keys when they are all letters, for pressing them
    /// together. Set even when typing them in a row would spell a word.
    public let chordSignature: String?

    public init(
        chordID: UUID,
        output: String,
        chordKeys: [String],
        letters: String,
        kind: ShorthandKind,
        signatures: [String],
        chordSignature: String? = nil
    ) {
        self.chordID = chordID
        self.output = output
        self.word = output.lowercased()
        self.chordKeys = chordKeys
        self.letters = letters
        self.kind = kind
        self.signatures = signatures
        self.chordSignature = chordSignature
    }

    /// Keystrokes saved per use, counting the trigger key on both sides.
    public var savedKeystrokes: Int { max(output.count - letters.count, 0) }
}

public struct SkippedShorthand: Identifiable, Hashable, Sendable {
    public var id: UUID { chordID }
    public let chordID: UUID
    public let output: String
    public let chordKeys: [String]
    public let reason: ShorthandSkipReason

    public init(chordID: UUID, output: String, chordKeys: [String], reason: ShorthandSkipReason) {
        self.chordID = chordID
        self.output = output
        self.chordKeys = chordKeys
        self.reason = reason
    }
}

/// A shorthand you changed: custom letters, or turned off.
public struct ShorthandOverride: Hashable, Codable, Sendable {
    public let chordID: UUID
    public let letters: String?
    public let disabled: Bool

    public init(chordID: UUID, letters: String? = nil, disabled: Bool = false) {
        self.chordID = chordID
        self.letters = letters
        self.disabled = disabled
    }
}

public struct ShorthandCatalog: Sendable {
    public let shorthands: [LaptopShorthand]
    public let skipped: [SkippedShorthand]
    public let bySignature: [String: LaptopShorthand]
    /// Chords by their own keys, for pressing them together.
    public let byChordSignature: [String: LaptopShorthand]

    public static let empty = ShorthandCatalog(shorthands: [], skipped: [])

    public init(shorthands: [LaptopShorthand], skipped: [SkippedShorthand]) {
        self.shorthands = shorthands
        self.skipped = skipped
        var bySignature: [String: LaptopShorthand] = [:]
        for shorthand in shorthands {
            for signature in shorthand.signatures where bySignature[signature] == nil {
                bySignature[signature] = shorthand
            }
        }
        self.bySignature = bySignature
        var byChordSignature: [String: LaptopShorthand] = [:]
        for shorthand in shorthands {
            if let signature = shorthand.chordSignature, byChordSignature[signature] == nil {
                byChordSignature[signature] = shorthand
            }
        }
        self.byChordSignature = byChordSignature
    }

    /// Shorthands by lowercased output, keeping the shortest per word.
    public var byWord: [String: LaptopShorthand] {
        var result: [String: LaptopShorthand] = [:]
        for shorthand in shorthands where shorthand.kind != .pressTogether {
            if let existing = result[shorthand.word], existing.letters.count <= shorthand.letters.count { continue }
            result[shorthand.word] = shorthand
        }
        return result
    }
}

/// A shorthand match for a typed token, with the output cased like the token.
public struct ShorthandMatch: Equatable, Sendable {
    public let shorthand: LaptopShorthand
    public let text: String
}

// MARK: - Matching

/// Decides, for the letters just typed, whether they are a shorthand. Real
/// words always win: `how` stays `how` even though h+o+w is a chord.
public struct ShorthandMatcher: Sendable {
    public let catalog: ShorthandCatalog
    /// Dictionary words plus words you type often. Typed as-is, never replaced.
    let realWords: Set<String>
    /// Tokens you undid twice; never replaced again.
    let blocked: Set<String>
    /// Tokens you asked to always replace, even though they are words.
    let allowed: Set<String>

    public static let empty = ShorthandMatcher(catalog: .empty, realWords: [], blocked: [], allowed: [])

    public init(catalog: ShorthandCatalog, realWords: Set<String>, blocked: Set<String> = [], allowed: Set<String> = []) {
        self.catalog = catalog
        self.realWords = realWords
        self.blocked = blocked
        self.allowed = allowed
    }

    public var isEmpty: Bool { catalog.bySignature.isEmpty }

    public func match(_ token: String) -> ShorthandMatch? {
        let lower = token.lowercased()
        guard lower.count >= 2, lower.count <= 16,
              lower.allSatisfy(ShorthandLetters.isShorthandCharacter),
              lower.contains(where: \.isLetter) else { return nil }
        if !allowed.contains(lower) {
            guard !realWords.contains(lower), !blocked.contains(lower) else { return nil }
        }
        guard let shorthand = catalog.bySignature[ShorthandLetters.signature(lower)],
              lower != shorthand.word else { return nil }
        return ShorthandMatch(shorthand: shorthand, text: ShorthandLetters.applyCase(of: token, to: shorthand.output))
    }

    /// Keys pressed together. The press itself shows intent, so real words
    /// don't block it; the typer asks for a tighter press instead.
    public func matchChord(_ keys: String) -> ShorthandMatch? {
        let lower = keys.lowercased()
        let signature = ShorthandLetters.signature(lower)
        guard lower.count >= 2, lower.allSatisfy(ShorthandLetters.isShorthandCharacter),
              let shorthand = catalog.byChordSignature[signature] ?? catalog.bySignature[signature],
              lower != shorthand.word else { return nil }
        return ShorthandMatch(shorthand: shorthand, text: ShorthandLetters.applyCase(of: keys, to: shorthand.output))
    }

    /// Why a token would not be replaced, for the Laptop tab.
    public func isRealWord(_ token: String) -> Bool {
        let lower = token.lowercased()
        return realWords.contains(lower) && !allowed.contains(lower)
    }

    public func isBlocked(_ token: String) -> Bool {
        blocked.contains(token.lowercased())
    }
}

public enum ShorthandLetters {
    /// Letters, digits and the apostrophe make up a shorthand token.
    public static func isShorthandCharacter(_ character: Character) -> Bool {
        guard character.isASCII else { return false }
        return character.isLetter || character.isNumber || character == "'"
    }

    public static func signature<S: Sequence>(_ characters: S) -> String where S.Element == Character {
        String(characters.map { Character($0.lowercased()) }.sorted())
    }

    /// `Abt` gives `About`, `ABT` gives `ABOUT`, `abt` keeps the output as is.
    public static func applyCase(of token: String, to output: String) -> String {
        let letters = token.filter(\.isLetter)
        guard let first = letters.first else { return output }
        if letters.count >= 2, letters.allSatisfy(\.isUppercase) {
            return output.uppercased()
        }
        if first.isUppercase, let head = output.first {
            return head.uppercased() + output.dropFirst()
        }
        return output
    }

    /// The common English words among `candidates`, from Apple's built-in
    /// English vocabulary (about 57,000 everyday words). Unlike the system
    /// word list it leaves out rarities such as `wha` or `hwa`, so natural
    /// letter orders stay usable, yet it knows `rash`, `ink` and `mom`.
    public static func englishWords(among candidates: Set<String>) -> Set<String> {
        guard let embedding = NLEmbedding.wordEmbedding(for: .english) else { return [] }
        return candidates.filter { embedding.contains($0) }
    }

    /// Everyday words and abbreviations missing from the system dictionary
    /// that are meant literally. Chat shorthands such as `pls` or `bc` are
    /// deliberately absent: turning those into the full word is the point.
    public static let literalWords: Set<String> = [
        "hmm", "hmmm", "mm", "mmm", "mom", "moms", "dad", "dads", "mum", "cron", "crons", "jan", "feb", "mar", "apr",
        "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec", "mon", "tue", "tues", "wed", "thu", "thur", "thurs",
        "fri", "sat", "sun", "inc", "ltd", "llc", "corp", "exp", "que", "ytd", "mtd", "qtd", "ms", "mr", "mrs", "dr",
        "st", "ave", "rd", "jr", "sr", "comp", "lol", "lmao", "yeah", "yea", "yep", "yup", "nope", "nah", "okay",
        "gonna", "wanna", "gotta", "kinda", "sorta", "ugh", "uh", "um", "umm", "huh", "wow", "aww", "oops", "hey",
        "hi", "yo", "ya", "ye", "bro", "sis", "blog", "blogs", "email", "emails", "app", "apps", "wifi", "tv", "pc",
        "mac", "ipad", "iphone", "min", "mins", "sec", "secs", "hr", "hrs", "km", "kg", "mb", "gb", "tb", "kb",
        "am", "pm", "vs", "etc", "ok", "no", "on", "so", "to", "do", "go", "we", "he", "me", "be", "my", "by", "up",
        "us", "of", "or", "if", "in", "is", "it", "at", "as", "an", "a", "i", "the", "and", "for", "but", "not",
        "you", "all", "any", "can", "had", "her", "was", "one", "our", "out", "day", "get", "has", "him", "his",
        "how", "man", "new", "now", "old", "see", "two", "way", "who", "boy", "did", "its", "let", "put", "say",
        "she", "too", "use", "why", "yes", "yet", "ago", "add", "few", "got", "own", "try", "ask", "big", "end",
        "far", "run", "set", "top", "lot", "saw", "sad", "bad", "ten", "net", "ton", "art", "eat", "tea", "ate",
        "act", "cat", "tab", "bat", "rat", "tar", "car", "arc", "are", "ear", "era", "war", "raw", "saw", "was",
        "ant", "tan", "nat", "pat", "tap", "apt", "map", "pam", "ram", "arm", "mar", "rim", "dim", "mid", "god",
        "dog", "nod", "don", "den", "end", "ned", "ted", "red", "bed", "deb", "bud", "dub", "sub", "bus", "gum",
        "mug", "hug", "tug", "gut", "nut", "tun", "urn", "run", "sun", "nun", "fun", "fan", "fat", "hat", "that",
        "this", "then", "than", "them", "they", "there", "their", "here", "were", "what", "when", "with", "have",
        "from", "some", "will", "your", "each", "make", "like", "time", "just", "know", "take", "into", "year",
        "good", "most", "much", "made", "over", "such", "only", "also", "back", "well", "work", "life", "been",
        "call", "come", "does", "down", "even", "find", "give", "going", "hand", "help", "high", "keep", "last",
        "left", "long", "look", "many", "more", "must", "name", "need", "next", "open", "part", "said", "same",
        "seem", "show", "side", "tell", "turn", "very", "want", "ways", "went", "word", "sure", "stop", "team",
        "test", "read", "note", "post", "rate", "real", "rest", "role", "rule", "safe", "sale", "save", "seat",
        "send", "sent", "sort", "star", "stay", "step", "task", "text", "tool", "tops", "tree", "true", "type",
        "unit", "user", "data", "date", "deal", "done", "draw", "drop", "easy", "edge", "else", "fast", "file",
        "fine", "fire", "fish", "flat", "form", "free", "full", "game", "goal", "hard", "head", "hear", "hold",
        "home", "hope", "hour", "idea", "item", "join", "kind", "land", "late", "lead", "less", "line", "list",
        "live", "load", "lose", "loss", "love", "main", "mark", "mean", "meet", "mind", "miss", "move", "near",
        "news", "nice", "none", "okay", "once", "page", "paid", "pass", "past", "path", "pick", "plan", "play",
        "plus", "pull", "push", "race", "rank", "reach", "ready", "rise", "risk", "road", "rock", "room", "root",
        "shot", "sign", "site", "size", "skip", "slow", "soon", "spot", "talk", "tape", "term", "thus", "tire",
        "told", "took", "trip", "upon", "used", "view", "wait", "walk", "wall", "wear", "week", "wide", "wife",
        "wind", "wish", "wood", "yard", "zero", "zone", "cost", "code", "copy", "core", "hit", "hot", "oil",
        "sir", "sit", "six", "sky", "son", "tie", "tip", "toe", "win", "won", "yes", "age", "aid", "aim", "air",
        "bag", "bar", "bit", "box", "buy", "cup", "cut", "due", "dry", "egg", "eye", "fee", "fit", "fix", "fly",
        "gas", "gap", "hey", "ice", "ill", "job", "key", "kid", "law", "lay", "leg", "lie", "low", "mix", "odd",
        "off", "pay", "pen", "per", "pet", "pie", "pin", "pop", "pot", "raise", "row", "sea", "sex", "shy", "ski",
        "tax", "via", "web", "wet", "wit", "abs", "ads", "ids", "its", "lots", "odds", "sku", "skus", "vip",
        "vips", "po", "pos", "sup", "lass", "rpg", "px", "faq", "faqs", "hq", "rsvp", "diy", "tbd", "tba", "aka"
    ]

    /// Words that look like shorthands but are typed for real in shells,
    /// code and chat. Kept out even when missing from the dictionary.
    public static let commonTokens: Set<String> = [
        "ls", "cd", "rm", "mv", "cp", "ps", "df", "du", "vi", "vim", "nvim", "git", "npm", "npx", "pnpm", "yarn",
        "brew", "sudo", "ssh", "scp", "grep", "awk", "sed", "curl", "wget", "jq", "yq", "xargs", "pwd", "mkdir",
        "rmdir", "chmod", "chown", "ln", "tar", "zip", "unzip", "pkill", "htop", "ping", "echo", "printf", "env",
        "wc", "tr", "gcc", "clang", "make", "cmake", "go", "py", "js", "ts", "tsx", "jsx", "rb", "rs", "sh", "zsh",
        "bash", "md", "json", "yaml", "yml", "toml", "html", "css", "scss", "sql", "api", "apis", "url", "urls",
        "ui", "ux", "id", "ids", "db", "dbs", "ok", "pr", "prs", "pm", "am", "ios", "sdk", "cli", "gui", "dev",
        "prod", "stg", "qa", "uat", "ci", "k8s", "kubectl", "tf", "aws", "gcp", "dns", "ssl", "tls", "http", "https",
        "www", "com", "org", "net", "io", "ai", "llm", "llms", "gpt", "etc", "eg", "ie", "vs", "fyi", "asap", "btw",
        "lol", "omg", "tbh", "imo", "idk", "otp", "sms", "pdf", "csv", "xlsx", "png", "jpg", "jpeg", "gif", "svg",
        "mp3", "mp4", "utc", "gmt", "usd", "eur", "fn", "func", "var", "let", "def", "int", "str", "len", "nil",
        "null", "args", "kwargs", "init", "impl", "enum", "struct", "async", "await", "todo", "tmp", "src", "lib",
        "bin", "usr", "opt", "dir", "cmd", "ctrl", "alt", "esc", "tab", "src", "dist", "repo", "repos", "config",
        "okr", "kpi", "kpis", "eta", "pto", "ooo", "wfh", "dm", "dms", "cc", "bcc", "re", "fw", "fwd", "hr", "vp",
        "ceo", "cto", "cfo", "coo", "b2b", "b2c", "saas", "mvp", "poc", "rfc", "sla", "slo", "sso", "otp", "mfa"
    ]
}

// MARK: - Building

public enum ShorthandBuilder {
    /// Turns device chords into laptop shorthands.
    /// - Parameters:
    ///   - realWords: words that must never be replaced (dictionary, words
    ///     you type, `ShorthandLetters.commonTokens`).
    ///   - overrides: your own letters, or shorthands you turned off.
    public static func build(
        chords: [ChordEntry],
        realWords: Set<String>,
        overrides: [UUID: ShorthandOverride] = [:]
    ) -> ShorthandCatalog {
        struct Pending {
            let chord: ChordEntry
            let output: String
            var chordSignature: String?
        }

        var skipped: [SkippedShorthand] = []
        var usedSignatures: Set<String> = []
        var shorthands: [LaptopShorthand] = []
        var needsNewShortcut: [Pending] = []
        var customs: [(Pending, String)] = []
        var direct: [Pending] = []

        for chord in chords where chord.enabled {
            let keys = chord.inputKeys
            guard let output = textOutput(of: chord) else {
                skipped.append(SkippedShorthand(chordID: chord.id, output: chord.output, chordKeys: keys, reason: .notText))
                continue
            }
            let pending = Pending(chord: chord, output: output)
            if let override = overrides[chord.id] {
                if override.disabled {
                    skipped.append(SkippedShorthand(chordID: chord.id, output: output, chordKeys: keys, reason: .disabled))
                    continue
                }
                if let letters = override.letters.map(normalizedLetters), letters.count >= 2 {
                    customs.append((pending, letters))
                    continue
                }
            }
            direct.append(pending)
        }

        // Your own letters come first so they win any conflict.
        for (pending, letters) in customs {
            let signature = ShorthandLetters.signature(letters)
            guard !usedSignatures.contains(signature) else {
                skipped.append(SkippedShorthand(chordID: pending.chord.id, output: pending.output, chordKeys: pending.chord.inputKeys, reason: .conflict))
                continue
            }
            usedSignatures.insert(signature)
            shorthands.append(LaptopShorthand(
                chordID: pending.chord.id,
                output: pending.output,
                chordKeys: pending.chord.inputKeys,
                letters: letters,
                kind: .custom,
                signatures: [signature],
                chordSignature: chordKeySignature(pending.chord)
            ))
        }

        for pending in direct {
            let keys = pending.chord.inputKeys.map { $0.lowercased() }
            let word = pending.output.lowercased()
            let letterKeys = keys.filter { $0.count == 1 && $0.allSatisfy(ShorthandLetters.isShorthandCharacter) }
            let hasDup = keys.contains("dup")
            let otherKeys = keys.count - letterKeys.count - (hasDup ? 1 : 0)
            guard otherKeys == 0, !letterKeys.isEmpty, !(hasDup && letterKeys.count < 1) else {
                needsNewShortcut.append(pending)
                continue
            }
            let base = letterKeys.map { Character($0) }

            // Each variant is one way to type the chord: its letters, or with
            // DUP, its letters with one of them doubled.
            let variants: [[Character]] = hasDup ? base.map { base + [$0] } : [base]
            let signatures = variants.map { ShorthandLetters.signature($0) }
            if signatures.contains(ShorthandLetters.signature(word)) {
                skipped.append(SkippedShorthand(chordID: pending.chord.id, output: pending.output, chordKeys: pending.chord.inputKeys, reason: .typeTheWord))
                continue
            }
            guard variants[0].count < pending.output.count else {
                skipped.append(SkippedShorthand(chordID: pending.chord.id, output: pending.output, chordKeys: pending.chord.inputKeys, reason: .noSavings))
                continue
            }
            let free = signatures.filter { !usedSignatures.contains($0) }
            guard !free.isEmpty else {
                skipped.append(SkippedShorthand(chordID: pending.chord.id, output: pending.output, chordKeys: pending.chord.inputKeys, reason: .conflict))
                continue
            }
            let ordered: String?
            if hasDup {
                ordered = doubledOrder(base: base, word: word, realWords: realWords)
            } else {
                ordered = typingOrder(base, word: word, realWords: realWords)
            }
            guard let letters = ordered else {
                // Every order spells a real word: pick new letters to type,
                // while pressing the keys together still works.
                var blocked = pending
                blocked.chordSignature = hasDup ? nil : signatures[0]
                needsNewShortcut.append(blocked)
                continue
            }
            usedSignatures.formUnion(free)
            shorthands.append(LaptopShorthand(
                chordID: pending.chord.id,
                output: pending.output,
                chordKeys: pending.chord.inputKeys,
                letters: letters,
                kind: hasDup ? .doubledLetter : .sameKeys,
                signatures: free,
                chordSignature: hasDup ? nil : signatures[0]
            ))
        }

        // Words that already have a shorthand don't need a second, invented one.
        let coveredWords = Set(shorthands.map(\.word))
        for pending in needsNewShortcut.sorted(by: { $0.output.count < $1.output.count }) {
            let word = pending.output.lowercased()
            if coveredWords.contains(word) {
                if let chordSignature = pending.chordSignature {
                    shorthands.append(pressTogether(pending.chord, output: pending.output, signature: chordSignature))
                }
                continue
            }
            guard let letters = newShortcut(for: word, realWords: realWords, used: usedSignatures) else {
                if let chordSignature = pending.chordSignature {
                    // Nothing new to type, but the keys can still be pressed together.
                    shorthands.append(pressTogether(pending.chord, output: pending.output, signature: chordSignature))
                } else {
                    skipped.append(SkippedShorthand(chordID: pending.chord.id, output: pending.output, chordKeys: pending.chord.inputKeys, reason: .noSavings))
                }
                continue
            }
            let signature = ShorthandLetters.signature(letters)
            usedSignatures.insert(signature)
            shorthands.append(LaptopShorthand(
                chordID: pending.chord.id,
                output: pending.output,
                chordKeys: pending.chord.inputKeys,
                letters: letters,
                kind: .newShortcut,
                signatures: [signature],
                chordSignature: pending.chordSignature
            ))
        }

        return ShorthandCatalog(shorthands: shorthands, skipped: skipped)
    }

    static func pressTogether(_ chord: ChordEntry, output: String, signature: String) -> LaptopShorthand {
        LaptopShorthand(
            chordID: chord.id, output: output, chordKeys: chord.inputKeys,
            letters: wordOrder(Array(signature), word: output.lowercased()).map(String.init).joined(),
            kind: .pressTogether, signatures: [], chordSignature: signature
        )
    }

    /// The chord's keys as a signature when every key is a laptop letter.
    static func chordKeySignature(_ chord: ChordEntry) -> String? {
        let keys = chord.inputKeys.map { $0.lowercased() }
        guard keys.count >= 2, keys.allSatisfy({ $0.count == 1 && $0.allSatisfy(ShorthandLetters.isShorthandCharacter) }) else { return nil }
        return ShorthandLetters.signature(keys.joined())
    }

    /// The chord's output as plain text, or nil for macros and key actions.
    static func textOutput(of chord: ChordEntry) -> String? {
        guard chord.actionFlags.isEmpty else { return nil }
        let raw = chord.plainOutput ?? chord.output
        guard !raw.contains("<"), !raw.contains("\n"), !raw.contains("\t") else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.contains(where: \.isLetter) else { return nil }
        return trimmed
    }

    static func normalizedLetters(_ letters: String) -> String {
        String(letters.lowercased().filter(ShorthandLetters.isShorthandCharacter))
    }

    /// The letters in the order they appear in the word (`abt` for about),
    /// or the nearest order that isn't itself a real word.
    static func typingOrder(_ letters: [Character], word: String, realWords: Set<String>) -> String? {
        let start = wordOrder(letters, word: word)
        if !realWords.contains(String(start)) { return String(start) }
        guard start.count <= 6 else { return nil }
        for permutation in permutations(start) {
            let candidate = String(permutation)
            if !realWords.contains(candidate), candidate != word { return candidate }
        }
        return nil
    }

    /// For DUP chords: the word-order letters with the last one doubled,
    /// falling back to doubling another letter.
    static func doubledOrder(base: [Character], word: String, realWords: Set<String>) -> String? {
        let ordered = wordOrder(base, word: word)
        for index in ordered.indices.reversed() {
            var letters = ordered
            letters.insert(ordered[index], at: index)
            let candidate = String(letters)
            if !realWords.contains(candidate), candidate != word { return candidate }
        }
        return nil
    }

    static func wordOrder(_ letters: [Character], word: String) -> [Character] {
        var remaining = letters
        var ordered: [Character] = []
        for character in word {
            if let index = remaining.firstIndex(of: character) {
                ordered.append(remaining.remove(at: index))
            }
        }
        return ordered + remaining
    }

    /// Permutations in an order that keeps the leading letters longest.
    static func permutations(_ letters: [Character]) -> [[Character]] {
        guard letters.count > 1 else { return [letters] }
        var result: [[Character]] = []
        for (index, letter) in letters.enumerated() {
            var rest = letters
            rest.remove(at: index)
            for tail in permutations(rest) {
                result.append([letter] + tail)
            }
        }
        return result
    }

    /// Every token the builder might suggest or you might type for these
    /// chords, so only those need a real-word check.
    public static func candidateTokens(for chords: [ChordEntry]) -> Set<String> {
        var tokens: Set<String> = []
        for chord in chords where chord.enabled {
            guard let output = textOutput(of: chord) else { continue }
            let keys = chord.inputKeys.map { $0.lowercased() }
            let letters = keys.filter { $0.count == 1 && $0.allSatisfy(ShorthandLetters.isShorthandCharacter) }.map { Character($0) }
            var variants: [[Character]] = [letters]
            if keys.contains("dup") { variants = letters.map { letters + [$0] } }
            for variant in variants where variant.count >= 2 && variant.count <= 6 {
                for permutation in permutations(variant) { tokens.insert(String(permutation)) }
            }
            tokens.formUnion(newShortcutCandidates(for: output.lowercased()))
        }
        return tokens
    }

    static func newShortcutCandidates(for word: String) -> [String] {
        let letters = Array(word.filter { $0.isASCII && $0.isLetter })
        guard letters.count >= 4, let first = letters.first else { return [] }
        let vowels: Set<Character> = ["a", "e", "i", "o", "u"]
        var skeleton: [Character] = [first]
        for character in letters.dropFirst() where !vowels.contains(character) && character != skeleton.last {
            skeleton.append(character)
        }
        var candidates: [String] = []
        for length in [3, 4, 2] where skeleton.count >= length {
            candidates.append(String(skeleton.prefix(length)))
        }
        for length in [3, 4] where letters.count > length {
            candidates.append(String(letters.prefix(length)))
        }
        if skeleton.count >= 2, let last = skeleton.last {
            candidates.append(String([first, skeleton[1], last]))
        }
        return candidates
    }

    /// A short, unused abbreviation that saves at least two keys: the word's
    /// first letter and following consonants (`elv` for eleven), then
    /// plain prefixes.
    static func newShortcut(for word: String, realWords: Set<String>, used: Set<String>) -> String? {
        let letters = Array(word.filter { $0.isASCII && $0.isLetter })
        for candidate in newShortcutCandidates(for: word) {
            guard candidate.count >= 2, candidate.count <= letters.count - 2,
                  !realWords.contains(candidate) else { continue }
            let signature = ShorthandLetters.signature(candidate)
            if !used.contains(signature), signature != ShorthandLetters.signature(word) {
                return candidate
            }
        }
        return nil
    }
}
