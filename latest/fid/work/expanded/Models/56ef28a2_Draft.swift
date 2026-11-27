import Foundation
import SwiftData
import SwiftUI

public class Draft {
    private var _$backingData: any SwiftData.BackingData<Draft> = Draft.createBackingData()
    public var persistentBackingData: any SwiftData.BackingData<Draft> {
        get { return _$backingData }
        set { _$backingData = newValue }
    }
    public static var schemaMetadata: [SwiftData.Schema.PropertyMetadata] {
        return [
            SwiftData.Schema.PropertyMetadata(name: "content", keypath: \Draft.content, defaultValue: "", metadata: nil),
            SwiftData.Schema.PropertyMetadata(name: "creationDate", keypath: \Draft.creationDate, defaultValue: Date(), metadata: nil)
        ]
    }
    required public init(backingData: any SwiftData.BackingData<Draft>) {
        _content = _SwiftDataNoType()
        _creationDate = _SwiftDataNoType()
        self.persistentBackingData = backingData
    }
    private let _$observationRegistrar = Observation.ObservationRegistrar()
    internal nonisolated func access<_M>(keyPath: KeyPath<Draft, _M>) {
        _$observationRegistrar.access(self, keyPath: keyPath)
    }
    internal nonisolated func withMutation<_M, _MR>(keyPath: KeyPath<Draft, _M>, _ mutation: () throws -> _MR) rethrows -> _MR {
        try _$observationRegistrar.withMutation(of: self, keyPath: keyPath, mutation)
    }
    struct _SwiftDataNoType {}

  public var content: String = "" {
    @storageRestrictions(accesses: _$backingData, initializes: _content)
    init(initialValue) {
        _$backingData.setValue(forKey: \.content, to: initialValue)
        _content = _SwiftDataNoType()
    }
    get {
        _$observationRegistrar.access(self, keyPath: \.content)
        return self.getValue(forKey: \.content)
    }
    set {
        _$observationRegistrar.withMutation(of: self, keyPath: \.content) {
            self.setValue(forKey: \.content, to: newValue)
        }
    }
}
private var _content: _SwiftDataNoType = _SwiftDataNoType()
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

  public init(content: String) {
    self.content = content
    creationDate = Date()
  }
}

extension Draft: SwiftData.PersistentModel {}
extension Draft: Observation.Observable {}
@available(*, unavailable, message: "PersistentModels are not Sendable, consider utilizing a ModelActor or use Draft's persistentModelID instead")
extension Draft: Sendable {}

