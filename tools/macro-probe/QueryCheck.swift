import SwiftUI
import SwiftData

@Model
final class Note {
  var title: String = ""
  var created: Date = Date()
  init() {}
}

struct NoteList: View {
  @Query(sort: \Note.title, order: .reverse) private var notes: [Note]
  @Query(Self.descriptor) var recent: [Note]
  @Query var all: [Note]

  static var descriptor: FetchDescriptor<Note> {
    var d = FetchDescriptor<Note>(sortBy: [SortDescriptor(\.created, order: .reverse)])
    d.fetchLimit = 4
    return d
  }

  var body: some View { Text("\(notes.count) \(recent.count) \(all.count)") }
}
