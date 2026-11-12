//
//  CertificateAuthority.swift
//  ProxletCore
//
//  Created by Aji on 11/11/26
//  Copyright © 2026 Aji. Licensed under the MIT License.
//

import Crypto
import Foundation
import NIOSSL
import Security
import SwiftASN1
import X509

/// Local root CA that signs a leaf certificate per intercepted host.
public final class CertificateAuthority: @unchecked Sendable {
    public let certificate: Certificate
    private let key: P256.Signing.PrivateKey
    private let leafKey = P256.Signing.PrivateKey()
    private let nioCA: NIOSSLCertificate
    private var contexts: [String: NIOSSLContext] = [:]
    private let lock = NSLock()

    public init(certificate: Certificate, key: P256.Signing.PrivateKey) throws {
        self.certificate = certificate
        self.key = key
        nioCA = try NIOSSLCertificate(bytes: Array(try certificate.serializeAsPEM().pemString.utf8), format: .pem)
    }

    /// Lifetime of a new CA; leaves are capped separately at 397 days.
    public static let defaultValidityDays = 825
    public static let validityRange = 1...3650

    /// The saved CA as this Mac sees it (for proxlet-mcp and diagnostics).
    public struct Status: Sendable {
        public let subject: String
        public let notBefore: Date
        public let notAfter: Date
        public let sha256: String
        /// Whether macOS trusts it as a root, i.e. "Trust CA on this Mac" was done and approved.
        public let trusted: Bool
    }

    /// nil when no CA has been created yet (Proxlet creates it on first start).
    public static func status() -> Status? {
        guard let pem = try? String(contentsOf: Paths.caCert, encoding: .utf8), let cert = try? Certificate(pemEncoded: pem) else {
            return nil
        }
        var serializer = DER.Serializer()
        guard (try? serializer.serialize(cert)) != nil else { return nil }
        let der = Data(serializer.serializedBytes)
        var trusted = false
        if let secCert = SecCertificateCreateWithData(nil, der as CFData) {
            var trust: SecTrust?
            if SecTrustCreateWithCertificates(secCert, SecPolicyCreateBasicX509(), &trust) == errSecSuccess, let trust {
                trusted = SecTrustEvaluateWithError(trust, nil)
            }
        }
        return Status(subject: cert.subject.description, notBefore: cert.notValidBefore, notAfter: cert.notValidAfter,
                      sha256: SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(), trusted: trusted)
    }

    /// Loads the CA from disk, creating and saving a new one (valid `validityDays`) on first run.
    public static func loadOrCreate(validityDays: Int = defaultValidityDays) throws -> CertificateAuthority {
        try Paths.ensure()
        if let certPEM = try? String(contentsOf: Paths.caCert, encoding: .utf8),
           let keyPEM = try? String(contentsOf: Paths.caKey, encoding: .utf8) {
            return try CertificateAuthority(
                certificate: Certificate(pemEncoded: certPEM),
                key: P256.Signing.PrivateKey(pemRepresentation: keyPEM)
            )
        }
        let ca = try makeRoot(validityDays: validityDays)
        try ca.certificate.serializeAsPEM().pemString.write(to: Paths.caCert, atomically: true, encoding: .utf8)
        // Created with 0600 so the private key is never readable by others, even briefly.
        guard FileManager.default.createFile(atPath: Paths.caKey.path, contents: Data(ca.key.pemRepresentation.utf8),
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: Paths.caKey.path])
        }
        return ca
    }

    /// Deletes the saved CA so the next `loadOrCreate` makes a new one.
    public static func remove() throws {
        for url in [Paths.caCert, Paths.caKey] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    static func makeRoot(validityDays: Int = defaultValidityDays) throws -> CertificateAuthority {
        let key = P256.Signing.PrivateKey()
        let host = ProcessInfo.processInfo.hostName
        let name = try DistinguishedName {
            CommonName("Proxlet CA (\(host))")
            OrganizationName("Proxlet")
        }
        let now = Date()
        let cert = try Certificate(
            version: .v3,
            serialNumber: .init(),
            publicKey: .init(key.publicKey),
            notValidBefore: now.addingTimeInterval(-86_400),
            notValidAfter: now.addingTimeInterval(86_400 * Double(validityDays)),
            issuer: name,
            subject: name,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: nil))
                Critical(KeyUsage(keyCertSign: true, cRLSign: true))
                SubjectKeyIdentifier(hash: .init(key.publicKey))
            },
            issuerPrivateKey: .init(key)
        )
        return try CertificateAuthority(certificate: cert, key: key)
    }

    /// Leaf certificate for `host`, valid 397 days (Apple's TLS server cert limit) or until the CA expires.
    public func leafCertificate(for host: String) throws -> Certificate {
        let now = Date()
        return try Certificate(
            version: .v3,
            serialNumber: .init(),
            publicKey: .init(leafKey.publicKey),
            notValidBefore: now.addingTimeInterval(-86_400),
            notValidAfter: min(now.addingTimeInterval(86_400 * 397), certificate.notValidAfter),
            issuer: certificate.subject,
            subject: try DistinguishedName { CommonName(host) },
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                Critical(KeyUsage(digitalSignature: true))
                try ExtendedKeyUsage([.serverAuth])
                SubjectAlternativeNames([Self.subjectAltName(for: host)])
                AuthorityKeyIdentifier(keyIdentifier: try certificate.extensions.subjectKeyIdentifier?.keyIdentifier)
            },
            issuerPrivateKey: .init(key)
        )
    }

    /// IP literals need an iPAddress SAN; TLS clients never match IPs against dNSName.
    static func subjectAltName(for host: String) -> GeneralName {
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 {
            return .ipAddress(ASN1OctetString(contentBytes: ArraySlice(withUnsafeBytes(of: &v4) { Array($0) })))
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, host, &v6) == 1 {
            return .ipAddress(ASN1OctetString(contentBytes: ArraySlice(withUnsafeBytes(of: &v6) { Array($0) })))
        }
        return .dnsName(host)
    }

    /// Cached TLS server context presenting a leaf cert for `host`.
    public func serverContext(for host: String) throws -> NIOSSLContext {
        lock.lock()
        defer { lock.unlock() }
        if let ctx = contexts[host] { return ctx }
        let leaf = try leafCertificate(for: host)
        let nioLeaf = try NIOSSLCertificate(bytes: Array(try leaf.serializeAsPEM().pemString.utf8), format: .pem)
        let nioKey = try NIOSSLPrivateKey(bytes: Array(leafKey.pemRepresentation.utf8), format: .pem)
        var config = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(nioLeaf), .certificate(nioCA)],
            privateKey: .privateKey(nioKey)
        )
        config.applicationProtocols = ["http/1.1"]
        let ctx = try NIOSSLContext(configuration: config)
        contexts[host] = ctx
        return ctx
    }
}
