//
//  FlowDetailView.swift
//  Proxlet
//
//  Created by Aji on 11/11/26
//  Copyright © 2026 Aji. Licensed under the MIT License.
//

import AppKit
import ProxletCore
import SwiftUI

struct FlowDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let flow: Flow
    @State private var split: CGFloat = 0.5
    @State private var image: BodyImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                MethodBadge(method: flow.method)
                StatusText(code: flow.status)
                // Wraps instead of pushing the buttons off screen.
                Text(flow.url)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(flow.durationMs) ms").foregroundStyle(.secondary).monospacedDigit().fixedSize()
                Button("Map Local", systemImage: "wand.and.stars") {
                    if let id = model.mock(flow) { openWindow(id: "mapLocal", value: id) }
                }
                .fixedSize()
                Button("Add Script", systemImage: "curlybraces") {
                    if let name = model.addScript(for: flow.url, method: flow.method) { openWindow(id: "script", value: name) }
                }
                .fixedSize()
            }
            if let error = flow.error {
                Text(error).foregroundStyle(.red).font(.caption).textSelection(.enabled)
            }
            if flow.method == "CONNECT" {
                HStack {
                    Label("SSL Proxying is off for \(flow.host): only the encrypted tunnel was recorded.", systemImage: "lock")
                    Spacer()
                    if model.sslProxying.shouldDecrypt(flow.host) {
                        Text("Enabled. Reload in the app to see requests.").foregroundStyle(.secondary)
                    } else {
                        Button("Enable SSL Proxying") { model.setSSLProxying(true, for: flow.host) }
                    }
                }
                .padding(8)
                .background(.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
            }
            ResizableSplit(axis: .horizontal, fraction: $split, minFirst: 240, minSecond: 240) {
                MessagePane(title: "Request", headers: flow.requestHeaders, bodyText: flow.requestBody, raw: rawRequest)
            } second: {
                if flow.websocket {
                    // New identity per flow, so state from the previously selected socket never leaks in.
                    WebSocketPane(flow: flow).id(flow.id)
                } else {
                    MessagePane(title: "Response", headers: flow.responseHeaders, bodyText: flow.responseBody, raw: rawResponse,
                                image: image)
                }
            }
        }
        .padding(8)
        .task(id: flow.id) {
            image = nil
            let id = flow.id
            image = await Task.detached { BodyStore.load(flowID: id) }.value.flatMap(BodyImage.init)
        }
    }

    private var rawRequest: String {
        let line = "\(flow.method) \(flow.path) HTTP/1.1\nHost: \(flow.host)"
        return ([line] + flow.requestHeaders.filter { $0.name.lowercased() != "host" }.map { "\($0.name): \($0.value)" })
            .joined(separator: "\n") + "\n\n" + flow.requestBody
    }

    private var rawResponse: String {
        HTTPMessageFormat.render(status: flow.status, headers: flow.responseHeaders, body: flow.responseBody)
    }
}

/// One side of a flow with Headers / Body / Raw tabs and a copy button.
struct MessagePane: View {
    enum Tab: String, CaseIterable { case headers = "Headers", body = "Body", raw = "Raw" }

    let title: String
    let headers: [Header]
    let bodyText: String
    let raw: String
    var image: BodyImage?
    @State private var tab: Tab = .body
    @State private var copied = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.headline)
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 240)
                Spacer()
                Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") { copy() }
            }
            ScrollView {
                content
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .headers:
            if headers.isEmpty {
                Text("No headers").foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                    ForEach(Array(headers.enumerated()), id: \.offset) { _, h in
                        GridRow {
                            Text(h.name).foregroundStyle(Color(nsColor: Syntax.nsColor(palette.headerName)))
                            Text(h.value).foregroundStyle(Color(nsColor: Syntax.nsColor(palette.headerValue)))
                        }
                    }
                }
            }
        case .body:
            if let image {
                VStack(alignment: .leading, spacing: 6) {
                    Image(nsImage: image.image).resizable().scaledToFit()
                        .frame(maxWidth: image.image.size.width, maxHeight: image.image.size.height)
                    Text(image.caption).font(.caption).foregroundStyle(.secondary)
                }
            } else if bodyText.isEmpty {
                Text("No body").foregroundStyle(.secondary)
            } else if let pretty = JSONFormatter.pretty(bodyText) {
                Text(Syntax.attributed(pretty, kind: .json, dark: colorScheme == .dark))
            } else {
                Text(bodyText)
            }
        case .raw:
            Text(Syntax.attributed(raw, kind: .http, dark: colorScheme == .dark))
        }
    }

    private var palette: Theme.Palette { Theme.current.palette(dark: colorScheme == .dark) }

    private var copyText: String {
        switch tab {
        case .headers: headers.map { "\($0.name): \($0.value)" }.joined(separator: "\n")
        case .body: JSONFormatter.pretty(bodyText) ?? bodyText
        case .raw: raw
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        if tab == .body, let image {
            NSPasteboard.general.writeObjects([image.image])
        } else {
            NSPasteboard.general.setString(copyText, forType: .string)
        }
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            copied = false
        }
    }
}

/// A recorded image response body, decoded once per selected flow.
struct BodyImage {
    let image: NSImage
    let caption: String

    init?(_ data: Data) {
        guard let image = NSImage(data: data) else { return nil }
        self.image = image
        let rep = image.representations.first
        let pixels = rep.map { "\($0.pixelsWide)×\($0.pixelsHigh) px · " } ?? ""
        caption = pixels + ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
    }
}
