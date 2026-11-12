//
//  StatusPill.swift
//  Proxlet
//
//  Created by Aji on 12/11/26
//  Copyright © 2026 Aji. Licensed under the MIT License.
//

import SwiftUI

struct StatusPill: View {
    let title: String
    let on: Bool

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(on ? Color.green : Color.secondary).frame(width: 6, height: 6)
            Text("\(title) \(on ? "On" : "Off")")
        }
    }
}
