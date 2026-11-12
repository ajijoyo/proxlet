//
//  LocalPages.swift
//  ProxletCore
//
//  Created by Aji on 11/11/26
//  Copyright © 2026 Aji. Licensed under the MIT License.
//

import Foundation

/// Pages served by Proxlet itself so a phone can download the CA:
/// `http://<mac-ip>:<port>/ssl` directly, or `http://proxlet.ssl/` once the phone uses the proxy.
public enum LocalPages {
    public static let host = "proxlet.ssl"

    public static func response(for req: ProxyRequest) -> ProxyResponse? {
        guard let c = URLComponents(string: req.url) else { return nil }
        let direct = c.host == nil && req.url.hasPrefix("/")
        guard direct || c.host == host else { return nil }
        switch c.path {
        case "/ssl", "/ssl.pem", "/ssl.crt":
            guard let pem = FileManager.default.contents(atPath: Paths.caCert.path) else {
                return ProxyResponse(status: 404, headers: [Header(name: "Content-Type", value: "text/plain")],
                                     body: Data("CA not created yet. Open Proxlet first.".utf8))
            }
            let name = c.path == "/ssl.crt" ? "Proxlet-CA.crt" : "Proxlet-CA.pem"
            return ProxyResponse(status: 200, headers: [
                Header(name: "Content-Type", value: "application/x-x509-ca-cert"),
                Header(name: "Content-Disposition", value: "attachment; filename=\"\(name)\""),
                Header(name: "Cache-Control", value: "no-store"),
            ], body: pem)
        default:
            return ProxyResponse(status: 200, headers: [Header(name: "Content-Type", value: "text/html; charset=utf-8")],
                                 body: Data(landing.utf8))
        }
    }

    static let landing = """
    <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Proxlet CA</title><style>body{font:17px -apple-system,sans-serif;margin:24px;line-height:1.5}
    a{display:block;margin:12px 0;padding:14px;border-radius:10px;background:#0a84ff;color:#fff;text-decoration:none;text-align:center}</style>
    </head><body><h2>Proxlet CA certificate</h2>
    <a href="/ssl.pem">Download for iOS</a><a href="/ssl.crt">Download for Android</a>
    <p>After installing, trust it: iOS → Settings › General › About › Certificate Trust Settings.
    Android → Settings › Security › Encryption &amp; credentials › Install a certificate › CA certificate.</p>
    </body></html>
    """
}
