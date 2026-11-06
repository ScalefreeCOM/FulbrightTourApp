import Foundation

public struct FieldChange: Identifiable, Hashable, Sendable {
    public var id: String { "\(participantId)|\(field.rawValue)" }
    public let participantId: String
    public let participantName: String
    public let field: ParticipantField
    public let oldValue: String
    public let newValue: String
    public let reason: String
}

public enum IssueSeverity: Int, Comparable, Sendable {
    case info = 0, warning, error
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    public var label: String { ["Info", "Warning", "Error"][rawValue] }
}

public struct DataIssue: Identifiable, Hashable, Sendable {
    public var id: String { "\(participantId)|\(field?.rawValue ?? "-")|\(message)" }
    public let participantId: String
    public let participantName: String
    public let field: ParticipantField?
    public let severity: IssueSeverity
    public let message: String
}

public struct CleansingReport: Sendable {
    public var changes: [FieldChange] = []
    public var issues: [DataIssue] = []
}

/// Rule-based cleansing and validation of participant (Lead) data.
public struct Cleanser: Sendable {
    public var settings: CleansingSettings
    public var tourEnd: Date
    /// Fields required by at least one host — missing values are reported.
    public var requiredFields: Set<ParticipantField>

    public init(settings: CleansingSettings, tourEnd: Date, requiredFields: Set<ParticipantField>) {
        self.settings = settings; self.tourEnd = tourEnd; self.requiredFields = requiredFields
    }

    public func run(_ participants: [Participant]) -> CleansingReport {
        var report = CleansingReport()
        var cleaned: [Participant] = []

        for p in participants {
            var c = p
            for field in ParticipantField.allCases {
                let old = p[field]
                guard !old.isEmpty else { continue }
                if let (new, reason) = normalize(field, old), new != old {
                    report.changes.append(FieldChange(participantId: p.id, participantName: p.displayName,
                                                      field: field, oldValue: old, newValue: new, reason: reason))
                    c[field] = new
                }
            }
            report.issues += validate(c)
            cleaned.append(c)
        }
        report.issues += duplicates(cleaned)
        report.issues.sort { ($0.severity, $0.participantName) > ($1.severity, $1.participantName) }
        return report
    }

    // MARK: Normalisation

    public func normalize(_ field: ParticipantField, _ value: String) -> (String, String)? {
        let v = Text.clean(value)
        switch field {
        case .firstName, .lastName, .emergencyContact:
            let n = Names.normalize(v)
            return (n, n == v ? "Whitespace" : "Capitalisation")
        case .email:
            return (v.lowercased().replacingOccurrences(of: " ", with: ""), "Lower-case email")
        case .phone, .emergencyPhone:
            guard let p = Phone.normalize(v, defaultCode: settings.defaultCountryCallingCode) else { return (v, "Whitespace") }
            return (p, "International phone format")
        case .birthDate, .passportExpiry:
            guard let d = Dates.parse(v) else { return (v, "Whitespace") }
            return (Dates.iso(d), "ISO date (YYYY-MM-DD)")
        case .nationality, .passportIssuingCountry:
            guard let c = Countries.normalize(v) else { return (v, "Whitespace") }
            return (c, "Standard country name")
        case .passportNumber:
            return (Passport.normalize(v), "Upper-case, no separators")
        case .identificationType:
            let l = v.lowercased()
            if l.contains("pass") || l.contains("reisepass") { return ("Passport", "Org picklist value") }
            if l.contains("id") || l.contains("ausweis") || l.contains("personal") { return ("National/Personal ID card", "Org picklist value") }
            return (v, "Whitespace")
        case .organization, .title, .dietary:
            return (v, "Whitespace")
        }
    }

    // MARK: Validation

    public func validate(_ p: Participant) -> [DataIssue] {
        var out: [DataIssue] = []
        func add(_ f: ParticipantField?, _ s: IssueSeverity, _ m: String) {
            out.append(DataIssue(participantId: p.id, participantName: p.displayName, field: f, severity: s, message: m))
        }

        for f in requiredFields.sorted(by: { $0.rawValue < $1.rawValue }) where p[f].isEmpty {
            add(f, .error, "\(f.label) is missing (required by a host)")
        }
        if !p[.email].isEmpty && !EmailRules.isValid(p[.email]) { add(.email, .error, "Email address looks invalid") }
        if !p[.phone].isEmpty && Phone.normalize(p[.phone], defaultCode: settings.defaultCountryCallingCode) == nil {
            add(.phone, .warning, "Phone number could not be normalised")
        }
        for f in [ParticipantField.birthDate, .passportExpiry] where !p[f].isEmpty && Dates.parse(p[f]) == nil {
            add(f, .error, "\(f.label) is not a valid date")
        }
        if let b = Dates.parse(p[.birthDate]) {
            let age = Calendar.current.dateComponents([.year], from: b, to: tourEnd).year ?? 0
            if age < 16 || age > 100 { add(.birthDate, .warning, "Unusual age (\(age)) — check date of birth") }
        }
        for f in [ParticipantField.nationality, .passportIssuingCountry] where !p[f].isEmpty && Countries.normalize(p[f]) == nil {
            add(f, .warning, "Unknown country \"\(p[f])\"")
        }
        if !p[.passportNumber].isEmpty {
            let n = Passport.normalize(p[.passportNumber])
            if !Passport.isPlausible(n) { add(.passportNumber, .warning, "Passport/ID number has unusual format") }
        }
        if let exp = Dates.parse(p[.passportExpiry]) {
            let minValid = Calendar.current.date(byAdding: .month, value: settings.passportMinValidityMonths, to: tourEnd) ?? tourEnd
            if exp < tourEnd {
                add(.passportExpiry, .error, "Passport expires before the end of the tour (\(Dates.iso(exp)))")
            } else if exp < minValid {
                add(.passportExpiry, .warning, "Passport valid less than \(settings.passportMinValidityMonths) months after the tour")
            }
        }
        return out
    }

    public func duplicates(_ ps: [Participant]) -> [DataIssue] {
        var out: [DataIssue] = []
        func groups(_ key: (Participant) -> String?) -> [[Participant]] {
            Dictionary(grouping: ps.compactMap { p in key(p).map { ($0, p) } }, by: { $0.0 })
                .values.map { $0.map(\.1) }.filter { $0.count > 1 }
        }
        var seen = Set<String>()
        let byEmail = groups { $0[.email].isEmpty ? nil : $0[.email].lowercased() }
        let byName = groups { p in
            let n = Text.fold(p[.firstName] + " " + p[.lastName])
            return n.trimmingCharacters(in: .whitespaces).isEmpty ? nil : n + "|" + p[.birthDate]
        }
        for (g, why) in byEmail.map({ ($0, "same email") }) + byName.map({ ($0, "same name and birth date") }) {
            for p in g {
                let others = g.filter { $0.id != p.id }.map(\.id).joined(separator: ", ")
                let key = p.id + why
                guard seen.insert(key).inserted else { continue }
                out.append(DataIssue(participantId: p.id, participantName: p.displayName, field: nil, severity: .warning,
                                     message: "Possible duplicate (\(why)) of member \(others) — merge in Salesforce"))
            }
        }
        return out
    }
}

// MARK: - Helpers

public enum Text {
    /// Removes invisible direction marks / NBSP and collapses whitespace.
    public static func clean(_ s: String) -> String {
        let invisible: Set<Character> = ["\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
                                         "\u{200B}", "\u{200E}", "\u{200F}", "\u{FEFF}"]
        let filtered = String(s.filter { !invisible.contains($0) }).replacingOccurrences(of: "\u{00A0}", with: " ")
        return filtered.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Case- and diacritic-insensitive key.
    public static func fold(_ s: String) -> String {
        clean(s).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en"))
    }
}

public enum Names {
    static let particles: Set<String> = ["von", "van", "de", "der", "den", "du", "da", "di", "la", "le", "zu", "zum", "zur", "del", "dos", "das", "ter"]

    /// Fixes ALL-CAPS / all-lower names; leaves deliberately mixed case (McDonald, DeLuca) untouched.
    public static func normalize(_ s: String) -> String {
        let v = Text.clean(s)
        let letters = v.filter(\.isLetter)
        guard !letters.isEmpty else { return v }
        let allUpper = letters == letters.uppercased()
        let allLower = letters == letters.lowercased()
        guard allUpper || allLower else { return v }
        let words = v.split(separator: " ").map(String.init)
        return words.enumerated().map { i, w in
            if i > 0 && particles.contains(w.lowercased()) { return w.lowercased() }
            return w.split(separator: "-", omittingEmptySubsequences: false)
                .map { part in part.split(separator: "'", omittingEmptySubsequences: false).map { cap(String($0)) }.joined(separator: "'") }
                .joined(separator: "-")
        }.joined(separator: " ")
    }

    private static func cap(_ s: String) -> String {
        guard let f = s.first else { return s }
        return String(f).uppercased() + s.dropFirst().lowercased()
    }
}

public enum Phone {
    /// Returns E.164-style "+<digits>" or nil if implausible.
    public static func normalize(_ s: String, defaultCode: String) -> String? {
        var v = Text.clean(s)
        v = v.replacingOccurrences(of: "(0)", with: "")
        var digits = v.filter { $0.isNumber || $0 == "+" }
        if digits.hasPrefix("00") { digits = "+" + digits.dropFirst(2) }
        else if digits.hasPrefix("0") { digits = defaultCode + digits.dropFirst() }
        else if !digits.hasPrefix("+") { digits = defaultCode + digits }
        let body = digits.dropFirst().filter(\.isNumber)
        guard digits.hasPrefix("+"), (8...15).contains(body.count) else { return nil }
        return "+" + body
    }
}

public enum Dates {
    static let formats = ["yyyy-MM-dd", "dd.MM.yyyy", "d.M.yyyy", "dd/MM/yyyy", "d/M/yyyy", "dd-MM-yyyy",
                          "yyyy/MM/dd", "dd.MM.yy", "d MMMM yyyy", "d MMM yyyy", "MMMM d, yyyy", "yyyy-MM-dd'T'HH:mm:ss.SSSZ"]

    public static func parse(_ s: String) -> Date? {
        let v = Text.clean(s)
        guard !v.isEmpty else { return nil }
        for locale in ["en_US_POSIX", "de_DE"] {
            for f in formats {
                let df = DateFormatter()
                df.locale = Locale(identifier: locale)
                df.timeZone = TimeZone(identifier: "UTC")
                df.dateFormat = f
                df.isLenient = false
                if let d = df.date(from: v) {
                    // two-digit years: treat > current year as 19xx
                    if f.hasSuffix("yy") && !f.hasSuffix("yyyy"), d > Date() {
                        return Calendar(identifier: .gregorian).date(byAdding: .year, value: -100, to: d)
                    }
                    return d
                }
            }
        }
        return nil
    }

    public static func iso(_ d: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "UTC")
        df.dateFormat = "yyyy-MM-dd"
        return df.string(from: d)
    }

    /// dd.MM.yyyy — the format most officials expect in their lists.
    public static func display(_ s: String) -> String {
        guard let d = parse(s) else { return s }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "UTC")
        df.dateFormat = "dd.MM.yyyy"
        return df.string(from: d)
    }
}

public enum Countries {
    static let demonyms: [String: String] = [
        "german": "DE", "deutsch": "DE", "deutsche": "DE", "american": "US", "usa": "US", "u.s.": "US", "u.s.a.": "US",
        "us": "US", "united states of america": "US", "amerikanisch": "US", "french": "FR", "französisch": "FR",
        "british": "GB", "uk": "GB", "england": "GB", "britisch": "GB", "austrian": "AT", "österreichisch": "AT",
        "swiss": "CH", "schweizerisch": "CH", "italian": "IT", "italienisch": "IT", "spanish": "ES", "spanisch": "ES",
        "dutch": "NL", "niederländisch": "NL", "hungarian": "HU", "ungarisch": "HU", "polish": "PL", "polnisch": "PL",
        "ukrainian": "UA", "ukrainisch": "UA", "canadian": "CA", "kanadisch": "CA", "belgian": "BE", "belgisch": "BE",
        "turkish": "TR", "türkisch": "TR", "greek": "GR", "griechisch": "GR", "czech": "CZ", "tschechisch": "CZ",
        "kosovar": "XK", "kosovo": "XK", "chinese": "CN", "indian": "IN", "japanese": "JP", "brazilian": "BR",
        "mexican": "MX", "irish": "IE", "portuguese": "PT", "swedish": "SE", "danish": "DK", "norwegian": "NO",
        "finnish": "FI", "romanian": "RO", "bulgarian": "BG", "croatian": "HR", "serbian": "RS", "russian": "RU",
    ]

    /// UN-style names used in the org's country picklists that macOS spells differently.
    static let officialNames: [String: String] = [
        "Antigua and Barbuda": "AG", "Bolivia (Plurinational State of)": "BO", "Bosnia and Herzegovina": "BA",
        "China": "CN", "Congo": "CG", "Côte d'Ivoire": "CI", "Democratic People's Republic of Korea": "KP",
        "Democratic Republic of the Congo": "CD", "Iran (Islamic Republic of)": "IR", "Lao People's Democratic Republic": "LA",
        "Micronesia (Federated States of)": "FM", "Republic of Korea": "KR", "Republic of Moldova": "MD",
        "Russian Federation": "RU", "Saint Kitts and Nevis": "KN", "Saint Lucia": "LC", "Saint Vincent and the Grenadines": "VC",
        "Sao Tome and Principe": "ST", "Syrian Arab Republic": "SY", "Trinidad and Tobago": "TT",
        "United Kingdom of Great Britain and Northern Ireland": "GB", "United Republic of Tanzania": "TZ",
        "United States of America": "US", "Venezuela (Bolivarian Republic of)": "VE", "Viet Nam": "VN",
        // common informal spellings
        "turkey": "TR", "türkei": "TR", "south korea": "KR", "north korea": "KP", "russia": "RU", "vietnam": "VN",
        "great britain": "GB", "großbritannien": "GB", "england": "GB", "ivory coast": "CI", "czech republic": "CZ", "tschechische republik": "CZ",
    ]

    static let lookup: [String: String] = {
        var m: [String: String] = [:]
        let en = Locale(identifier: "en"), de = Locale(identifier: "de")
        for r in Locale.Region.isoRegions where r.identifier.count == 2 && r.identifier.allSatisfy(\.isLetter) {
            let code = r.identifier
            m[code.lowercased()] = code
            if let n = en.localizedString(forRegionCode: code) { m[Text.fold(n)] = code }
            if let n = de.localizedString(forRegionCode: code) { m[Text.fold(n)] = code }
        }
        for (k, v) in demonyms { m[Text.fold(k)] = v }
        for (k, v) in officialNames { m[Text.fold(k)] = v }
        return m
    }()

    /// Org picklist value by ISO code (e.g. "US" → "United States of America", "TR" → "Türkiye").
    static let orgValueByCode: [String: String] = {
        var m: [String: String] = [:]
        for v in OrgPicklists.countries { if let c = lookup[Text.fold(v)], m[c] == nil { m[c] = v } }
        return m
    }()

    /// ISO 3166 alpha-2 code for any supported spelling, or nil.
    public static func code(_ s: String) -> String? { lookup[Text.fold(s)] }

    /// Normalises to the exact Citizenship/Issuing Country picklist value of the org, or nil if unknown.
    public static func normalize(_ s: String) -> String? {
        if let exact = OrgPicklists.countries.first(where: { Text.fold($0) == Text.fold(s) }) { return exact }
        guard let code = lookup[Text.fold(s)] else { return nil }
        return orgValueByCode[code] ?? Locale(identifier: "en").localizedString(forRegionCode: code)
    }
}

public enum Passport {
    public static func normalize(_ s: String) -> String {
        Text.clean(s).uppercased().filter { $0.isLetter || $0.isNumber }
    }
    public static func isPlausible(_ s: String) -> Bool {
        (6...12).contains(s.count) && s.contains(where: \.isNumber) && s.allSatisfy { $0.isASCII }
    }
}

public enum EmailRules {
    public static let freemailDomains: Set<String> = ["gmail.com", "googlemail.com", "gmx.de", "gmx.net", "web.de", "outlook.com",
                                                      "outlook.de", "hotmail.com", "hotmail.de", "yahoo.com", "yahoo.de",
                                                      "icloud.com", "me.com", "t-online.de", "posteo.de", "proton.me", "protonmail.com"]
    public static func isValid(_ s: String) -> Bool {
        s.range(of: #"^[A-Za-z0-9._%+'-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"#, options: .regularExpression) != nil
    }
    /// Extracts the bare address from `"Name" <a@b.c>`.
    public static func address(from header: String) -> String {
        if let l = header.lastIndex(of: "<"), let r = header.lastIndex(of: ">"), l < r {
            return String(header[header.index(after: l)..<r]).lowercased().trimmingCharacters(in: .whitespaces)
        }
        return header.lowercased().trimmingCharacters(in: .whitespaces)
    }
    public static func displayName(from header: String) -> String {
        if let l = header.lastIndex(of: "<") {
            let n = header[..<l].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if !n.isEmpty { return n }
        }
        return address(from: header)
    }
}
