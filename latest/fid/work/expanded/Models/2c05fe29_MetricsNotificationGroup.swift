import Foundation
import SwiftData

public class MetricsNotificationGroup {
    private var _$backingData: any SwiftData.BackingData<MetricsNotificationGroup> = MetricsNotificationGroup.createBackingData()
    public var persistentBackingData: any SwiftData.BackingData<MetricsNotificationGroup> {
        get { return _$backingData }
        set { _$backingData = newValue }
    }
    public static var schemaMetadata: [SwiftData.Schema.PropertyMetadata] {
        return [
            SwiftData.Schema.PropertyMetadata(name: "groupKey", keypath: \MetricsNotificationGroup.groupKey, defaultValue: "", metadata: nil),
            SwiftData.Schema.PropertyMetadata(name: "type", keypath: \MetricsNotificationGroup.type, defaultValue: "", metadata: nil),
            SwiftData.Schema.PropertyMetadata(name: "notificationsCount", keypath: \MetricsNotificationGroup.notificationsCount, defaultValue: 0, metadata: nil),
            SwiftData.Schema.PropertyMetadata(name: "mostRecentNotificationId", keypath: \MetricsNotificationGroup.mostRecentNotificationId, defaultValue: 0, metadata: nil),
            SwiftData.Schema.PropertyMetadata(name: "latestPageNotificationAt", keypath: \MetricsNotificationGroup.latestPageNotificationAt, defaultValue: Date(), metadata: nil),
            SwiftData.Schema.PropertyMetadata(name: "dayStart", keypath: \MetricsNotificationGroup.dayStart, defaultValue: Date(), metadata: nil),
            SwiftData.Schema.PropertyMetadata(name: "statusId", keypath: \MetricsNotificationGroup.statusId, defaultValue: "", metadata: nil),
            SwiftData.Schema.PropertyMetadata(name: "accountId", keypath: \MetricsNotificationGroup.accountId, defaultValue: "", metadata: nil),
            SwiftData.Schema.PropertyMetadata(name: "server", keypath: \MetricsNotificationGroup.server, defaultValue: "", metadata: nil)
        ]
    }
    required public init(backingData: any SwiftData.BackingData<MetricsNotificationGroup>) {
        _groupKey = _SwiftDataNoType()
        _type = _SwiftDataNoType()
        _notificationsCount = _SwiftDataNoType()
        _mostRecentNotificationId = _SwiftDataNoType()
        _latestPageNotificationAt = _SwiftDataNoType()
        _dayStart = _SwiftDataNoType()
        _statusId = _SwiftDataNoType()
        _accountId = _SwiftDataNoType()
        _server = _SwiftDataNoType()
        self.persistentBackingData = backingData
    }
    private let _$observationRegistrar = Observation.ObservationRegistrar()
    internal nonisolated func access<_M>(keyPath: KeyPath<MetricsNotificationGroup, _M>) {
        _$observationRegistrar.access(self, keyPath: keyPath)
    }
    internal nonisolated func withMutation<_M, _MR>(keyPath: KeyPath<MetricsNotificationGroup, _M>, _ mutation: () throws -> _MR) rethrows -> _MR {
        try _$observationRegistrar.withMutation(of: self, keyPath: keyPath, mutation)
    }
    struct _SwiftDataNoType {}

  public var groupKey: String = "" {
    @storageRestrictions(accesses: _$backingData, initializes: _groupKey)
    init(initialValue) {
        _$backingData.setValue(forKey: \.groupKey, to: initialValue)
        _groupKey = _SwiftDataNoType()
    }
    get {
        _$observationRegistrar.access(self, keyPath: \.groupKey)
        return self.getValue(forKey: \.groupKey)
    }
    set {
        _$observationRegistrar.withMutation(of: self, keyPath: \.groupKey) {
            self.setValue(forKey: \.groupKey, to: newValue)
        }
    }
}
private var _groupKey: _SwiftDataNoType = _SwiftDataNoType()
  public var type: String = "" {
    @storageRestrictions(accesses: _$backingData, initializes: _type)
    init(initialValue) {
        _$backingData.setValue(forKey: \.type, to: initialValue)
        _type = _SwiftDataNoType()
    }
    get {
        _$observationRegistrar.access(self, keyPath: \.type)
        return self.getValue(forKey: \.type)
    }
    set {
        _$observationRegistrar.withMutation(of: self, keyPath: \.type) {
            self.setValue(forKey: \.type, to: newValue)
        }
    }
}
private var _type: _SwiftDataNoType = _SwiftDataNoType()
  public var notificationsCount: Int = 0 {
    @storageRestrictions(accesses: _$backingData, initializes: _notificationsCount)
    init(initialValue) {
        _$backingData.setValue(forKey: \.notificationsCount, to: initialValue)
        _notificationsCount = _SwiftDataNoType()
    }
    get {
        _$observationRegistrar.access(self, keyPath: \.notificationsCount)
        return self.getValue(forKey: \.notificationsCount)
    }
    set {
        _$observationRegistrar.withMutation(of: self, keyPath: \.notificationsCount) {
            self.setValue(forKey: \.notificationsCount, to: newValue)
        }
    }
}
private var _notificationsCount: _SwiftDataNoType = _SwiftDataNoType()
  public var mostRecentNotificationId: Int = 0 {
    @storageRestrictions(accesses: _$backingData, initializes: _mostRecentNotificationId)
    init(initialValue) {
        _$backingData.setValue(forKey: \.mostRecentNotificationId, to: initialValue)
        _mostRecentNotificationId = _SwiftDataNoType()
    }
    get {
        _$observationRegistrar.access(self, keyPath: \.mostRecentNotificationId)
        return self.getValue(forKey: \.mostRecentNotificationId)
    }
    set {
        _$observationRegistrar.withMutation(of: self, keyPath: \.mostRecentNotificationId) {
            self.setValue(forKey: \.mostRecentNotificationId, to: newValue)
        }
    }
}
private var _mostRecentNotificationId: _SwiftDataNoType = _SwiftDataNoType()
  public var latestPageNotificationAt: Date = Date() {
    @storageRestrictions(accesses: _$backingData, initializes: _latestPageNotificationAt)
    init(initialValue) {
        _$backingData.setValue(forKey: \.latestPageNotificationAt, to: initialValue)
        _latestPageNotificationAt = _SwiftDataNoType()
    }
    get {
        _$observationRegistrar.access(self, keyPath: \.latestPageNotificationAt)
        return self.getValue(forKey: \.latestPageNotificationAt)
    }
    set {
        _$observationRegistrar.withMutation(of: self, keyPath: \.latestPageNotificationAt) {
            self.setValue(forKey: \.latestPageNotificationAt, to: newValue)
        }
    }
}
private var _latestPageNotificationAt: _SwiftDataNoType = _SwiftDataNoType()
  public var dayStart: Date = Date() {
    @storageRestrictions(accesses: _$backingData, initializes: _dayStart)
    init(initialValue) {
        _$backingData.setValue(forKey: \.dayStart, to: initialValue)
        _dayStart = _SwiftDataNoType()
    }
    get {
        _$observationRegistrar.access(self, keyPath: \.dayStart)
        return self.getValue(forKey: \.dayStart)
    }
    set {
        _$observationRegistrar.withMutation(of: self, keyPath: \.dayStart) {
            self.setValue(forKey: \.dayStart, to: newValue)
        }
    }
}
private var _dayStart: _SwiftDataNoType = _SwiftDataNoType()
  public var statusId: String = "" {
    @storageRestrictions(accesses: _$backingData, initializes: _statusId)
    init(initialValue) {
        _$backingData.setValue(forKey: \.statusId, to: initialValue)
        _statusId = _SwiftDataNoType()
    }
    get {
        _$observationRegistrar.access(self, keyPath: \.statusId)
        return self.getValue(forKey: \.statusId)
    }
    set {
        _$observationRegistrar.withMutation(of: self, keyPath: \.statusId) {
            self.setValue(forKey: \.statusId, to: newValue)
        }
    }
}
private var _statusId: _SwiftDataNoType = _SwiftDataNoType()
  public var accountId: String = "" {
    @storageRestrictions(accesses: _$backingData, initializes: _accountId)
    init(initialValue) {
        _$backingData.setValue(forKey: \.accountId, to: initialValue)
        _accountId = _SwiftDataNoType()
    }
    get {
        _$observationRegistrar.access(self, keyPath: \.accountId)
        return self.getValue(forKey: \.accountId)
    }
    set {
        _$observationRegistrar.withMutation(of: self, keyPath: \.accountId) {
            self.setValue(forKey: \.accountId, to: newValue)
        }
    }
}
private var _accountId: _SwiftDataNoType = _SwiftDataNoType()
  public var server: String = "" {
    @storageRestrictions(accesses: _$backingData, initializes: _server)
    init(initialValue) {
        _$backingData.setValue(forKey: \.server, to: initialValue)
        _server = _SwiftDataNoType()
    }
    get {
        _$observationRegistrar.access(self, keyPath: \.server)
        return self.getValue(forKey: \.server)
    }
    set {
        _$observationRegistrar.withMutation(of: self, keyPath: \.server) {
            self.setValue(forKey: \.server, to: newValue)
        }
    }
}
private var _server: _SwiftDataNoType = _SwiftDataNoType()

  public init(
    groupKey: String,
    type: String,
    notificationsCount: Int,
    mostRecentNotificationId: Int,
    latestPageNotificationAt: Date,
    dayStart: Date,
    statusId: String,
    accountId: String,
    server: String
  ) {
    self.groupKey = groupKey
    self.type = type
    self.notificationsCount = notificationsCount
    self.mostRecentNotificationId = mostRecentNotificationId
    self.latestPageNotificationAt = latestPageNotificationAt
    self.dayStart = dayStart
    self.statusId = statusId
    self.accountId = accountId
    self.server = server
  }
}

extension MetricsNotificationGroup: SwiftData.PersistentModel {}
extension MetricsNotificationGroup: Observation.Observable {}
@available(*, unavailable, message: "PersistentModels are not Sendable, consider utilizing a ModelActor or use MetricsNotificationGroup's persistentModelID instead")
extension MetricsNotificationGroup: Sendable {}

