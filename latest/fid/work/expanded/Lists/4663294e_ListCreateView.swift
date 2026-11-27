import DesignSystem
import EmojiText
import Env
import Models
import NetworkClient
import SwiftUI

@MainActor
public struct ListCreateView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(Theme.self) private var theme
  @Environment(MastodonClient.self) private var client
  @Environment(CurrentAccount.self) private var currentAccount
  @Environment(ToastCenter.self) private var toastCenter

  @__iOXState_f455649a private var title = ""
  @__iOXState_f455649a private var repliesPolicy: Models.List.RepliesPolicy = .list
  @__iOXState_f455649a private var isExclusive: Bool = false
  @__iOXState_f455649a private var isSaving: Bool = false

  public init() {}

  public var body: some View {
    NavigationStack {
      Form {
        Section("lists.edit.settings") {
          TextField("list.edit.title", text: $title)
          Picker(
            "list.edit.repliesPolicy",
            selection: $repliesPolicy
          ) {
            ForEach(Models.List.RepliesPolicy.allCases) { policy in
              Text(policy.title)
                .tag(policy)
            }
          }
          Toggle("list.edit.isExclusive", isOn: $isExclusive)
        }
        .listRowBackground(theme.primaryBackgroundColor)
      }
      .scrollContentBackground(.hidden)
      .background(theme.secondaryBackgroundColor)
      .toolbar {
        CancelToolbarItem()
        ToolbarItem {
          Button(action: createList) {
            if isSaving {
              ProgressView()
            } else {
              Text("lists.create.confirm")
            }
          }
        }
      }
      .navigationTitle(title)
      .navigationBarTitleDisplayMode(.inline)
    }
  }

  private func createList() {
    let client = client
    Task {
      isSaving = true
      defer { isSaving = false }

      do {
        let _: Models.List = try await client.post(
          endpoint: Lists.createList(
            title: title,
            repliesPolicy: repliesPolicy,
            exclusive: isExclusive))
        await currentAccount.fetchLists()
        dismiss()
      } catch {
        toastCenter.show(
          .init(
            title: String(localized: "lists.create"),
            message: error.localizedDescription,
            systemImage: "exclamationmark.triangle.fill",
            tint: .red
          ),
          autoDismissAfter: .seconds(4)
        )
      }
    }
  }
}


public typealias __iOXState_f455649a<Value> = SwiftUI.State<Value>
