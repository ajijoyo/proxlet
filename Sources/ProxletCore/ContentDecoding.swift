//
//  ContentDecoding.swift
//  ProxletCore
//
//  Created by Aji on 11/11/26
//  Copyright © 2026 Aji. Licensed under the MIT License.
//

import Compression
import Foundation

/// Decodes HTTP `Content-Encoding` bodies (gzip, deflate, br) with Apple's Compression framework.
public enum ContentDecoding {
    public static let acceptEncoding = "gzip, deflate, br"

    /// Decoded body, or nil when the encoding is unsupported or the data is malformed.
    public static func decode(_ data: Data, encoding: String) -> Data? {
        if data.isEmpty { return data }
        switch encoding.lowercased().trimmingCharacters(in: .whitespaces) {
        case "identity", "": return data
        case "gzip", "x-gzip": return gunzip(data)
        case "deflate": return inflate(data)
        case "br": return stream(data, COMPRESSION_BROTLI)
        default: return nil
        }
    }

    /// Strips the gzip header/trailer (RFC 1952) and inflates the raw deflate payload.
    public static func gunzip(_ data: Data) -> Data? {
        let b = [UInt8](data)
        guard b.count >= 18, b[0] == 0x1f, b[1] == 0x8b, b[2] == 8 else { return nil }
        let flags = b[3]
        var i = 10
        if flags & 0x04 != 0 {
            guard i + 2 <= b.count else { return nil }
            i += 2 + Int(b[i]) + Int(b[i + 1]) << 8
        }
        if flags & 0x08 != 0 { while i < b.count, b[i] != 0 { i += 1 }; i += 1 }
        if flags & 0x10 != 0 { while i < b.count, b[i] != 0 { i += 1 }; i += 1 }
        if flags & 0x02 != 0 { i += 2 }
        guard i < b.count - 8 else { return nil }
        return stream(Data(b[i..<(b.count - 8)]), COMPRESSION_ZLIB)
    }

    /// HTTP "deflate" is usually zlib-wrapped; fall back to raw deflate.
    static func inflate(_ data: Data) -> Data? {
        let b = [UInt8](data)
        if b.count > 2, b[0] & 0x0f == 8, (Int(b[0]) << 8 | Int(b[1])) % 31 == 0,
           let out = stream(Data(b[2...]), COMPRESSION_ZLIB) {
            return out
        }
        return stream(data, COMPRESSION_ZLIB)
    }

    /// gzip (RFC 1952) of `data`: header, raw deflate, CRC-32 and size.
    public static func gzip(_ data: Data) -> Data? {
        guard let deflated = stream(data, COMPRESSION_ZLIB, operation: COMPRESSION_STREAM_ENCODE) else { return nil }
        var out = Data([0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 0x03])
        out.append(deflated)
        for value in [crc32(data), UInt32(truncatingIfNeeded: data.count)] {
            out.append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) })
        }
        return out
    }

    private static let crcTable: [UInt32] = (0..<256).map { n in
        (0..<8).reduce(UInt32(n)) { c, _ in c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
    }

    static func crc32(_ data: Data) -> UInt32 {
        ~data.reduce(~UInt32(0)) { crcTable[Int(($0 ^ UInt32($1)) & 0xff)] ^ ($0 >> 8) }
    }

    static func stream(_ input: Data, _ algorithm: compression_algorithm,
                       operation: compression_stream_operation = COMPRESSION_STREAM_DECODE) -> Data? {
        let streamPtr = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPtr.deallocate() }
        guard compression_stream_init(streamPtr, operation, algorithm) == COMPRESSION_STATUS_OK else { return nil }
        defer { compression_stream_destroy(streamPtr) }

        let chunk = 64 * 1024
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { dst.deallocate() }
        var output = Data()
        return input.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Data? in
            guard let base = src.bindMemory(to: UInt8.self).baseAddress else { return nil }
            streamPtr.pointee.src_ptr = base
            streamPtr.pointee.src_size = input.count
            while true {
                streamPtr.pointee.dst_ptr = dst
                streamPtr.pointee.dst_size = chunk
                let status = compression_stream_process(streamPtr, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                output.append(dst, count: chunk - streamPtr.pointee.dst_size)
                switch status {
                case COMPRESSION_STATUS_OK: continue
                case COMPRESSION_STATUS_END: return output
                default: return nil
                }
            }
        }
    }
}
