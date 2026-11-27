import Foundation
import SwiftData
import SwiftUI

public class RecentTag: Equatable {
    private var _$backingData: any SwiftData.BackingData<RecentTag> = RecentTag.createBackingData()
    public var persistentBackingData: any SwiftData.BackingData<RecentTag> {
        get { return _$backingData }
        set { _$backingData = newValue }
    }
    public static var schemaMetadata: [SwiftData.Schema.PropertyMetadata] {
        return [
            SwiftData.Schema.PropertyMetadata(name: "title", keypath: \RecentTag.title, defaultValue: "", metadata: nil),
            SwiftData.Schema.PropertyMetadata(name: "lastUse", keypath: \RecentTag.lastUse, defaultValue: Date(), metadata: nil)
        ]
    }
    required public init(backingData: any SwiftData.BackingData<RecentTag>) {
        _title = _SwiftDataNoType()
        _lastUse = _SwiftDataNoType()
        self.persistentBackingData = backingData
    }
    private let _$observationRegistrar = Observation.ObservationRegistrar()
    internal nonisolated func access<_M>(keyPath: KeyPath<RecentTag, _M>) {
        _$observationRegistrar.access(self, keyPath: keyPath)
    }
    internal nonisolated func withMutation<_M, _MR>(keyPath: KeyPath<RecentTag, _M>, _ mutation: () throws -> _MR) rethrows -> _MR {
        try _$observationRegistrar.withMutation(of: self, keyPath: keyPath, mutation)
    }
    struct _SwiftDataNoType {}

  public var title: String = "" {
    @storageRestrictions(accesses: _$backingData, initializes: _title)
    init(initialValue) {
        _$backingData.setValue(forKey: \.title, to: initialValue)
        _title = _SwiftDataNoType()
    }
    get {
        _$observationRegistrar.access(self, keyPath: \.title)
        return self.getValue(forKey: \.title)
    }
    set {
        _$observationRegistrar.withMutation(of: self, keyPath: \.title) {
            self.setValue(forKey: \.title, to: newValue)
        }
    }
}
private var _title: _SwiftDataNoType = _SwiftDataNoType()
  public var lastUse: Date = Date() {
    @storageRestrictions(accesses: _$backingData, initializes: _lastUse)
    init(initialValue) {
        _$backingData.setValue(forKey: \.lastUse, to: initialValue)
        _lastUse = _SwiftDataNoType()
    }
    get {
        _$observationRegistrar.access(self, keyPath: \.lastUse)
        return self.getValue(forKey: \.lastUse)
    }
    set {
        _$observationRegistrar.withMutation(of: self, keyPath: \.lastUse) {
            self.setValue(forKey: \.lastUse, to: newValue)
        }
    }
}
private var _lastUse: _SwiftDataNoType = _SwiftDataNoType()

  public init(title: String) {
    self.title = title
    self.lastUse = Date()
  }
}

extension RecentTag: SwiftData.PersistentModel {}
extension RecentTag: Observation.Observable {}
@available(*, unavailable, message: "PersistentModels are not Sendable, consider utilizing a ModelActor or use RecentTag's persistentModelID instead")
extension RecentTag: Sendable {}


extension RecentTag {
  public var formattedDate: String {
    DateFormatterCache.shared.createdAtRelativeFormatter.localizedString(
      for: lastUse, relativeTo: Date())
  }
}
