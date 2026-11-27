import Foundation
import SwiftData
import SwiftUI

public class TagGroup: Equatable {
    private var _$backingData: any SwiftData.BackingData<TagGroup> = TagGroup.createBackingData()
    public var persistentBackingData: any SwiftData.BackingData<TagGroup> {
        get { return _$backingData }
        set { _$backingData = newValue }
    }
    public static var schemaMetadata: [SwiftData.Schema.PropertyMetadata] {
        return [
            SwiftData.Schema.PropertyMetadata(name: "title", keypath: \TagGroup.title, defaultValue: "", metadata: nil),
            SwiftData.Schema.PropertyMetadata(name: "symbolName", keypath: \TagGroup.symbolName, defaultValue: "", metadata: nil),
            SwiftData.Schema.PropertyMetadata(name: "tags", keypath: \TagGroup.tags, defaultValue: [], metadata: nil),
            SwiftData.Schema.PropertyMetadata(name: "creationDate", keypath: \TagGroup.creationDate, defaultValue: Date(), metadata: nil)
        ]
    }
    required public init(backingData: any SwiftData.BackingData<TagGroup>) {
        _title = _SwiftDataNoType()
        _symbolName = _SwiftDataNoType()
        _tags = _SwiftDataNoType()
        _creationDate = _SwiftDataNoType()
        self.persistentBackingData = backingData
    }
    private let _$observationRegistrar = Observation.ObservationRegistrar()
    internal nonisolated func access<_M>(keyPath: KeyPath<TagGroup, _M>) {
        _$observationRegistrar.access(self, keyPath: keyPath)
    }
    internal nonisolated func withMutation<_M, _MR>(keyPath: KeyPath<TagGroup, _M>, _ mutation: () throws -> _MR) rethrows -> _MR {
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
  public var symbolName: String = "" {
    @storageRestrictions(accesses: _$backingData, initializes: _symbolName)
    init(initialValue) {
        _$backingData.setValue(forKey: \.symbolName, to: initialValue)
        _symbolName = _SwiftDataNoType()
    }
    get {
        _$observationRegistrar.access(self, keyPath: \.symbolName)
        return self.getValue(forKey: \.symbolName)
    }
    set {
        _$observationRegistrar.withMutation(of: self, keyPath: \.symbolName) {
            self.setValue(forKey: \.symbolName, to: newValue)
        }
    }
}
private var _symbolName: _SwiftDataNoType = _SwiftDataNoType()
  public var tags: [String] = [] {
    @storageRestrictions(accesses: _$backingData, initializes: _tags)
    init(initialValue) {
        _$backingData.setValue(forKey: \.tags, to: initialValue)
        _tags = _SwiftDataNoType()
    }
    get {
        _$observationRegistrar.access(self, keyPath: \.tags)
        return self.getValue(forKey: \.tags)
    }
    set {
        _$observationRegistrar.withMutation(of: self, keyPath: \.tags) {
            self.setValue(forKey: \.tags, to: newValue)
        }
    }
}
private var _tags: _SwiftDataNoType = _SwiftDataNoType()
  public var creationDate: Date = Date() {
    @storageRestrictions(accesses: _$backingData, initializes: _creationDate)
    init(initialValue) {
        _$backingData.setValue(forKey: \.creationDate, to: initialValue)
        _creationDate = _SwiftDataNoType()
    }
    get {
        _$observationRegistrar.access(self, keyPath: \.creationDate)
        return self.getValue(forKey: \.creationDate)
    }
    set {
        _$observationRegistrar.withMutation(of: self, keyPath: \.creationDate) {
            self.setValue(forKey: \.creationDate, to: newValue)
        }
    }
}
private var _creationDate: _SwiftDataNoType = _SwiftDataNoType()

  public init(title: String, symbolName: String, tags: [String]) {
    self.title = title
    self.symbolName = symbolName
    self.tags = tags
    creationDate = Date()
  }
}

extension TagGroup: SwiftData.PersistentModel {}
extension TagGroup: Observation.Observable {}
@available(*, unavailable, message: "PersistentModels are not Sendable, consider utilizing a ModelActor or use TagGroup's persistentModelID instead")
extension TagGroup: Sendable {}

