import XCTest
@testable import StudyToursCore

final class CleansingTests: XCTestCase {
    let tourEnd = Dates.parse("2026-09-30")!

    func cleanser(_ required: Set<ParticipantField> = []) -> Cleanser {
        Cleanser(settings: CleansingSettings(), tourEnd: tourEnd, requiredFields: required)
    }

    func testNames() {
        XCTAssertEqual(Names.normalize("  JANE   DOE "), "Jane Doe")
        XCTAssertEqual(Names.normalize("anna von der heide"), "Anna von der Heide")
        XCTAssertEqual(Names.normalize("MARIE-CLAIRE O'NEIL"), "Marie-Claire O'Neil")
        XCTAssertEqual(Names.normalize("McDonald"), "McDonald")   // mixed case untouched
    }

    func testPhoneStripsInvisibleCharacters() {
        // Directional marks like those found in the team sheet.
        XCTAssertEqual(Phone.normalize("\u{202A}+49 1522 0000000\u{202C}", defaultCode: "+49"), "+4915220000000")
        XCTAssertEqual(Phone.normalize("0176 123 45678", defaultCode: "+49"), "+4917612345678")
        XCTAssertEqual(Phone.normalize("0036 30 123 4567", defaultCode: "+49"), "+36301234567")
        XCTAssertNil(Phone.normalize("123", defaultCode: "+49"))
    }

    func testDates() {
        XCTAssertEqual(Dates.iso(Dates.parse("03.04.1990")!), "1990-04-03")
        XCTAssertEqual(Dates.iso(Dates.parse("1990-04-03")!), "1990-04-03")
        XCTAssertEqual(Dates.display("1990-04-03"), "03.04.1990")
        XCTAssertNil(Dates.parse("not a date"))
    }

    func testCountries() {
        XCTAssertEqual(Countries.normalize("Deutschland"), "Germany")
        XCTAssertEqual(Countries.normalize("german"), "Germany")
        XCTAssertEqual(Countries.normalize("HU"), "Hungary")
        XCTAssertEqual(Countries.normalize("USA"), "United States of America")   // org picklist value
        XCTAssertEqual(Countries.normalize("Turkey"), "Türkiye")
        XCTAssertEqual(Countries.normalize("Tschechien"), "Czechia")
        XCTAssertTrue(OrgPicklists.countries.contains(Countries.normalize("deutsch")!))
        // every country input must end up as a valid (restricted) picklist value
        for input in ["UK", "Großbritannien", "Vietnam", "South Korea", "Russia", "Bosnia & Herzegovina", "Ivory Coast"] {
            let v = Countries.normalize(input)
            XCTAssertTrue(v.map(OrgPicklists.countries.contains) ?? false, "\(input) → \(v ?? "nil")")
        }
        // and every org value maps to itself
        for v in OrgPicklists.countries { XCTAssertEqual(Countries.normalize(v), v) }
        XCTAssertNil(Countries.normalize("Atlantis"))
    }

    func testPassportExpiryRules() {
        let expired = Participant(id: "L1", values: [.firstName: "Jane", .lastName: "Doe", .passportExpiry: "2026-09-01", .passportNumber: "C01X00T47"])
        let short = Participant(id: "L2", values: [.firstName: "John", .lastName: "Doe", .passportExpiry: "2026-12-01", .passportNumber: "C01X00T48"])
        let fine = Participant(id: "L3", values: [.firstName: "Max", .lastName: "Muster", .passportExpiry: "2030-01-01", .passportNumber: "C01X00T49"])
        let issues = cleanser().run([expired, short, fine]).issues
        XCTAssertTrue(issues.contains { $0.participantId == "L1" && $0.severity == .error && $0.field == .passportExpiry })
        XCTAssertTrue(issues.contains { $0.participantId == "L2" && $0.severity == .warning && $0.field == .passportExpiry })
        XCTAssertFalse(issues.contains { $0.participantId == "L3" && $0.field == .passportExpiry })
    }

    func testRequiredFieldsAndChanges() {
        let p = Participant(id: "L1", values: [.firstName: "JANE", .lastName: "DOE", .email: " Jane.Doe@Example.com ", .birthDate: "03.04.1990"])
        let r = cleanser([.passportNumber]).run([p])
        XCTAssertTrue(r.changes.contains { $0.field == .firstName && $0.newValue == "Jane" })
        XCTAssertTrue(r.changes.contains { $0.field == .email && $0.newValue == "jane.doe@example.com" })
        XCTAssertTrue(r.changes.contains { $0.field == .birthDate && $0.newValue == "1990-04-03" })
        XCTAssertTrue(r.issues.contains { $0.field == .passportNumber && $0.severity == .error })
    }

    func testDuplicates() {
        let a = Participant(id: "L1", values: [.firstName: "Jane", .lastName: "Doe", .email: "jane@example.com"])
        let b = Participant(id: "L2", values: [.firstName: "Jäne", .lastName: "DOE", .email: "JANE@example.com"])
        let issues = cleanser().run([a, b]).issues.filter { $0.message.contains("duplicate") }
        XCTAssertEqual(Set(issues.map(\.participantId)), ["L1", "L2"])
    }
}

final class AssistantTests: XCTestCase {
    func msg(from: String) -> MailMessage {
        MailMessage(id: "m1", threadId: "t1", from: from, to: "tour@example.com", subject: "Question about the meeting point",
                    date: Date(), snippet: "", body: "Hello, where do we meet?", labelIds: [])
    }

    func tour() -> Tour {
        var t = Tour(name: "Test Tour", startDate: Date(), endDate: Date())
        var h = Host(name: "Example Ministry", accountId: "001A")
        h.contacts = [HostContact(id: "003A", name: "Jane Doe", email: "jane.doe@ministry.example.org", title: "Assistant")]
        t.hosts = [h]
        t.team = [TeamMember(name: "Max Muster", email: "max@example.com", roles: ["Lead"])]
        return t
    }

    func testIdentifyOfficialByDomainEvenWithoutSalesforce() {
        let id = Assistant.identify(address: "someone.else@ministry.example.org", tour: tour(), salesforceMatches: [])
        XCTAssertEqual(id.kind, .official)
    }

    func testContactBeatsLead() {
        let refs = [SFRecordRef(kind: .lead, id: "00Q1", name: "A", email: "a@x.org", accountId: nil, accountName: nil),
                    SFRecordRef(kind: .contact, id: "0031", name: "A", email: "a@x.org", accountId: "001", accountName: "X")]
        XCTAssertEqual(Assistant.identify(address: "a@x.org", tour: tour(), salesforceMatches: refs).kind, .official)
    }

    func testSalesforceUserIsOrganiser() {
        let user = SFRecordRef(kind: .user, id: "005A", name: "Max Muster", email: "max@example.com", accountId: nil, accountName: nil)
        XCTAssertEqual(Assistant.identify(address: "max@example.com", tour: tour(), salesforceMatches: [user]).kind, .team)
    }

    func testAutoSendGuard() {
        var settings = AssistantSettings(); settings.autoSend = true
        let lead = SenderIdentity(kind: .attendee, record: SFRecordRef(kind: .lead, id: "00Q1", name: "A", email: "a@x.org", accountId: nil, accountName: nil), source: "")
        let triage = MailTriage(relatedToTour: true, senderType: "attendee", importance: "normal", needsReply: true, topic: "", reason: "")
        let good = DraftReply(subject: nil, body: "We meet at 9:00 at the hotel lobby.", confident: true, missingInfo: [])
        XCTAssertTrue(Assistant.autoSendDecision(identity: lead, triage: triage, reply: good, address: "a@x.org", settings: settings, alreadyHandled: false, sentThisRun: 0).allowed)

        let check = DraftReply(subject: nil, body: "We meet at [CHECK: time].", confident: true, missingInfo: [])
        XCTAssertFalse(Assistant.autoSendDecision(identity: lead, triage: triage, reply: check, address: "a@x.org", settings: settings, alreadyHandled: false, sentThisRun: 0).allowed)

        let official = SenderIdentity(kind: .official, record: nil, source: "")
        XCTAssertFalse(Assistant.autoSendDecision(identity: official, triage: triage, reply: good, address: "a@x.org", settings: settings, alreadyHandled: false, sentThisRun: 0).allowed)

        var high = triage; high.importance = "high"
        XCTAssertFalse(Assistant.autoSendDecision(identity: lead, triage: high, reply: good, address: "a@x.org", settings: settings, alreadyHandled: false, sentThisRun: 0).allowed)

        settings.autoSend = false
        XCTAssertFalse(Assistant.autoSendDecision(identity: lead, triage: triage, reply: good, address: "a@x.org", settings: settings, alreadyHandled: false, sentThisRun: 0).allowed)
    }

    func testRedaction() {
        let r = Assistant.redact("My passport is C01X00T47 and phone 017612345678, meeting on 2026-09-30.")
        XCTAssertFalse(r.contains("C01X00T47"))
        XCTAssertFalse(r.contains("017612345678"))
        XCTAssertTrue(r.contains("2026-09-30"))
    }

    func testDecodeFencedJSON() {
        let t = Assistant.decode(MailTriage.self, from: "```json\n{\"relatedToTour\":true,\"senderType\":\"attendee\",\"importance\":\"low\",\"needsReply\":false,\"topic\":\"x\",\"reason\":\"y\"}\n```")
        XCTAssertEqual(t?.senderType, "attendee")
    }

    func testRecordProposalOnlyForUnknownTourMail() {
        let m = msg(from: "\"Jane Doe\" <jane@example.com>")
        let triage = MailTriage(relatedToTour: true, senderType: "attendee", importance: "normal", needsReply: true, topic: "", reason: "")
        let unknown = SenderIdentity(kind: .unknown, record: nil, source: "")
        let p = Assistant.recordProposal(m, triage: triage, identity: unknown)
        XCTAssertEqual(p?.kind, .lead)
        XCTAssertEqual(p?.lastName, "Doe")
        let known = SenderIdentity(kind: .attendee, record: nil, source: "")
        XCTAssertNil(Assistant.recordProposal(m, triage: triage, identity: known))
        var unrelated = triage; unrelated.relatedToTour = false
        XCTAssertNil(Assistant.recordProposal(m, triage: unrelated, identity: unknown))
    }

    func testEmailHeaderParsing() {
        XCTAssertEqual(EmailRules.address(from: "\"Jane Doe\" <Jane@Example.com>"), "jane@example.com")
        XCTAssertEqual(EmailRules.displayName(from: "\"Jane Doe\" <jane@example.com>"), "Jane Doe")
    }

    func testDigestMentionsOverdue() {
        var t = tour()
        t.startDate = Calendar.current.date(byAdding: .day, value: 10, to: Date())!
        t.endDate = t.startDate
        let d = Assistant.teamDigest(t)
        XCTAssertTrue(d.contains("Overdue"))
    }
}

final class ExportTests: XCTestCase {
    func testXLSXIsValidZipWithSheet() throws {
        let sheet = XLSXWriter.Sheet(name: "Participants", title: "Test & <title>", headers: ["Last name", "First name"],
                                     rows: [["Doe", "Jane"], ["Müller", "Max"]])
        let data = XLSXWriter.build([sheet])
        XCTAssertEqual(data.prefix(2), Data([0x50, 0x4B]))   // "PK"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID().uuidString).xlsx")
        try data.write(to: url)
        // Validate with the system unzip: archive must list all parts and be CRC-correct.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-t", url.path]
        let pipe = Pipe(); p.standardOutput = pipe
        try p.run(); p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(p.terminationStatus, 0, out)
        XCTAssertTrue(out.contains("xl/worksheets/sheet1.xml"))
        let xml = XLSXWriter.sheetXML(sheet)
        XCTAssertTrue(xml.contains("Test &amp; &lt;title&gt;"))
        XCTAssertTrue(xml.contains("Müller"))
    }

    func testColumnNames() {
        XCTAssertEqual(XLSXWriter.colName(0), "A")
        XCTAssertEqual(XLSXWriter.colName(25), "Z")
        XCTAssertEqual(XLSXWriter.colName(26), "AA")
    }

    func testHostExportOrderAndHeaders() {
        let tour = Tour(name: "Tour", startDate: Date(), endDate: Date())
        var host = Host(name: "Ministry")
        host.requiredFields = [.lastName, .firstName, .birthDate]
        host.columnHeaders[.birthDate] = "Geburtsdatum"
        let ps = [Participant(id: "2", values: [.lastName: "Zeta", .firstName: "A", .birthDate: "1990-04-03"]),
                  Participant(id: "1", values: [.lastName: "Alpha", .firstName: "B", .birthDate: "1985-01-02"])]
        let s = ParticipantExport.sheet(host: host, tour: tour, participants: ps)
        XCTAssertEqual(s.headers, ["No.", "Last name", "First name", "Geburtsdatum"])
        XCTAssertEqual(s.rows.first, ["1", "Alpha", "B", "02.01.1985"])
    }

    func testDefaultScrubCoversPassportFields() {
        XCTAssertTrue(ParticipantField.defaultScrub.allSatisfy(\.isDeletableAfterTour))
        XCTAssertTrue(ParticipantField.defaultScrub.contains(.emergencyPhone))
        XCTAssertFalse(ParticipantField.defaultScrub.contains(.email))
        XCTAssertTrue(ParticipantField.defaultScrub.contains(.passportNumber))
    }

    func testSettingsRoundTrip() throws {
        var d = AppData()
        d.tours = [Tour(name: "T", startDate: Date(), endDate: Date())]
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let back = try dec.decode(AppData.self, from: enc.encode(d))
        XCTAssertEqual(back.tours.first?.tasks.count, PhasePlan.defaultTasks().count)
        // field names never come from stored settings, only from the Salesforce mapping
        XCTAssertEqual(back.settings.salesforce.field(.passportNumber), SFMap["member.passportNumber"])
    }

    func testSOQLEscaping() {
        XCTAssertEqual(SalesforceClient.esc("O'Neil"), "O\\'Neil")
    }
}

final class ProgramDateTests: XCTestCase {
    func testCalendarDayRoundTripInLocalTimeZone() {
        // A date picker yields local midnight; it must be written as the same calendar day.
        let localMidnight = Calendar.current.date(from: DateComponents(year: 2027, month: 3, day: 4))!
        let s = SalesforceClient.dayFormatter.string(from: localMidnight)
        XCTAssertEqual(s, "2027-03-04")
        XCTAssertEqual(SalesforceClient.dayFormatter.date(from: s), localMidnight)
    }
}

final class GmailAndActivityTests: XCTestCase {
    func decode(_ raw: String) -> String { String(decoding: PKCE.b64urlDecode(raw)!, as: UTF8.self) }

    func testReplyIsThreaded() {
        let msg = decode(MailComposer.raw(to: "jane@example.com", subject: "Re: Treffpunkt für Montag", body: "Hallo Jane",
                                          inReplyTo: "<abc@mail.example.com>", references: "<x@mail.example.com>"))
        XCTAssertTrue(msg.contains("To: jane@example.com\r\n"))
        XCTAssertTrue(msg.contains("Subject: =?UTF-8?B?"))                       // umlaut encoded per RFC 2047
        XCTAssertTrue(msg.contains("In-Reply-To: <abc@mail.example.com>"))
        XCTAssertTrue(msg.contains("References: <x@mail.example.com> <abc@mail.example.com>"))
        let body = msg.components(separatedBy: "\r\n\r\n").last!
        XCTAssertEqual(String(decoding: Data(base64Encoded: body, options: .ignoreUnknownCharacters)!, as: UTF8.self), "Hallo Jane")
    }

    func testPlainSubjectUnchanged() {
        XCTAssertEqual(MailComposer.encodeHeader("Question"), "Question")
    }

    func testDataProtectionTaskOnMember() {
        let t = SalesforceClient.dataProtectionTask(leadId: "00Q000000000001", fields: [.passportNumber, .passportExpiry], scope: "Program X")
        XCTAssertEqual(t["WhoId"] as? String, "00Q000000000001")
        XCTAssertEqual(t["Status"] as? String, "Completed")
        XCTAssertTrue((t["Description"] as? String ?? "").contains("Passport / ID number"))
        XCTAssertNil(t["WhatId"])   // Leads cannot have WhatId
    }
}

final class KnowledgeBaseTests: XCTestCase {
    func testDocumentIdFromVariousURLs() {
        XCTAssertEqual(KnowledgeBase.documentId(from: "https://docs.google.com/document/d/1AbCdEfGhIjKlMnOp_q-r/edit?tab=t.0"), "1AbCdEfGhIjKlMnOp_q-r")
        XCTAssertNil(KnowledgeBase.documentId(from: "https://example.com/faq"))
    }

    func testTextFromTabsAndTables() {
        let para: ([String]) -> [String: Any] = { texts in ["paragraph": ["elements": texts.map { ["textRun": ["content": $0]] }]] }
        let doc: [String: Any] = ["tabs": [
            ["tabProperties": ["title": "General"], "documentTab": ["body": ["content": [para(["Dress code: business attire\n"])]]]],
            ["tabProperties": ["title": "Travel"], "documentTab": ["body": ["content": [
                ["table": ["tableRows": [["tableCells": [["content": [para(["Meeting point"])]], ["content": [para(["Hotel lobby"])]]]]]]]
            ]]]],
        ]]
        let t = KnowledgeBase.text(fromDocument: doc)
        XCTAssertTrue(t.contains("## General"))
        XCTAssertTrue(t.contains("Dress code: business attire"))
        XCTAssertTrue(t.contains("Meeting point\tHotel lobby"))
    }

    func testReplyPromptContainsKnowledgeBase() {
        let m = MailMessage(id: "m", threadId: "t", from: "Jane Doe <jane@example.com>", to: "", subject: "Dress code?",
                            date: Date(), snippet: "", body: "What should I wear?", labelIds: [])
        let p = Assistant.replyPrompt(m, tour: Tour(name: "T", startDate: Date(), endDate: Date()),
                                      knowledgeBase: "Dress code: business attire", settings: AssistantSettings(), redact: false)
        XCTAssertTrue(p.prompt.contains("Dress code: business attire"))
    }
}

final class DriveStructureTests: XCTestCase {
    func testIdsFromURLs() {
        XCTAssertEqual(DriveStructure.id(from: "https://drive.google.com/drive/folders/1AbCdEfGhIjKlMnOpQ"), "1AbCdEfGhIjKlMnOpQ")
        XCTAssertEqual(DriveStructure.id(from: "https://docs.google.com/presentation/d/1AbCdEfGhIjKlMnOpQ/edit?slide=id.p1#slide=id.p1"), "1AbCdEfGhIjKlMnOpQ")
        XCTAssertEqual(DriveStructure.id(from: "https://drive.google.com/open?id=1AbCdEfGhIjKlMnOpQ"), "1AbCdEfGhIjKlMnOpQ")
        XCTAssertNil(DriveStructure.id(from: "https://example.com"))
    }

    func testRoundTripOfStoredLinks() {
        let folderId = "1FolderIdForTesting_abc", slidesId = "1SlidesIdForTesting-xyz"
        XCTAssertEqual(DriveStructure.id(from: DriveStructure.folderURL(folderId)), folderId)
        XCTAssertEqual(DriveStructure.id(from: DriveStructure.slidesURL(slidesId)), slidesId)
    }

    func testExampleConfigIsValidJSON() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("config/studytours.config.example.json")
        let c = try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: url))
        XCTAssertTrue(c.salesforceURL.contains("my.salesforce.com"))
    }
}

final class HostTemplateTests: XCTestCase {
    /// Builds a realistic host form: title row, German header in row 3 (shared strings), an example row,
    /// styled cells, deflate-compressed like files saved by Excel.
    static func hostTemplate() throws -> Data {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("tpl-\(UUID().uuidString)")
        let files: [String: String] = [
            "[Content_Types].xml": #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/></Types>"#,
            "_rels/.rels": #"<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>"#,
            "xl/workbook.xml": #"<?xml version="1.0" encoding="UTF-8"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Besucherliste" sheetId="1" r:id="rId1"/></sheets></workbook>"#,
            "xl/_rels/workbook.xml.rels": #"<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>"#,
            "xl/styles.xml": #"<?xml version="1.0" encoding="UTF-8"?><styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="2"><font><sz val="11"/><name val="Arial"/></font><font><b/><sz val="11"/><name val="Arial"/></font></fonts><fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills><borders count="2"><border/><border><left style="thin"/><right style="thin"/><top style="thin"/><bottom style="thin"/></border></borders><cellStyleXfs count="1"><xf/></cellStyleXfs><cellXfs count="3"><xf/><xf fontId="1" borderId="1" applyFont="1" applyBorder="1"/><xf borderId="1" applyBorder="1"/></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>"#,
            "xl/sharedStrings.xml": #"<?xml version="1.0" encoding="UTF-8"?><sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="8" uniqueCount="8"><si><t>Besucherliste Bundesministerium (Beispiel)</t></si><si><t>Lfd. Nr.</t></si><si><t>Nachname</t></si><si><t>Vorname</t></si><si><t>Geburtsdatum</t></si><si><t>Staatsangehörigkeit</t></si><si><t>Ausweisnummer</t></si><si><r><t>Muster</t></r><r><t>mann</t></r></si></sst>"#,
            "xl/worksheets/sheet1.xml": #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><dimension ref="A1:F4"/><sheetData><row r="1"><c r="A1" t="s"><v>0</v></c></row><row r="3"><c r="A3" s="1" t="s"><v>1</v></c><c r="B3" s="1" t="s"><v>2</v></c><c r="C3" s="1" t="s"><v>3</v></c><c r="D3" s="1" t="s"><v>4</v></c><c r="E3" s="1" t="s"><v>5</v></c><c r="F3" s="1" t="s"><v>6</v></c></row><row r="4"><c r="A4" s="2"><v>1</v></c><c r="B4" s="2" t="s"><v>7</v></c><c r="C4" s="2"/><c r="D4" s="2"/><c r="E4" s="2"/><c r="F4" s="2"/></row></sheetData></worksheet>"#,
        ]
        for (name, xml) in files {
            let url = dir.appendingPathComponent(name)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try xml.write(to: url, atomically: true, encoding: .utf8)
        }
        let out = dir.appendingPathComponent("template.xlsx")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.currentDirectoryURL = dir
        p.arguments = ["-q", "-X", "-r", out.path, "[Content_Types].xml", "_rels", "xl"]   // deflate, like Excel
        try p.run(); p.waitUntilExit()
        return try Data(contentsOf: out)
    }

    let members = [
        Participant(id: "1", values: [.firstName: "Max", .lastName: "Muster", .birthDate: "1990-04-03", .nationality: "Germany", .passportNumber: "C01X00T47"]),
        Participant(id: "2", values: [.firstName: "Jane", .lastName: "Doe", .birthDate: "1985-01-02", .nationality: "United States of America", .passportNumber: "X1234567"]),
        Participant(id: "3", values: [.firstName: "Ana", .lastName: "Beispiel", .birthDate: "1979-12-24", .nationality: "Hungary", .passportNumber: "HU998877"]),
    ]

    func testReadsDeflatedTemplateWithSharedStrings() throws {
        let t = try XLSXTemplate(data: Self.hostTemplate())
        XCTAssertEqual(t.sheetName, "Besucherliste")
        let pv = try t.preview()
        XCTAssertEqual(pv.rows[3]?["B"], "Nachname")
        XCTAssertEqual(pv.rows[4]?["B"], "Mustermann")          // rich-text shared string
        XCTAssertTrue(pv.asText().contains("F3=Ausweisnummer"))
    }

    func testFallbackMappingFindsGermanHeaders() throws {
        let pv = try XLSXTemplate(data: Self.hostTemplate()).preview()
        let m = try XCTUnwrap(TemplateMapper.fallback(pv))
        XCTAssertEqual(m.headerRow, 3)
        XCTAssertEqual(m.firstDataRow, 4)
        let byCol = Dictionary(uniqueKeysWithValues: m.columns.map { ($0.column, $0.source) })
        XCTAssertEqual(byCol["A"], .index)
        XCTAssertEqual(byCol["B"], .field(.lastName))
        XCTAssertEqual(byCol["C"], .field(.firstName))
        XCTAssertEqual(byCol["D"], .field(.birthDate))
        XCTAssertEqual(byCol["E"], .field(.nationality))
        XCTAssertEqual(byCol["F"], .field(.passportNumber))
    }

    func testFallbackMappingEnglishHeaders() throws {
        let pv = SheetPreview(sheetPath: "xl/worksheets/sheet1.xml", sheetName: "Visitors", rows: [
            1: ["A": "Visitor registration – Example Ministry"],
            2: ["A": "No.", "B": "Surname", "C": "First name", "D": "Date of birth", "E": "Nationality",
                "F": "Passport/ID number", "G": "For official use"],
        ])
        let m = try XCTUnwrap(TemplateMapper.fallback(pv))
        let byCol = Dictionary(uniqueKeysWithValues: m.columns.map { ($0.column, $0.source) })
        XCTAssertEqual(m.headerRow, 2)
        XCTAssertEqual(byCol["B"], .field(.lastName))
        XCTAssertEqual(byCol["C"], .field(.firstName))
        XCTAssertEqual(byCol["D"], .field(.birthDate))
        XCTAssertEqual(byCol["E"], .field(.nationality))
        XCTAssertEqual(byCol["F"], .field(.passportNumber))
        XCTAssertEqual(byCol["G"], ColumnSource.none)
    }

    func testGeminiMappingParsing() throws {
        let pv = try XLSXTemplate(data: Self.hostTemplate()).preview()
        let json = #"{"headerRow":3,"firstDataRow":4,"lastTemplateRow":4,"dateFormat":"dd.MM.yyyy","columns":[{"column":"A","header":"Lfd. Nr.","source":"index"},{"column":"B","source":"lastName"},{"column":"G","source":"constant","value":"Fulbright"},{"column":"H","source":"bogusField"}],"notes":"ok"}"#
        let m = try XCTUnwrap(TemplateMapper.parse(json, preview: pv))
        XCTAssertEqual(m.columns.first { $0.column == "G" }?.source, .constant("Fulbright"))
        XCTAssertEqual(m.columns.first { $0.column == "H" }?.source, ColumnSource.none)   // unknown → ignored
        XCTAssertEqual(m.columns.first { $0.column == "B" }?.header, "Nachname")
    }

    func testFillKeepsTemplateAndWritesAllMembers() throws {
        let t = try XLSXTemplate(data: Self.hostTemplate())
        let m = try XCTUnwrap(TemplateMapper.fallback(try t.preview()))
        let out = try t.filled(with: members, mapping: m)
        let back = try XLSXTemplate(data: out)
        let pv = try back.preview()
        XCTAssertEqual(pv.rows[1]?["A"], "Besucherliste Bundesministerium (Beispiel)")   // title kept
        XCTAssertEqual(pv.rows[3]?["F"], "Ausweisnummer")                                // header kept
        // sorted by last name: Beispiel, Doe, Muster — the example row "Mustermann" is overwritten
        XCTAssertEqual(pv.rows[4]?["B"], "Beispiel")
        XCTAssertEqual(pv.rows[4]?["A"], "1")
        XCTAssertEqual(pv.rows[5]?["B"], "Doe")
        XCTAssertEqual(pv.rows[5]?["D"], "02.01.1985")
        XCTAssertEqual(pv.rows[6]?["F"], "C01X00T47")
        XCTAssertNil(pv.rows[7])
        // styles of the template's data row are reused on new rows
        let sheet = String(decoding: back.entries.first { $0.name == back.sheetPath }!.data, as: UTF8.self)
        XCTAssertTrue(sheet.contains(#"r="B6" s="2""#) || sheet.contains(#"s="2" r="B6""#), sheet)
        XCTAssertTrue(sheet.contains("A1:F6"))   // dimension updated
    }

    func testFewerMembersClearExampleRows() throws {
        let t = try XLSXTemplate(data: Self.hostTemplate())
        var m = try XCTUnwrap(TemplateMapper.fallback(try t.preview()))
        m.lastTemplateRow = 6
        let pv = try XLSXTemplate(data: t.filled(with: [members[0]], mapping: m)).preview()
        XCTAssertEqual(pv.rows[4]?["B"], "Muster")
        XCTAssertNil(pv.rows[5])
    }
}

final class AttachmentMailTests: XCTestCase {
    func testMultipartWithExcel() {
        let xlsx = Data([0x50, 0x4B, 0x03, 0x04, 1, 2, 3])
        let raw = MailComposer.raw(to: "host@example.org", subject: "Attendee list", body: "Dear Ms Doe,",
                                   attachments: [.init(fileName: "Study Tour Brussels 2027 – Example Ministry.xlsx", mimeType: MailComposer.Attachment.xlsxMime, data: xlsx)])
        let msg = String(decoding: PKCE.b64urlDecode(raw)!, as: UTF8.self)
        XCTAssertTrue(msg.contains("Content-Type: multipart/mixed; boundary="))
        XCTAssertTrue(msg.contains("Content-Disposition: attachment; filename=\"=?UTF-8?B?"))   // non-ASCII file name encoded
        XCTAssertTrue(msg.contains(xlsx.base64EncodedString()))
        XCTAssertTrue(msg.hasSuffix("--"))
    }
}

final class KnowledgeLearningTests: XCTestCase {
    func testFactsFilterPersonalData() {
        let json = #"{"newFacts":["Lunch is included on all visit days.","jane@example.com","Passport C01X00T47 accepted","  "]}"#
        XCTAssertEqual(KnowledgeBase.parseFacts(json), ["Lunch is included on all visit days."])
    }

    func testPromptRedactsAndAppendixFormat() {
        let p = KnowledgeBase.learningPrompt(question: "My passport is C01X00T47 — is lunch included?", answer: "Yes, lunch is included.", knowledgeBase: "Dress code: business")
        XCTAssertFalse(p.prompt.contains("C01X00T47"))
        let a = KnowledgeBase.appendix(facts: ["Lunch is included."], date: Dates.parse("2027-03-01")!)
        XCTAssertTrue(a.contains("Added from email replies (2027-03-01)"))
        XCTAssertTrue(a.contains("• Lunch is included."))
    }
}


final class SalesforceMappingTests: XCTestCase {
    override func tearDown() { SFMap.reload(override: nil) }

    func testDefaultFileMatchesCompiledDefaults() throws {
        let url = SFMap.sourceConfigDir.appendingPathComponent("salesforce-mapping.default.json")
        let file = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let flatFile = SFMap.flatten(file), flatDefaults = SFMap.flatten(SFMap.defaults)
        XCTAssertEqual(Set(flatFile.keys), Set(flatDefaults.keys))
        func norm(_ v: Any?) -> [String] { (v as? [String]) ?? (v as? [Any])?.map { "\($0)" } ?? [(v as? String) ?? ""] }
        for (k, v) in flatDefaults { XCTAssertEqual(norm(flatFile[k]), norm(v), k) }
    }

    func testOverrideForDifferentlyConfiguredOrg() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("map-\(UUID().uuidString).json")
        try #"{"member": {"birthDate": "Date_of_Birth__c", "unknownKey": "x"}, "programMember": {"attendingValue": "Confirmed"},"#
          .appending(#" "task": {"phaseValues": ["Setup", "Outreach", "Program", "Registration", "Lists", "Tour", "Wrap-up"]}}"#)
          .write(to: url, atomically: true, encoding: .utf8)
        SFMap.reload(override: url)
        XCTAssertEqual(ParticipantField.birthDate.defaultSalesforceField, "Date_of_Birth__c")   // overridden
        XCTAssertEqual(ParticipantField.passportNumber.defaultSalesforceField, "Identification_Number__c") // default kept
        XCTAssertEqual(SFMap["programMember.attendingValue"], "Confirmed")
        XCTAssertEqual(PhaseID.submissions.salesforceValue, "Lists")
        XCTAssertEqual(PhaseID(salesforceValue: "Tour"), .tour)
        XCTAssertTrue(SFMap.customFields.contains { $0 == ("Lead", "Date_of_Birth__c") })
        XCTAssertNil(SFMap.values["member.unknownKey"])
    }

    func testCustomFieldsCoverMetadataPackage() {
        let fields = Set(SFMap.customFields.map { "\($0.object).\($0.field)" })
        for f in ["Campaign.Study_Tour_City__c", "Task.Study_Tour_Phase__c", "Opportunity.Visit_Start__c", "Lead.Dietary_Needs__c"] {
            XCTAssertTrue(fields.contains(f), f)
        }
    }
}
