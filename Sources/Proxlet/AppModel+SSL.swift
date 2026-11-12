//
//  AppModel+SSL.swift
//  Proxlet
//
//  Created by Aji on 12/11/26
//  Copyright © 2026 Aji. Licensed under the MIT License.
//

import ProxletCore

extension AppModel {
    /// Writes ssl-proxying.json; the next CONNECT to a host sees the change.
    func updateSSLProxying(_ change: (inout SSLProxying) -> Void) {
        do { sslProxying = try SSLProxying.update(change) } catch {
            alert("Could not save the SSL Proxying list: \(error.localizedDescription)")
        }
    }

    /// Enables a host, or turns off whichever include entries currently decrypt it.
    func setSSLProxying(_ on: Bool, for host: String) {
        updateSSLProxying { list in
            if on { list.add(host) } else { list.disableIncludes(matching: host) }
        }
    }
}
