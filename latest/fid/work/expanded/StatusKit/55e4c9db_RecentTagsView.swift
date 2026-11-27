import DesignSystem
import EmojiText
import Foundation
import Models
import SwiftData
import SwiftUI

extension StatusEditor.AutoCompleteView {
  struct RecentTagsView: View {
    @Environment(Theme.self) private var theme

    var store: StatusEditor.EditorStore
    @Binding var isTagSuggestionExpanded: Bool

     var recentTags: [RecentTag] {
    get { _recentTags.wrappedValue }
}
private(set) var _recentTags: SwiftData.Query<[RecentTag].Element, [RecentTag]> = .init(sort: \RecentTag.lastUse, order: .reverse)

    var body: some View {
      ForEach(recentTags) { tag in
        Button {
          withAnimation {
            isTagSuggestionExpanded = false
            store.selectHashtagSuggestion(tag: tag.title)
          }
          tag.lastUse = Date()
        } label: {
          VStack(alignment: .leading) {
            Text("#\(tag.title)")
              .font(.scaledFootnote)
              .fontWeight(.bold)
              .foregroundColor(theme.labelColor)
            Text(tag.formattedDate)
              .font(.scaledFootnote)
              .foregroundStyle(theme.tintColor)
          }
        }
      }
    }
  }
}
