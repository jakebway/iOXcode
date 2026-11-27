import Foundation
import Models
import SwiftData

struct AccountMetricsStore {
  @MainActor
  func upsert(
    groups: [NotificationGroup],
    accountId: String,
    server: String,
    modelContext: ModelContext
  ) {
    let calendar = Calendar.current
    let allowedTypes = Set(MetricType.allCases.map(\.rawValue)).union(["quote"])

    for group in groups where allowedTypes.contains(group.type) {
      let storageKey = metricsGroupKey(
        groupKey: group.groupKey,
        accountId: accountId,
        server: server
      )
      let dayStart = calendar.startOfDay(for: group.latestPageNotificationAt.asDate)

      var descriptor = FetchDescriptor<MetricsNotificationGroup>(
        predicate: Foundation.Predicate({ 
PredicateExpressions.build_Conjunction(lhs: PredicateExpressions.build_Conjunction(lhs: PredicateExpressions.build_Equal(lhs: PredicateExpressions.build_KeyPath(root: PredicateExpressions.build_Arg($0), keyPath: \.groupKey), rhs: PredicateExpressions.build_Arg(storageKey)), rhs: PredicateExpressions.build_Equal(lhs: PredicateExpressions.build_KeyPath(root: PredicateExpressions.build_Arg($0), keyPath: \.accountId), rhs: PredicateExpressions.build_Arg(accountId))), rhs: PredicateExpressions.build_Equal(lhs: PredicateExpressions.build_KeyPath(root: PredicateExpressions.build_Arg($0), keyPath: \.server), rhs: PredicateExpressions.build_Arg(server)))
})
      )
      descriptor.fetchLimit = 1

      if let existing = try? modelContext.fetch(descriptor).first {
        existing.notificationsCount = group.notificationsCount
        existing.mostRecentNotificationId = group.mostRecentNotificationId
        existing.latestPageNotificationAt = group.latestPageNotificationAt.asDate
        existing.dayStart = dayStart
        existing.type = group.type
        existing.statusId = group.statusId ?? ""
      } else {
        let newGroup = MetricsNotificationGroup(
          groupKey: storageKey,
          type: group.type,
          notificationsCount: group.notificationsCount,
          mostRecentNotificationId: group.mostRecentNotificationId,
          latestPageNotificationAt: group.latestPageNotificationAt.asDate,
          dayStart: dayStart,
          statusId: group.statusId ?? "",
          accountId: accountId,
          server: server
        )
        modelContext.insert(newGroup)
      }
    }
  }

  @MainActor
  func pruneOldGroups(
    accountId: String,
    server: String,
    keepingDays: Int,
    modelContext: ModelContext
  ) {
    let calendar = Calendar.current
    let cutoff = calendar.date(byAdding: .day, value: -keepingDays, to: Date()) ?? Date()
    let descriptor = FetchDescriptor<MetricsNotificationGroup>(
      predicate: Foundation.Predicate({ 
PredicateExpressions.build_Conjunction(lhs: PredicateExpressions.build_Conjunction(lhs: PredicateExpressions.build_Equal(lhs: PredicateExpressions.build_KeyPath(root: PredicateExpressions.build_Arg($0), keyPath: \.accountId), rhs: PredicateExpressions.build_Arg(accountId)), rhs: PredicateExpressions.build_Equal(lhs: PredicateExpressions.build_KeyPath(root: PredicateExpressions.build_Arg($0), keyPath: \.server), rhs: PredicateExpressions.build_Arg(server))), rhs: PredicateExpressions.build_Comparison(lhs: PredicateExpressions.build_KeyPath(root: PredicateExpressions.build_Arg($0), keyPath: \.latestPageNotificationAt), rhs: PredicateExpressions.build_Arg(cutoff), op: .lessThan))
})
    )
    let groups = (try? modelContext.fetch(descriptor)) ?? []
    groups.forEach { modelContext.delete($0) }
  }

  func latestStoredNotificationId(
    accountId: String,
    server: String,
    modelContext: ModelContext
  ) -> Int? {
    var descriptor = FetchDescriptor<MetricsNotificationGroup>(
      predicate: Foundation.Predicate({ 
PredicateExpressions.build_Conjunction(lhs: PredicateExpressions.build_Equal(lhs: PredicateExpressions.build_KeyPath(root: PredicateExpressions.build_Arg($0), keyPath: \.accountId), rhs: PredicateExpressions.build_Arg(accountId)), rhs: PredicateExpressions.build_Equal(lhs: PredicateExpressions.build_KeyPath(root: PredicateExpressions.build_Arg($0), keyPath: \.server), rhs: PredicateExpressions.build_Arg(server)))
}),
      sortBy: [SortDescriptor(\.mostRecentNotificationId, order: .reverse)]
    )
    descriptor.fetchLimit = 1
    return try? modelContext.fetch(descriptor).first?.mostRecentNotificationId
  }

  func oldestStoredNotificationId(
    accountId: String,
    server: String,
    modelContext: ModelContext
  ) -> Int? {
    var descriptor = FetchDescriptor<MetricsNotificationGroup>(
      predicate: Foundation.Predicate({ 
PredicateExpressions.build_Conjunction(lhs: PredicateExpressions.build_Equal(lhs: PredicateExpressions.build_KeyPath(root: PredicateExpressions.build_Arg($0), keyPath: \.accountId), rhs: PredicateExpressions.build_Arg(accountId)), rhs: PredicateExpressions.build_Equal(lhs: PredicateExpressions.build_KeyPath(root: PredicateExpressions.build_Arg($0), keyPath: \.server), rhs: PredicateExpressions.build_Arg(server)))
}),
      sortBy: [SortDescriptor(\.mostRecentNotificationId, order: .forward)]
    )
    descriptor.fetchLimit = 1
    return try? modelContext.fetch(descriptor).first?.mostRecentNotificationId
  }

  func earliestStoredDayStart(
    accountId: String,
    server: String,
    modelContext: ModelContext
  ) -> Date? {
    var descriptor = FetchDescriptor<MetricsNotificationGroup>(
      predicate: Foundation.Predicate({ 
PredicateExpressions.build_Conjunction(lhs: PredicateExpressions.build_Equal(lhs: PredicateExpressions.build_KeyPath(root: PredicateExpressions.build_Arg($0), keyPath: \.accountId), rhs: PredicateExpressions.build_Arg(accountId)), rhs: PredicateExpressions.build_Equal(lhs: PredicateExpressions.build_KeyPath(root: PredicateExpressions.build_Arg($0), keyPath: \.server), rhs: PredicateExpressions.build_Arg(server)))
}),
      sortBy: [SortDescriptor(\.dayStart, order: .forward)]
    )
    descriptor.fetchLimit = 1
    return try? modelContext.fetch(descriptor).first?.dayStart
  }

  private func metricsGroupKey(groupKey: String, accountId: String, server: String) -> String {
    "\(server)|\(accountId)|\(groupKey)"
  }
}
