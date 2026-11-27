import SwiftUI

public struct PlaceholderView: View {
  public let iconName: String
  public let title: LocalizedStringKey
  public let message: LocalizedStringKey

  public init(iconName: String, title: LocalizedStringKey, message: LocalizedStringKey) {
    self.iconName = iconName
    self.title = title
    self.message = message
  }

  public var body: some View {
    ContentUnavailableView(
      title,
      systemImage: iconName,
      description: Text(message))
  }
}


