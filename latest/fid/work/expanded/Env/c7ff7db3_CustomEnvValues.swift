import Foundation
import SwiftUI

extension EnvironmentValues {
  public var isSecondaryColumn: Bool  {
    get { self[__Key_isSecondaryColumn.self] }
    set { self[__Key_isSecondaryColumn.self] = newValue }
}
private struct __Key_isSecondaryColumn: SwiftUI.EnvironmentKey {
    static var defaultValue: Bool { false }
}
  public var extraLeadingInset: CGFloat  {
    get { self[__Key_extraLeadingInset.self] }
    set { self[__Key_extraLeadingInset.self] = newValue }
}
private struct __Key_extraLeadingInset: SwiftUI.EnvironmentKey {
    static var defaultValue: CGFloat { 0 }
}
  public var isCompact: Bool  {
    get { self[__Key_isCompact.self] }
    set { self[__Key_isCompact.self] = newValue }
}
private struct __Key_isCompact: SwiftUI.EnvironmentKey {
    static var defaultValue: Bool { false }
}
  public var isMediaCompact: Bool  {
    get { self[__Key_isMediaCompact.self] }
    set { self[__Key_isMediaCompact.self] = newValue }
}
private struct __Key_isMediaCompact: SwiftUI.EnvironmentKey {
    static var defaultValue: Bool { false }
}
  public var isCatalystWindow: Bool  {
    get { self[__Key_isCatalystWindow.self] }
    set { self[__Key_isCatalystWindow.self] = newValue }
}
private struct __Key_isCatalystWindow: SwiftUI.EnvironmentKey {
    static var defaultValue: Bool { false }
}
  public var isModal: Bool  {
    get { self[__Key_isModal.self] }
    set { self[__Key_isModal.self] = newValue }
}
private struct __Key_isModal: SwiftUI.EnvironmentKey {
    static var defaultValue: Bool { false }
}
  public var isInCaptureMode: Bool  {
    get { self[__Key_isInCaptureMode.self] }
    set { self[__Key_isInCaptureMode.self] = newValue }
}
private struct __Key_isInCaptureMode: SwiftUI.EnvironmentKey {
    static var defaultValue: Bool { false }
}
  public var isSupporter: Bool  {
    get { self[__Key_isSupporter.self] }
    set { self[__Key_isSupporter.self] = newValue }
}
private struct __Key_isSupporter: SwiftUI.EnvironmentKey {
    static var defaultValue: Bool { false }
}
  public var isStatusFocused: Bool  {
    get { self[__Key_isStatusFocused.self] }
    set { self[__Key_isStatusFocused.self] = newValue }
}
private struct __Key_isStatusFocused: SwiftUI.EnvironmentKey {
    static var defaultValue: Bool { false }
}
  public var isHomeTimeline: Bool  {
    get { self[__Key_isHomeTimeline.self] }
    set { self[__Key_isHomeTimeline.self] = newValue }
}
private struct __Key_isHomeTimeline: SwiftUI.EnvironmentKey {
    static var defaultValue: Bool { false }
}
  public var indentationLevel: UInt  {
    get { self[__Key_indentationLevel.self] }
    set { self[__Key_indentationLevel.self] = newValue }
}
private struct __Key_indentationLevel: SwiftUI.EnvironmentKey {
    static var defaultValue: UInt { 0 }
}
  public var selectedTabScrollToTop: Int  {
    get { self[__Key_selectedTabScrollToTop.self] }
    set { self[__Key_selectedTabScrollToTop.self] = newValue }
}
private struct __Key_selectedTabScrollToTop: SwiftUI.EnvironmentKey {
    static var defaultValue: Int { -1 }
}
  // Set to true when rendering inside the Notifications tab
  public var isNotificationsTab: Bool  {
    get { self[__Key_isNotificationsTab.self] }
    set { self[__Key_isNotificationsTab.self] = newValue }
}
private struct __Key_isNotificationsTab: SwiftUI.EnvironmentKey {
    static var defaultValue: Bool { false }
}
}
