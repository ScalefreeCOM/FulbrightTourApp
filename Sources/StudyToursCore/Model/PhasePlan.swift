import Foundation

/// Default task plan, derived from the team's original process sheet and
/// converted to deadlines relative to the tour start (wrap-up: relative to tour end).
public enum PhasePlan {
    public static func defaultTasks() -> [TaskItem] {
        func t(_ p: PhaseID, _ title: String, _ role: String, _ offset: Int) -> TaskItem {
            TaskItem(phase: p, title: title, role: role, offsetDays: offset)
        }
        return [
            // 0 Setup
            t(.setup, "Create program, set dates and city", "Coordination", -110),
            t(.setup, "Create tour folder and agenda (shared Drive)", "Coordination", -110),
            t(.setup, "Link Salesforce program (campaign) for registrations", "Coordination", -105),
            t(.setup, "Book kick-off team meeting (calendar)", "Coordination", -105),

            // 1 Host outreach
            t(.outreach, "Select host institutions and contacts (Salesforce Accounts)", "Contacts", -100),
            t(.outreach, "Send invitation letters", "Letter", -92),
            t(.outreach, "Follow up on unanswered letters", "Contacts", -80),
            t(.outreach, "Record each host's data requirements and submission deadline", "Contacts", -75),
            t(.outreach, "All visits confirmed and in the calendar", "Lead", -62),

            // 2 Program & promotion
            t(.program, "Tentative agenda and flyer", "Marketing", -77),
            t(.program, "First marketing wave", "Marketing", -76),
            t(.program, "Final agenda (agenda doc published)", "Lead", -60),
            t(.program, "Second marketing wave", "Marketing", -59),
            t(.program, "Fill FAQ / knowledge base for the email assistant", "Coordination", -60),

            // 3 Registration
            t(.registration, "Open registration", "Registrations", -76),
            t(.registration, "Weekly cleansing run (duplicates, formats)", "Registrations", -55),
            t(.registration, "Passport check and follow-up of missing/expiring documents", "Registrations", -40),
            t(.registration, "Close registration", "Registrations", -32),

            // 4 Submissions & logistics
            t(.submissions, "Final cleansing and duplicate check", "Registrations", -31),
            t(.submissions, "Export and submit participant lists to each host", "Registrations", -28),
            t(.submissions, "Book restaurants", "Restaurants", -30),
            t(.submissions, "Book city tour", "City Tour", -30),
            t(.submissions, "Final briefing email to participants", "Coordination", -7),

            // 5 Tour days
            t(.tour, "Print attendance and emergency contact lists", "Coordination", -1),
            t(.tour, "Collect photos", "Media", 0),

            // 6 Wrap-up (relative to tour end)
            t(.wrapup, "Thank-you emails to officials (own program)", "Letter", 5),
            t(.wrapup, "Publish report and photos", "Media", 14),
            t(.wrapup, "Scrub passport data (Salesforce + exports)", "Data Protection", 14),
            t(.wrapup, "Lessons learned / update this plan", "Lead", 21),
        ]
    }
}
