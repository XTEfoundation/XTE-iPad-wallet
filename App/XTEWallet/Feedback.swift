// Copyright (c) 2026, TRRXITTE Int., incorporate. Licensed under AGPL-3.0.
//
// Subtle interaction feedback: haptics (sensoryFeedback on iOS 17+, UIFeedbackGenerator
// before), spring animations on selection/toggle changes and a symbol bounce on
// confirmations. Motion is skipped when Reduce Motion is on.

import SwiftUI
import UIKit

enum HapticKind { case selection, light, success, warning }

enum Haptics {
    static func play(_ kind: HapticKind) {
        switch kind {
        case .selection: UISelectionFeedbackGenerator().selectionChanged()
        case .light: UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .success: UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .warning: UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
    }
}

private struct FeedbackOnChange<V: Equatable>: ViewModifier {
    let value: V
    let kind: HapticKind
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        Group {
            if #available(iOS 17.0, *) {
                content.sensoryFeedback(trigger: value) { _, _ in
                    switch kind {
                    case .selection: return .selection
                    case .light: return .impact(weight: .light)
                    case .success: return .success
                    case .warning: return .warning
                    }
                }
            } else {
                content.onChange(of: value) { _ in Haptics.play(kind) }
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8), value: value)
    }
}

private struct ConfirmBounce<V: Equatable>: ViewModifier {
    let trigger: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pop = false

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else if #available(iOS 17.0, *) {
            content.symbolEffect(.bounce, value: trigger)
        } else {
            content
                .scaleEffect(pop ? 1.12 : 1)
                .onChange(of: trigger) { _ in
                    withAnimation(.spring(response: 0.2, dampingFraction: 0.5)) { pop = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { pop = false }
                    }
                }
        }
    }
}

/// Subtle press scale for buttons.
struct PressScaleStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

extension View {
    /// Haptic tick plus a spring animation whenever `value` changes (selections, pickers, toggles).
    func feedback<V: Equatable>(on value: V, _ kind: HapticKind = .selection) -> some View {
        modifier(FeedbackOnChange(value: value, kind: kind))
    }

    /// Bounces the SF Symbol (or pops the view on iOS 16) when `trigger` changes.
    func confirmBounce<V: Equatable>(_ trigger: V) -> some View {
        modifier(ConfirmBounce(trigger: trigger))
    }
}
