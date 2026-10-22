//
//  Unzip.swift
//  PipaRender — 零依赖 ZIP 解压（stored + deflate，走系统 libz）
//

import Foundation
import zlib

enum UnzipError: LocalizedError {
    case notAZip
    case badCentralDirectory
    case unsupportedMethod(UInt16)
    case inflateFailed(Int32)
    case entryNotFound(String)
    case corruptData(String)

    var errorDescription: String? {
        switch self {
        case .notAZip: return "不是有效的 ZIP 文件"
        case .badCentralDirectory: return "ZIP 中央目录损坏"
        case .unsupportedMethod(let m): return "不支持的压缩方法 \(m)（仅支持 stored/deflate）"
        case .inflateFailed(let c): return "解压失败（zlib \(c)）"
        case .entryNotFound(let n): return "ZIP 内没有条目：\(n)"
        case .corruptData(let m): return "ZIP 数据损坏：\(m)"
        }
    }
}

struct ZipEntry {
    let name: String
    let compressedSize: UInt32
    let uncompressedSize: UInt32
    let method: UInt16
    let localHeaderOffset: UInt32
}

final class Unzip {

    private let data: Data
    private(set) var entries: [ZipEntry] = []

    init(url: URL) throws {
        let d = try Data(contentsOf: url, options: .mappedIfSafe)
        self.data = d
        try parseCentralDirectory()
    }

    // MARK: - 中央目录解析

    private func parseCentralDirectory() throws {
        // EOCD signature: 0x06054b50，位于文件尾部（可能有最长 64KB 注释）
        let bytes = [UInt8](data)
        let n = bytes.count
        var eocd = -1
        if n >= 22 {
            let lo = max(0, n - 22 - 0xFFFF)
            var i = n - 22
            while i >= lo {
                if bytes[i] == 0x50 && bytes[i+1] == 0x4b && bytes[i+2] == 0x05 && bytes[i+3] == 0x06 {
                    eocd = i
                    break
                }
                i -= 1
            }
        }
        guard eocd >= 0 else { throw UnzipError.notAZip }
        // EOCD: cd_offset(16) + cd_size(12) + cd_count(10)
        let cdCount = rd32(eocd + 10)
        let cdOffset = rd32(eocd + 16)

        var pos = Int(cdOffset)
        for _ in 0..<cdCount {
            guard pos + 46 <= n else { throw UnzipError.badCentralDirectory }
            guard bytes[pos] == 0x50 && bytes[pos+1] == 0x4b && bytes[pos+2] == 0x01 && bytes[pos+3] == 0x02 else {
                throw UnzipError.badCentralDirectory
            }
            let method = rd16(pos + 10)
            let compSize = rd32(pos + 20)
            let uncompSize = rd32(pos + 24)
            let nameLen = Int(rd16(pos + 28))
            let extraLen = Int(rd16(pos + 30))
            let commentLen = Int(rd16(pos + 32))
            let localOffset = rd32(pos + 42)
            guard pos + 46 + nameLen <= n else { throw UnzipError.badCentralDirectory }
            let nameData = data.subdata(in: (pos + 46)..<(pos + 46 + nameLen))
            let name = String(decoding: nameData, as: UTF8.self)
            entries.append(ZipEntry(name: name, compressedSize: compSize,
                                    uncompressedSize: uncompSize, method: method,
                                    localHeaderOffset: localOffset))
            pos += 46 + nameLen + extraLen + commentLen
        }
    }

    // MARK: - 解压

    /// 解压单个条目到目标 URL
    func extract(_ entry: ZipEntry, to destURL: URL) throws {
        let bytes = [UInt8](data)
        let n = bytes.count
        let lho = Int(entry.localHeaderOffset)
        guard lho + 30 <= n,
              bytes[lho] == 0x50 && bytes[lho+1] == 0x4b && bytes[lho+2] == 0x03 && bytes[lho+3] == 0x04 else {
            throw UnzipError.badCentralDirectory
        }
        let nameLen = Int(rd16(lho + 26))
        let extraLen = Int(rd16(lho + 28))
        let dataStart = lho + 30 + nameLen + extraLen
        let compSize = Int(entry.compressedSize)
        guard dataStart + compSize <= n else { throw UnzipError.badCentralDirectory }
        let comp = data.subdata(in: dataStart..<(dataStart + compSize))

        var out: Data
        switch entry.method {
        case 0:  // stored
            out = comp
        case 8:  // deflate
            out = try inflateRaw(comp, expectedSize: Int(entry.uncompressedSize))
        default:
            throw UnzipError.unsupportedMethod(entry.method)
        }
        try FileManager.default.createDirectory(at: destURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try out.write(to: destURL, options: .atomic)
    }

    func extractAll(to directory: URL, progress: ((String, Int, Int) -> Void)? = nil) throws {
        for (i, e) in entries.enumerated() {
            progress?(e.name, i + 1, entries.count)
            // 目录条目（名字以 / 结尾）跳过
            if e.name.hasSuffix("/") { continue }
            try extract(e, to: directory.appendingPathComponent(e.name))
        }
    }

    // MARK: - raw deflate (zlib)

    private func inflateRaw(_ comp: Data, expectedSize: Int) throws -> Data {
        var out = Data(capacity: expectedSize)
        var stream = z_stream()
        var status = inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { throw UnzipError.inflateFailed(status) }
        defer { inflateEnd(&stream) }

        try comp.withUnsafeBytes { (compPtr: UnsafeRawBufferPointer) in
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: compPtr.bindMemory(to: Bytef.self).baseAddress!)
            stream.avail_in = uInt(comp.count)
            let chunk = 64 * 1024
            let buffer = UnsafeMutablePointer<Bytef>.allocate(capacity: chunk)
            defer { buffer.deallocate() }
            repeat {
                stream.next_out = buffer
                stream.avail_out = uInt(chunk)
                status = inflate(&stream, Z_NO_FLUSH)
                switch status {
                case Z_OK, Z_STREAM_END, Z_BUF_ERROR:
                    let produced = chunk - Int(stream.avail_out)
                    if produced > 0 {
                        out.append(buffer, count: produced)
                    }
                default:
                    throw UnzipError.inflateFailed(status)
                }
            } while status != Z_STREAM_END && stream.avail_in > 0
        }
        if out.count != expectedSize {
            throw UnzipError.corruptData("解压大小不符（得到 \(out.count)，预期 \(expectedSize)）")
        }
        return out
    }

    // MARK: - 小工具

    private func rd16(_ off: Int) -> UInt16 {
        let b = [UInt8](data)
        return UInt16(b[off]) | (UInt16(b[off+1]) << 8)
    }

    private func rd32(_ off: Int) -> UInt32 {
        let b = [UInt8](data)
        return UInt32(b[off]) | (UInt32(b[off+1]) << 8) | (UInt32(b[off+2]) << 16) | (UInt32(b[off+3]) << 24)
    }
}
