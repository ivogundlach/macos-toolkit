import SwiftUI

struct CoursesView: View {
    let snapshot: Snapshot

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if snapshot.courses.isEmpty {
                    Card(flat: true) {
                        EmptyNote(symbol: "books.vertical",
                                  title: "No courses loaded",
                                  detail: "Course details come from the university registrar. They appear once the term's sections are imported.")
                    }
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 330), spacing: 14)], spacing: 14) {
                        ForEach(snapshot.courses) { course in
                            CourseCard(course: course,
                                       color: Palette.color(for: course.code, in: snapshot.courses))
                        }
                    }
                    termNotes
                }
            }
            .padding(18)
        }
    }

    private var termNotes: some View {
        Card(flat: true) {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Term dates",
                              subtitle: snapshot.term.name,
                              symbol: "calendar.badge.clock",
                              color: Color(red: 0.20, green: 0.55, blue: 0.78))
                VStack(spacing: 0) {
                    if let start = snapshot.term.startDate {
                        DetailRow(label: "Classes begin", value: Format.mediumDate.string(from: start))
                        Divider().padding(.leading, 12)
                    }
                    if let end = snapshot.term.endDate {
                        DetailRow(label: "Last day of classes", value: Format.mediumDate.string(from: end))
                        Divider().padding(.leading, 12)
                    }
                    DetailRow(label: "No-class days",
                              value: snapshot.term.breaks.isEmpty ? "None"
                                : snapshot.term.breaks.compactMap { SchoolDate.day($0) }
                                    .map { Format.monthDay.string(from: $0) }
                                    .joined(separator: ", "))
                    if !snapshot.term.study_days.isEmpty {
                        Divider().padding(.leading, 12)
                        DetailRow(label: "Study days",
                                  value: snapshot.term.study_days.keys.sorted()
                                    .compactMap { SchoolDate.day($0) }
                                    .map { Format.monthDay.string(from: $0) }
                                    .joined(separator: ", "))
                    }
                }
            }
        }
    }
}

struct CourseCard: View {
    let course: Course
    let color: Color

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 9) {
                    IconTile(symbol: "book.fill", color: color, size: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(course.code).font(.system(size: 14, weight: .semibold))
                        Text(course.title)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                    if let credits = course.credits {
                        Pill(text: "\(credits) cr", color: color)
                    }
                }

                if course.meetings.isEmpty {
                    Text("No scheduled meeting times — this course is online or arranged.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(course.meetings.enumerated()), id: \.offset) { _, meeting in
                            HStack(spacing: 7) {
                                Image(systemName: "clock")
                                    .font(.system(size: 10))
                                    .foregroundStyle(color)
                                Text(meeting.dayLabel)
                                    .font(.system(size: 11, weight: .semibold))
                                Text(meeting.timeLabel)
                                    .font(.system(size: 11, design: .rounded))
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: 4)
                            }
                            if let location = meeting.location {
                                HStack(spacing: 7) {
                                    Image(systemName: "mappin.and.ellipse")
                                        .font(.system(size: 10))
                                        .foregroundStyle(color)
                                    Text(location)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                    Spacer(minLength: 4)
                                }
                            }
                        }
                    }
                }

                Divider()

                HStack(spacing: 7) {
                    Image(systemName: "person.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(color)
                    Text(course.instructorName ?? "Instructor not listed")
                        .font(.system(size: 11, weight: .medium))
                    Spacer(minLength: 4)
                    if let email = course.instructor_email,
                       let url = URL(string: "mailto:\(email)") {
                        Link(destination: url) {
                            Image(systemName: "envelope.fill").font(.system(size: 10.5))
                        }
                        .focusEffectDisabled()
                        .help("Email \(email)")
                    }
                }

                HStack(spacing: 6) {
                    if let section = course.section {
                        Text("Section \(section)")
                    }
                    Text("CRN \(course.crn)")
                    if let type = course.schedule_type {
                        Text(type)
                    }
                }
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
            }
        }
    }
}

struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 11.5, weight: .medium))
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
