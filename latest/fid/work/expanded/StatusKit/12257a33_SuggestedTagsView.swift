import DesignSystem
import EmojiText
import Foundation
import Models
import SwiftData
import SwiftUI

extension StatusEditor.AutoCompleteView {
  @available(iOS 26.0, *)
  struct SuggestedTagsView: View {
    enum ViewState {
      case loading, loaded(tags: [String]), error
    }
    
    @Environment(\.modelContext) private var context
    @Environment(Theme.self) private var theme
    
    private let assistant = StatusEditor.Assistant()
    
    var store: StatusEditor.EditorStore
    @Binding var isTagSuggestionExpanded: Bool
    
    @__iOXState_d3dee5ae var viewState: ViewState = .loading
    
     var recentTags: [RecentTag] {
    get { _recentTags.wrappedValue }
}
private(set) var _recentTags: SwiftData.Query<[RecentTag].Element, [RecentTag]> = .init(sort: \RecentTag.lastUse, order: .reverse)

    var body: some View {
      switch viewState {
      case .loading:
        ProgressView()
          .task {
            viewState = .loaded(tags: await assistant.generateTags(from: store.statusText.string).values)
          }
      case .loaded(let tags):
        ForEach(tags, id: \.self ) { tag in
          Button {
            withAnimation {
              isTagSuggestionExpanded = false
              store.selectHashtagSuggestion(tag: tag)
            }
            
            if let index = recentTags.firstIndex(where: {
              $0.title.lowercased() == tag.lowercased()
            }) {
              recentTags[index].lastUse = Date()
            } else {
              var tag = tag
              if tag.first == "#" {
                tag.removeFirst()
              }
              context.insert(RecentTag(title: tag))
            }
          } label: {
            Text(tag)
              .font(.scaledFootnote)
              .fontWeight(.bold)
              .foregroundColor(theme.labelColor)
          }
        }
      case .error:
        EmptyView()
      }
    }
  }
}


public typealias __iOXState_d3dee5ae<Value> = SwiftUI.State<Value>
