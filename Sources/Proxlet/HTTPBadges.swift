//
//  HTTPBadges.swift
//  Proxlet
//
//  Created by Aji on 11/11/26
//  Copyright © 2026 Aji. Licensed under the MIT License.
//

import SwiftUI

/// Method and status styling shared by the flow list and the detail header.
enum HTTPStyle {
    static func status(_ code: Int) -> Color {
        switch code {
        case 200..<300: .green
        case 300..<400: .blue
        case 400..<500: .orange
        default: .red
        }
    }

    static func method(_ method: String) -> Color {
        switch method.uppercased() {
        case "GET": .teal
        case "POST": .orange
        case "PUT": .blue
        case "PATCH": .purple
        case "DELETE": .red
        case "WS": .pink
        default: .secondary
        }
    }
}

struct MethodBadge: View {
    let method: String

    var body: some View {
        Text(method)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(HTTPStyle.method(method))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(HTTPStyle.method(method).opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
    }
}

struct StatusText: View {
    let code: Int

    var body: some View {
        Text("\(code)").fontWeight(.semibold).monospacedDigit().foregroundStyle(HTTPStyle.status(code))
    }
}
