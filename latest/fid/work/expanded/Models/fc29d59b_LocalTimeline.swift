import Foundation
import SwiftData
import SwiftUI

public class LocalTimeline {
    private var _$backingData: any SwiftData.BackingData<LocalTimeline> = LocalTimeline.createBackingData()
    public var persistentBackingData: any SwiftData.BackingData<LocalTimeline> {
        get { return _$backingData }
        set { _$backingData = newValue }
    }
    public static var schemaMetadata: [SwiftData.Schema.PropertyMetadata] {
        return [
            SwiftData.Schema.PropertyMetadata(name: "instance", keypath: \LocalTimeline.instance, defaultValue: "", metadata: nil),
            SwiftData.Schema.PropertyMetadata(name: "creationDate", keypath: \LocalTimeline.creationDate, defaultValue: Date(), metadata: nil)
        ]
    }
    required public init(backingData: any SwiftData.BackingData<LocalTimeline>) {
        _instance = _SwiftDataNoType()
        _creationDate = _SwiftDataNoType()
        self.persistentBackingData = backingData
    }
    private let _$observationRegistrar = Observation.ObservationRegistrar()
    internal nonisolated func access<_M>(keyPath: KeyPath<LocalTimeline, _M>) {
        _$observationRegistrar.access(self, keyPath: keyPath)
    }
    internal nonisolated func withMutation<_M, _MR>(keyPath: KeyPath<LocalTimeline, _M>, _ mutation: () throws -> _MR) rethrows -> _MR {
        try _$observationRegistrar.withMutation(of: self, keyPath: keyPath, mutation)
    }
    struct _SwiftDataNoType {}

  public var instance: String = "" {
    @storageRestrictions(accesses: _$backingData, initializes: _instance)
    init(initialValue) {
        _$backingData.setValue(forKey: \.instance, to: initialValue)
        _instance = _SwiftDataNoType()
    }
    get {
        _$observationRegistrar.access(self, keyPath: \.instance)
        return self.getValue(forKey: \.instance)
    }
    set {
        _$observationRegistrar.withMutation(of: self, keyPath: \.instance) {
            self.setValue(forKey: \.instance, to: newValue)
        }
    }
}
private var _instance: _SwiftDataNoType = _SwiftDataNoType()
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

  public init(instance: String) {
    self.instance = instance
    creationDate = Date()
  }
}

extension LocalTimeline: SwiftData.PersistentModel {}
extension LocalTimeline: Observation.Observable {}
@available(*, unavailable, message: "PersistentModels are not Sendable, consider utilizing a ModelActor or use LocalTimeline's persistentModelID instead")
extension LocalTimeline: Sendable {}

