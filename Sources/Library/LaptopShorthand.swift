import Foundation
import NaturalLanguage

// MARK: - Laptop shorthand
//
// A laptop keyboard can't press four or five letter keys at once reliably
// (MacBook keyboards ghost at three), and holding keys back to detect chords
// makes every keystroke lag. So on the laptop a chord becomes a shorthand:
// type three letters, then Space or punctuation, and they are replaced by the
// chord's output (`wrt` → write). Short words keep only the press-together
// chord. Keys are never delayed; only the trigger key is consumed when a
// shorthand matches.

/// How a Master Forge chord was turned into something a laptop can type.
public enum ShorthandKind: String, Codable, Sendable {
    /// Three of the word's letters that happen to be the chord's own keys.
    case sameKeys
    /// Kept so saved values still decode; no longer produced.
    case doubledLetter
    /// Three of the word's letters, picked to be quick to type.
    case newShortcut
    /// Letters you chose yourself.
    case custom
    /// A short word: typing three letters wouldn't save anything, so only
    /// pressing the keys together works.
    case pressTogether

    public var displayName: String {
        switch self {
        case .sameKeys: return "Chord's keys"
        case .doubledLetter: return "DUP → double letter"
        case .newShortcut: return "Word's letters"
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
    /// Every quick set of letters is taken or spells a word.
    case conflict
    /// You turned it off.
    case disabled
    /// Its keys can't be pressed together on a laptop and nothing
    /// comfortable was free.
    case awkwardOnLaptop
    /// Three letters or fewer: as quick to type as to press.
    case shortWord

    public var displayName: String {
        switch self {
        case .typeTheWord: return "Its keys spell the word, so just type it"
        case .noSavings: return "No keys saved"
        case .notText: return "Macro or shortcut, not text"
        case .conflict: return "Every quick set of letters is taken"
        case .disabled: return "Turned off"
        case .awkwardOnLaptop: return "No three keys are safe to press together"
        case .shortWord: return "Short enough to just type"
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
    /// The letters to type, in this order: `wrt` for write.
    public let letters: String
    public let kind: ShorthandKind
    /// Typed tokens that trigger this shorthand, lowercased.
    public let tokens: [String]
    /// The keys to press together on the laptop, in word order: the
    /// chord's own keys, or comfortable ones when those share a finger.
    public let pressKeys: String?
    /// Whether `pressKeys` differ from the chord's keys.
    public let pressAdjusted: Bool
    /// Signature of `pressKeys`, for matching a press.
    public var chordSignature: String? { pressKeys.map { ShorthandLetters.signature($0) } }

    public init(
        chordID: UUID,
        output: String,
        chordKeys: [String],
        letters: String,
        kind: ShorthandKind,
        tokens: [String],
        chordSignature: String? = nil,
        pressKeys: String? = nil,
        pressAdjusted: Bool = false
    ) {
        self.chordID = chordID
        self.output = output
        self.word = output.lowercased()
        self.chordKeys = chordKeys
        self.letters = letters
        self.kind = kind
        self.tokens = tokens
        self.pressKeys = pressKeys ?? chordSignature.map {
            ShorthandBuilder.wordOrder(Array($0), word: output.lowercased()).map(String.init).joined()
        }
        self.pressAdjusted = pressAdjusted
    }

    func withPressKeys(_ keys: String?, adjusted: Bool) -> LaptopShorthand {
        LaptopShorthand(
            chordID: chordID, output: output, chordKeys: chordKeys, letters: letters, kind: kind,
            tokens: tokens, pressKeys: keys, pressAdjusted: adjusted
        )
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
    public let byToken: [String: LaptopShorthand]
    /// Chords by their own keys, for pressing them together.
    public let byChordSignature: [String: LaptopShorthand]

    public static let empty = ShorthandCatalog(shorthands: [], skipped: [])

    public init(shorthands: [LaptopShorthand], skipped: [SkippedShorthand]) {
        self.shorthands = shorthands
        self.skipped = skipped
        var byToken: [String: LaptopShorthand] = [:]
        for shorthand in shorthands {
            for token in shorthand.tokens where byToken[token] == nil {
                byToken[token] = shorthand
            }
        }
        self.byToken = byToken
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

    public var isEmpty: Bool { catalog.byToken.isEmpty && catalog.byChordSignature.isEmpty }

    public func match(_ token: String) -> ShorthandMatch? {
        let lower = token.lowercased()
        guard lower.count >= 2, lower.count <= 16,
              lower.allSatisfy(ShorthandLetters.isShorthandCharacter),
              lower.contains(where: \.isLetter) else { return nil }
        if !allowed.contains(lower) {
            guard !realWords.contains(lower), !blocked.contains(lower) else { return nil }
        }
        guard let shorthand = catalog.byToken[lower],
              lower != shorthand.word else { return nil }
        return ShorthandMatch(shorthand: shorthand, text: ShorthandLetters.applyCase(of: token, to: shorthand.output))
    }

    /// Keys pressed together. The press itself shows intent, so real words
    /// don't block it; the typer asks for a tighter press instead.
    public func matchChord(_ keys: String) -> ShorthandMatch? {
        let lower = keys.lowercased()
        let signature = ShorthandLetters.signature(lower)
        guard lower.count == ShorthandBuilder.pressKeyCount, lower.allSatisfy(ShorthandLetters.isShorthandCharacter),
              let shorthand = catalog.byChordSignature[signature],
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
    /// A typed shorthand must save at least this many keystrokes; below
    /// that, the word itself is as quick and needs no thought.
    static let minimumSavings = 2

    /// Turns device chords into laptop shorthands.
    /// - Parameters:
    ///   - realWords: words that must never be replaced (dictionary, words
    ///     you type, `ShorthandLetters.commonTokens`).
    ///   - overrides: your own letters, or shorthands you turned off.
    ///   - usage: how often you write each word; frequent words pick first.
    public static func build(
        chords: [ChordEntry],
        realWords: Set<String>,
        overrides: [UUID: ShorthandOverride] = [:],
        usage: [String: Int] = [:]
    ) -> ShorthandCatalog {
        var skipped: [SkippedShorthand] = []
        var used: Set<String> = []
        var shorthands: [LaptopShorthand] = []
        var customs: [(ChordEntry, String, String)] = []
        var byWord: [String: [(chord: ChordEntry, output: String)]] = [:]
        var wordOrderSeen: [String] = []

        for chord in chords where chord.enabled {
            let keys = chord.inputKeys
            guard let output = textOutput(of: chord) else {
                skipped.append(SkippedShorthand(chordID: chord.id, output: chord.output, chordKeys: keys, reason: .notText))
                continue
            }
            if let override = overrides[chord.id] {
                if override.disabled {
                    skipped.append(SkippedShorthand(chordID: chord.id, output: output, chordKeys: keys, reason: .disabled))
                    continue
                }
                if let letters = override.letters.map(normalizedLetters), letters.count >= 2 {
                    customs.append((chord, output, letters))
                    continue
                }
            }
            let word = output.lowercased()
            if byWord[word] == nil { wordOrderSeen.append(word) }
            byWord[word, default: []].append((chord, output))
        }

        // Your own letters come first so they win any conflict.
        var customWords: Set<String> = []
        for (chord, output, letters) in customs {
            guard !used.contains(letters) else {
                skipped.append(SkippedShorthand(chordID: chord.id, output: output, chordKeys: chord.inputKeys, reason: .conflict))
                continue
            }
            used.insert(letters)
            customWords.insert(output.lowercased())
            shorthands.append(LaptopShorthand(
                chordID: chord.id, output: output, chordKeys: chord.inputKeys, letters: letters,
                kind: .custom, tokens: [letters], chordSignature: chordKeySignature(chord)
            ))
        }

        // Words you write most pick their letters first.
        let words = wordOrderSeen.enumerated().sorted { lhs, rhs in
            let left = usage[lhs.element] ?? 0, right = usage[rhs.element] ?? 0
            if left != right { return left > right }
            return lhs.offset < rhs.offset
        }.map(\.element)

        for word in words {
            let entries = byWord[word] ?? []
            // Chords whose keys just spell the word add nothing.
            let useful = entries.filter { entry in
                let keys = entry.chord.inputKeys.map { $0.lowercased() }
                return !(keys.allSatisfy { $0.count == 1 } && ShorthandLetters.signature(keys.joined()) == ShorthandLetters.signature(word))
            }
            for entry in entries where !useful.contains(where: { $0.chord.id == entry.chord.id }) {
                skipped.append(SkippedShorthand(chordID: entry.chord.id, output: entry.output, chordKeys: entry.chord.inputKeys, reason: .typeTheWord))
            }
            guard let first = useful.first else { continue }

            var typedChordID: UUID?
            if !customWords.contains(word),
               let code = typedCode(for: word, chords: useful.map(\.chord), realWords: realWords, used: used) {
                used.insert(code.letters)
                let owner = useful.first { $0.chord.id == code.chordID } ?? first
                typedChordID = owner.chord.id
                shorthands.append(LaptopShorthand(
                    chordID: owner.chord.id, output: owner.output, chordKeys: owner.chord.inputKeys, letters: code.letters,
                    kind: code.fromChord ? .sameKeys : .newShortcut, tokens: [code.letters],
                    chordSignature: chordKeySignature(owner.chord)
                ))
            }
            // Every other chord for the word is pressed together. Keys that
            // don't exist on a laptop get comfortable ones, once per word.
            let typed = typedChordID != nil || customWords.contains(word)
            if !typed, word.filter({ $0.isASCII && $0.isLetter }).count < minimumPressWordLength {
                for entry in useful {
                    skipped.append(SkippedShorthand(chordID: entry.chord.id, output: entry.output, chordKeys: entry.chord.inputKeys, reason: .shortWord))
                }
                continue
            }
            for (offset, entry) in useful.enumerated() where entry.chord.id != typedChordID {
                let signature = chordKeySignature(entry.chord)
                if signature == nil && (typed || offset > 0) { continue }
                shorthands.append(pressTogether(entry.chord, output: entry.output, signature: signature))
            }
        }

        let (pressable, awkward) = assignPressKeys(shorthands, realWords: realWords, usage: usage)
        skipped += awkward.map {
            SkippedShorthand(chordID: $0.chordID, output: $0.output, chordKeys: $0.chordKeys, reason: .awkwardOnLaptop)
        }
        return ShorthandCatalog(shorthands: pressable, skipped: skipped)
    }

    static func savesEnough(word: String) -> Bool {
        word.count - 3 >= minimumSavings && word.filter { $0.isASCII && $0.isLetter }.count >= 3
    }

    /// The letters to type for `word`: three of its letters in order,
    /// starting with the first (`wrt` for write), that read like the word
    /// and roll off the fingers. Four only when every three is taken.
    static func typedCode(
        for word: String,
        chords: [ChordEntry],
        realWords: Set<String>,
        used: Set<String>
    ) -> (letters: String, chordID: UUID?, fromChord: Bool)? {
        guard savesEnough(word: word) else { return nil }
        let letters = Array(word.filter { $0.isASCII && $0.isLetter })
        // The chord's own letters in word order, when they are three or four
        // of the word's letters: already familiar.
        var chordCodes: [String: UUID] = [:]
        for chord in chords {
            let keys = chord.inputKeys.map { $0.lowercased() }
            guard keys.allSatisfy({ $0.count == 1 && $0.first!.isLetter }) else { continue }
            let ordered = String(wordOrder(keys.map { Character($0) }, word: String(letters)))
            if chordCodes[ordered] == nil { chordCodes[ordered] = chord.id }
        }
        let wordLetters = String(letters)
        for size in [3, 4] {
            guard word.count - size >= minimumSavings, size < letters.count else { break }
            var best: (score: Double, code: String)?
            for code in codeCandidates(letters, size: size) {
                guard !used.contains(code.letters), !realWords.contains(code.letters), code.letters != wordLetters,
                      let typing = LaptopErgonomics.typingCost(code.letters) else { continue }
                // Letters you can't recall are slow however well they roll,
                // so reading like the word comes first.
                var score = code.readability * 2 + typing * 0.6
                if chordCodes[code.letters] != nil { score -= 0.8 }
                if best == nil || score < best!.score { best = (score, code.letters) }
            }
            if let best {
                let chordID = chordCodes[best.code]
                return (best.code, chordID ?? chords.first?.id, chordID != nil)
            }
        }
        return nil
    }

    /// Every way to pick `size` of the word's letters in order, starting
    /// with the first, and how far each strays from how you'd abbreviate it
    /// by ear: the first letter, then the consonants you hear, optionally
    /// ending on the last one (`wrt`, `pls`, `smt`).
    static func codeCandidates(_ letters: [Character], size: Int) -> [(letters: String, readability: Double)] {
        guard letters.count > size, size >= 2 else { return [] }
        let vowels: Set<Character> = ["a", "e", "i", "o", "u"]
        // Rank of each consonant you'd hear, skipping vowels and the second
        // of a doubled letter.
        var rank: [Int: Int] = [:]
        var next = 1
        for index in letters.indices.dropFirst() where !vowels.contains(letters[index]) && letters[index] != letters[index - 1] {
            rank[index] = next
            next += 1
        }
        let lastConsonant = rank.max { $0.value < $1.value }?.key

        var results: [(String, Double)] = []
        var chosen = [0]
        func recurse(_ start: Int) {
            if chosen.count == size {
                var penalty = 0.0
                var previousRank = 0
                for (slot, index) in chosen.enumerated().dropFirst() {
                    guard let current = rank[index] else {
                        penalty += vowels.contains(letters[index]) ? 1.2 : 0.8
                        continue
                    }
                    let skipped = Double(max(current - previousRank - 1, 0))
                    // Ending on the word's last consonant is a natural anchor.
                    let isAnchor = index == lastConsonant && slot == size - 1
                    penalty += skipped * (isAnchor ? 0.15 : 0.45)
                    previousRank = current
                }
                // The word's start reads fine even with a vowel (`rev`).
                if chosen == Array(0..<size) { penalty *= 0.6 }
                let code = String(chosen.map { letters[$0] })
                if chosen.map({ letters[$0] }).count != Set(chosen.map { letters[$0] }).count { penalty += 0.6 }
                results.append((code, penalty))
                return
            }
            guard start < letters.count else { return }
            for index in start..<letters.count where letters.count - index >= size - chosen.count {
                chosen.append(index)
                recurse(index + 1)
                chosen.removeLast()
            }
        }
        recurse(1)
        // The same letters can come from different positions; keep the best.
        var best: [String: Double] = [:]
        for (code, penalty) in results where best[code].map({ penalty < $0 }) ?? true {
            best[code] = penalty
        }
        return best.map { ($0.key, $0.value) }.sorted { $0.0 < $1.0 }
    }

    /// Keys pressed together on a laptop are exactly three, never two:
    /// typing fast, the first two or three letters of a word overlap, and
    /// a two-key chord like `s+h` fires when you meant `should`.
    public static let pressKeyCount = 3
    /// One- and two-letter words are as quick to type as to press.
    static let minimumPressWordLength = 3
    /// When no three of a word's own letters are safe, one of these joins
    /// two of them, like `/` on the Forge: hardly any word starts with it,
    /// and it sits on the right index or middle finger at home.
    static let markerKeys: [Character: Double] = ["j": 1.0, "k": 1.3]

    /// Gives words keys to press together: three keys on three fingers,
    /// chosen so typing never sets them off. No word you write may start
    /// with the same three letters in any order (at speed those overlap),
    /// and no other word's typed letters may use them either. Keys come
    /// from the word, ideally its typed letters, so there's one thing to
    /// learn; failing that, two of its letters and J or K. Words you write
    /// most pick first. Press-only shorthands with nothing safe are
    /// returned apart.
    static func assignPressKeys(
        _ shorthands: [LaptopShorthand],
        realWords: Set<String>,
        usage: [String: Int] = [:]
    ) -> ([LaptopShorthand], [LaptopShorthand]) {
        var result = shorthands
        let rollover = rolloverStarts(vocabulary: usage, realWords: realWords)
        // Typing another word's letters quickly must not press this one.
        var typedBy: [String: String] = [:]
        for shorthand in shorthands {
            for token in shorthand.tokens { typedBy[ShorthandLetters.signature(token)] = shorthand.word }
        }
        var used: Set<String> = []

        var pressedWords: Set<String> = []
        var awkward: [LaptopShorthand] = []
        var dropped: Set<Int> = []
        let order = shorthands.indices.sorted {
            (usage[shorthands[$0].word] ?? 0, -$0) > (usage[shorthands[$1].word] ?? 0, -$1)
        }
        for index in order {
            let shorthand = shorthands[index]
            let keys = pressedWords.contains(shorthand.word)
                ? nil
                : safePressKeys(for: shorthand, used: used, rollover: rollover, typedBy: typedBy)
            guard let keys else {
                result[index] = shorthand.withPressKeys(nil, adjusted: false)
                if shorthand.kind == .pressTogether {
                    awkward.append(shorthand)
                    dropped.insert(index)
                }
                continue
            }
            used.insert(ShorthandLetters.signature(keys))
            pressedWords.insert(shorthand.word)
            let original = shorthand.chordKeys.map { $0.lowercased() }.joined()
            let adjusted = ShorthandLetters.signature(keys) != ShorthandLetters.signature(original)
            result[index] = shorthand.withPressKeys(keys, adjusted: adjusted)
        }
        let kept = result.enumerated().filter { !dropped.contains($0.offset) }.map(\.element)
        return (kept, awkward)
    }

    /// Signatures of how your words start: three letters that land together
    /// when you type them fast.
    static func rolloverStarts(vocabulary: [String: Int], realWords: Set<String>) -> Set<String> {
        var starts: Set<String> = []
        let words = Set(vocabulary.keys).union(realWords).union(ShorthandLetters.literalWords).union(ShorthandLetters.commonTokens)
        for word in words {
            let letters = word.lowercased().prefix { ShorthandLetters.isShorthandCharacter($0) }
            guard letters.count >= pressKeyCount else { continue }
            starts.insert(ShorthandLetters.signature(letters.prefix(pressKeyCount)))
        }
        return starts
    }

    static func safePressKeys(
        for shorthand: LaptopShorthand,
        used: Set<String>,
        rollover: Set<String>,
        typedBy: [String: String]
    ) -> String? {
        let word = shorthand.word
        let wordLetters = Array(word.filter { $0.isASCII && $0.isLetter })
        guard wordLetters.count >= minimumPressWordLength, let first = wordLetters.first else { return nil }
        let original = Set(shorthand.chordKeys.map { $0.lowercased() }.filter { $0.count == 1 }.compactMap(\.first)
            .filter { LaptopErgonomics.keys[$0] != nil })
        let typed = Set(shorthand.tokens.first ?? "")
        let letters = Array(Set(wordLetters).union(markerKeys.keys)).sorted()

        var best: (score: Double, keys: [Character])?
        forEachCombination(of: letters, size: pressKeyCount) { keys in
            let signature = ShorthandLetters.signature(keys)
            let markers = keys.filter { !wordLetters.contains($0) }
            // Your own typed letters are fine: typing them fast gives the same word.
            guard markers.count <= 1, !used.contains(signature), !rollover.contains(signature),
                  typedBy[signature].map({ $0 == word }) ?? true,
                  let cost = LaptopErgonomics.cost(keys), cost <= LaptopErgonomics.limit(keys: keys.count) else { return }
            var score = cost + markers.reduce(0) { $0 + (markerKeys[$1] ?? 0) }
            if !keys.contains(first) { score += 1.0 }
            if Set(keys) == typed { score -= 1.0 }
            // Keys you already press on the Forge are easy to remember.
            score -= Double(keys.filter(original.contains).count) * 0.6
            if best == nil || score < best!.score { best = (score, keys) }
        }
        guard let keys = best?.keys else { return nil }
        return wordOrder(keys, word: word).map(String.init).joined()
    }

    static func forEachCombination(of items: [Character], size: Int, _ body: ([Character]) -> Void) {
        var chosen: [Character] = []
        func recurse(_ start: Int) {
            if chosen.count == size { body(chosen); return }
            guard start < items.count, items.count - start >= size - chosen.count else { return }
            for index in start..<items.count {
                chosen.append(items[index])
                recurse(index + 1)
                chosen.removeLast()
            }
        }
        recurse(0)
    }

    static func pressTogether(_ chord: ChordEntry, output: String, signature: String?) -> LaptopShorthand {
        LaptopShorthand(
            chordID: chord.id, output: output, chordKeys: chord.inputKeys,
            letters: signature.map { wordOrder(Array($0), word: output.lowercased()).map(String.init).joined() } ?? "",
            kind: .pressTogether, tokens: [], chordSignature: signature
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

    /// Every token the builder might suggest for these chords, so only
    /// those need a real-word check.
    public static func candidateTokens(for chords: [ChordEntry]) -> Set<String> {
        var tokens: Set<String> = []
        for chord in chords where chord.enabled {
            guard let output = textOutput(of: chord) else { continue }
            let word = output.lowercased()
            guard savesEnough(word: word) else { continue }
            let letters = Array(word.filter { $0.isASCII && $0.isLetter })
            for size in [3, 4] where word.count - size >= minimumSavings {
                tokens.formUnion(codeCandidates(letters, size: size).map(\.letters))
            }
        }
        return tokens
    }
}
