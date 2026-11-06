import SwiftUI

protocol TabType {}
struct K: Hashable { var a = 1 }

extension EnvironmentValues {
  @Entry public var currentTab: (any TabType)? = nil
  @Entry var plain: Int = 5
  @Entry var name: String = "x"
  @Entry var optionalNoDefault: Int?
  @Entry public var key: K = K()
}

extension FocusedValues {
  @Entry var focusedThing: String?
}

extension Transaction {
  @Entry var customFlag: Bool = false
}

extension ContainerValues {
  @Entry var rowStyle: Int = 0
}

struct V: View {
  @Previewable @State var n = 1
  var body: some View { Text("\(n)") }
}
