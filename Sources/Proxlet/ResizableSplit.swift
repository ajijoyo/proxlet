//
//  ResizableSplit.swift
//  Proxlet
//
//  Created by Aji on 11/11/26
//  Copyright © 2026 Aji. Licensed under the MIT License.
//

import AppKit
import SwiftUI

/// Two panes with a wide drag handle. `.vertical` stacks top/bottom, `.horizontal` places left/right.
struct ResizableSplit<First: View, Second: View>: View {
    let axis: Axis
    @Binding var fraction: CGFloat
    var minFirst: CGFloat = 120
    var minSecond: CGFloat = 160
    /// False gives `first` the whole space; `first` keeps its identity either way.
    var showsSecond = true
    @ViewBuilder var first: First
    @ViewBuilder var second: Second

    @State private var dragStart: CGFloat?
    private let handle: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            let total = (axis == .vertical ? geo.size.height : geo.size.width) - handle
            let size = min(max(total * fraction, minFirst), max(minFirst, total - minSecond))
            if axis == .vertical {
                VStack(spacing: 0) {
                    first.frame(height: showsSecond ? size : geo.size.height)
                    if showsSecond {
                        grip(total: total, current: size)
                        second.frame(maxHeight: .infinity)
                    }
                }
            } else {
                HStack(spacing: 0) {
                    first.frame(width: showsSecond ? size : geo.size.width)
                    if showsSecond {
                        grip(total: total, current: size)
                        second.frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private func grip(total: CGFloat, current: CGFloat) -> some View {
        ZStack {
            Rectangle().fill(Color(nsColor: .windowBackgroundColor))
            Rectangle().fill(Color(nsColor: .separatorColor))
                .frame(width: axis == .vertical ? nil : 1, height: axis == .vertical ? 1 : nil)
            Capsule().fill(Color.secondary.opacity(0.5))
                .frame(width: axis == .vertical ? 36 : 4, height: axis == .vertical ? 4 : 36)
        }
        .frame(width: axis == .vertical ? nil : handle, height: axis == .vertical ? handle : nil)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { (axis == .vertical ? NSCursor.resizeUpDown : NSCursor.resizeLeftRight).push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    let start = dragStart ?? current
                    dragStart = start
                    let delta = axis == .vertical ? value.translation.height : value.translation.width
                    if total > 0 { fraction = min(max((start + delta) / total, 0.05), 0.95) }
                }
                .onEnded { _ in dragStart = nil }
        )
    }
}
