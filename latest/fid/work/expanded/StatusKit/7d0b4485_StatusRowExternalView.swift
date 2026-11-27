import SwiftUI

public struct StatusRowExternalView: View {
  @__iOXState_95a0a38a private var viewModel: StatusRowViewModel
  private let context: StatusRowView.Context

  public init(viewModel: StatusRowViewModel, context: StatusRowView.Context = .timeline) {
    _viewModel = .init(initialValue: viewModel)
    self.context = context
  }

  public var body: some View {
    StatusRowView(viewModel: viewModel, context: context)
  }
}


public typealias __iOXState_95a0a38a<Value> = SwiftUI.State<Value>
