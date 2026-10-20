//
//  PackageStore.swift
//  PipaRender — 导入的包管理 + 二进制块读取（mmap 零拷贝）
//

import Foundation
import UIKit

/// 一个已导入（解压）的渲染包
final class ImportedPackage: Identifiable {
    let id: UUID
    let name: String
    let directory: URL
    let pkg: PipaPackage
    let importedAt: Date

    private var blobCache: [String: Data] = [:]
    private let lock = NSLock()

    init(id: UUID = UUID(), name: String, directory: URL, pkg: PipaPackage) {
        self.id = id
        self.name = name
        self.directory = directory
        self.pkg = pkg
        self.importedAt = Date()
    }

    func fileURL(_ relative: String) -> URL {
        directory.appendingPathComponent(relative)
    }

    func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(relative).path)
    }

    /// mmap 方式读取二进制块（零拷贝，重复调用返回缓存）
    func blob(_ relative: String) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        if let d = blobCache[relative] { return d }
        let url = fileURL(relative)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PackageError.missingFile(relative)
        }
        let d = try Data(contentsOf: url, options: .mappedIfSafe)
        if d.count != 0 { blobCache[relative] = d }
        return d
    }

    /// 读取 f4 切片（小端即本机）
    func floats(_ relative: String, byteOffset: Int, count: Int) throws -> [Float] {
        let d = try blob(relative)
        let start = byteOffset
        let end = start + count * 4
        guard start >= 0, end <= d.count else {
            throw PackageError.corruptData("\(relative) 切片越界 [\(start),\(end)) / \(d.count)")
        }
        return d.withUnsafeBytes { raw -> [Float] in
            let p = raw.bindMemory(to: Float.self).baseAddress!
            return Array(UnsafeBufferPointer(start: p.advanced(by: start / 4), count: count))
        }
    }

    func uint32s(_ relative: String, byteOffset: Int, count: Int) throws -> [UInt32] {
        let d = try blob(relative)
        let start = byteOffset
        let end = start + count * 4
        guard start >= 0, end <= d.count else {
            throw PackageError.corruptData("\(relative) 切片越界")
        }
        return d.withUnsafeBytes { raw -> [UInt32] in
            let p = raw.bindMemory(to: UInt32.self).baseAddress!
            return Array(UnsafeBufferPointer(start: p.advanced(by: start / 4), count: count))
        }
    }

    /// 索引缓冲字节范围（idx 用 u4 原生）
    func indexData(_ ref: BufferRef) throws -> Data {
        let d = try blob(ref.file ?? "meshes.bin")
        let start = ref.offset
        let end = start + ref.count * 4
        guard start >= 0, end <= d.count else {
            throw PackageError.corruptData("索引越界")
        }
        return d.subdata(in: start..<end)
    }

    /// 贴图解码（房间贴图 LINEAR+repeat；皮肤 NEAREST+clamp 在 SceneAssets 区分）
    func loadTextureImage(_ relative: String) throws -> UIImage {
        let url = fileURL(relative)
        guard let img = UIImage(contentsOfFile: url.path), let cg = img.cgImage else {
            throw PackageError.missingFile(relative)
        }
        return UIImage(cgImage: cg, scale: 1, orientation: .up)
    }

    func audioURL() -> URL? {
        guard let a = pkg.audio, exists(a) else { return nil }
        return fileURL(a)
    }
}

// MARK: - 包仓库（单例）

final class PackageStore {
    static let shared = PackageStore()

    private(set) var packages: [ImportedPackage] = []
    private let root: URL

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = docs.appendingPathComponent("Packages", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        reload()
    }

    /// 扫描已解压目录，重建包列表
    func reload() {
        var out: [ImportedPackage] = []
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for dir in dirs {
            let metaURL = dir.appendingPathComponent("package.json")
            guard let data = try? Data(contentsOf: metaURL),
                  let pkg = try? PipaPackage.decode(from: data) else { continue }
            out.append(ImportedPackage(name: pkg.name, directory: dir, pkg: pkg))
        }
        packages = out.sorted { $0.importedAt > $1.importedAt }
    }

    /// 从 ZIP URL 导入（解压 + 校验）
    @discardableResult
    func importZip(at url: URL, progress: ((String, Int, Int) -> Void)? = nil) throws -> ImportedPackage {
        let unzip = try Unzip(url: url)
        // 先找 package.json 验证
        guard let metaEntry = unzip.entries.first(where: { $0.name == "package.json" }) else {
            throw PackageError.missingFile("package.json")
        }
        let id = UUID()
        let dest = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try unzip.extract(metaEntry, to: dest.appendingPathComponent("package.json"))
        guard let data = try? Data(contentsOf: dest.appendingPathComponent("package.json")),
              let pkg = try? PipaPackage.decode(from: data) else {
            try? FileManager.default.removeItem(at: dest)
            throw PackageError.corruptData("package.json 解析失败")
        }
        // 校验必需二进制块存在
        for f in ["meshes.bin", "bones.bin", "camera.bin", "particles.bin", "ao.bin"] {
            guard unzip.entries.contains(where: { $0.name == f }) else {
                try? FileManager.default.removeItem(at: dest)
                throw PackageError.missingFile(f)
            }
        }
        // 全量解压
        try unzip.extractAll(to: dest, progress: progress)
        let p = ImportedPackage(id: id, name: pkg.name, directory: dest, pkg: pkg)
        packages.insert(p, at: 0)
        return p
    }

    func remove(_ p: ImportedPackage) {
        try? FileManager.default.removeItem(at: p.directory)
        packages.removeAll { $0.id == p.id }
    }

    /// 渲染任务的工作目录（分段 mp4 + 状态）
    func jobDirectory(_ p: ImportedPackage, jobId: String) -> URL {
        let d = root.appendingPathComponent(p.id.uuidString).appendingPathComponent("jobs", isDirectory: true)
            .appendingPathComponent(jobId, isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func jobRoot(_ p: ImportedPackage) -> URL {
        let d = root.appendingPathComponent(p.id.uuidString).appendingPathComponent("jobs", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
}
