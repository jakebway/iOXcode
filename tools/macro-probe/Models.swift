import SwiftUI
import SwiftData

@Model
public class RecentFeedItem {
  @Attribute(.unique)
  public var uri: String
  public var name: String
  public var avatarImageURL: URL? = nil
  public var lastViewedAt: Date

  public init(uri: String, name: String, avatarImageURL: URL?, lastViewedAt: Date) {
    self.uri = uri
    self.name = name
    self.avatarImageURL = avatarImageURL
    self.lastViewedAt = lastViewedAt
  }
}

@Model
final class Trip {
  var title: String = ""
  var days: Int = 1
  var tags: [String] = []
  @Transient var scratch: Int = 0
  @Relationship(deleteRule: .cascade, inverse: \Stop.trip) var stops: [Stop] = []
  init() {}
}

@Model
final class Stop {
  var name: String = ""
  var trip: Trip?
  init() {}
}

