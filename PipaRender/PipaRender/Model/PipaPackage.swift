//
//  PipaPackage.swift
//  PipaRender — pipapkg v2 包格式的 Codable 模型（见 PackageFormat.md）
//

import Foundation
import simd

// MARK: - 顶层清单

struct PipaPackage: Codable {
    let format: String
    let version: Int
    let name: String
    let fps: Int
    let frameStart: Int
    let frameEnd: Int
    let resolution: [Int]
    let shutter: Float
    let world: WorldInfo
    let defaults: RenderDefaults
    let sun: Sun
    let lights: [SceneLight]
    let camera: CameraInfo
    let groups: [SceneGroup]
    let characters: [RigCharacter]
    let particles: ParticlesInfo
    let visibility: VisibilityInfo?
    let debris: DebrisInfo?
    let ao: AOInfo?
    let audio: String?

    enum CodingKeys: String, CodingKey {
        case format, version, name, fps, resolution, shutter
        case frameStart = "frame_start"
        case frameEnd = "frame_end"
        case world, defaults, sun, lights, camera, groups, characters
        case particles, visibility, debris, ao, audio
    }

    /// 输出宽高（源比例）
    var width: Int { max(2, resolution[0]) }
    var height: Int { max(2, resolution[1]) }
    /// 源帧总数
    var frameCount: Int { frameEnd - frameStart + 1 }

    static func decode(from data: Data) throws -> PipaPackage {
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        let pkg = try dec.decode(PipaPackage.self, from: data)
        guard pkg.format == "pipapkg" else {
            throw PackageError.badFormat(pkg.format)
        }
        guard pkg.version >= 1 && pkg.version <= 2 else {
            throw PackageError.unsupportedVersion(pkg.version)
        }
        guard pkg.frameCount > 0, !pkg.groups.isEmpty else {
            throw PackageError.emptyPackage
        }
        return pkg
    }
}

enum PackageError: LocalizedError {
    case badFormat(String)
    case unsupportedVersion(Int)
    case emptyPackage
    case missingFile(String)
    case corruptData(String)
    case metalFailure(String)

    var errorDescription: String? {
        switch self {
        case .badFormat(let f): return "不是 pipapkg 包（format=\(f)）"
        case .unsupportedVersion(let v): return "不支持的包版本 v\(v)"
        case .emptyPackage: return "包内容为空"
        case .missingFile(let f): return "缺少文件：\(f)"
        case .corruptData(let m): return "数据损坏：\(m)"
        case .metalFailure(let m): return "Metal 错误：\(m)"
        }
    }
}

// MARK: - 世界 / 灯光

struct WorldInfo: Codable {
    let background: [Float]
}

struct Sun: Codable {
    let dir: [Float]
    let color: [Float]
    let intensity: Float
    let shadowSoftness: Float
    let shadowSamples: Int
}

struct SceneLight: Codable {
    let type: String          // "POINT" / "AREA"
    let energy: Float
    let color: [Float]
    let pos: [Float]
    let normal: [Float]?      // AREA 发光面法线（世界空间）；零向量 = 面光不照明（忠实桌面端）
}

// MARK: - 相机

struct CameraInfo: Codable {
    let buffer: String
    let metaBuffer: String?
    let frames: Int
    let fovUnit: String?
}

// MARK: - 网格

struct BufferRef: Codable {
    let file: String?
    let offset: Int
    let count: Int
    let dtype: String
}

struct Bounds: Codable {
    let min: [Float]
    let max: [Float]
}

struct SceneGroup: Codable {
    let name: String
    let texture: String?
    let color: [Float]
    let emission: [Float]
    let alphaCut: Bool
    let animated: Bool
    let bounds: Bounds
    let verts: Int
    let indices: Int
    let buf: [String: BufferRef]
    let mat: MatTrack?

    enum CodingKeys: String, CodingKey {
        case name, texture, color, emission, alphaCut = "alpha_cut"
        case animated, bounds, verts, indices, buf, mat
    }
}

struct MatTrack: Codable {
    let file: String
    let offset: Int
    let frames: Int
    let dtype: String
}

struct RigCharacter: Codable {
    let name: String
    let skin: String?
    let bones: [String]
    let boneCount: Int
    let armatureWorld: [Float]      // Blender 空间 4×4 行主序
    let boneBuffer: BoneBufferRef
    let parts: [CharacterPart]

    enum CodingKeys: String, CodingKey {
        case name, skin, bones, boneCount = "bone_count"
        case armatureWorld = "armature_world"
        case boneBuffer = "bone_buffer"
        case parts
    }
}

struct BoneBufferRef: Codable {
    let file: String
    let offset: Int?         // 共享 bones.bin 时的 float 偏移（缺省按 characters 顺序累加，兼容旧包）
    let frames: Int
    let bones: Int
    let dtype: String
    let layout: String
}

struct CharacterPart: Codable {
    let name: String
    let alphaCut: Bool
    let bounds: Bounds
    let verts: Int
    let indices: Int
    let buf: [String: BufferRef]

    enum CodingKeys: String, CodingKey {
        case name, alphaCut = "alpha_cut", bounds, verts, indices, buf
    }
}

// MARK: - 粒子

struct ParticlesInfo: Codable {
    let buffer: String
    let count: Int
    let pos: BufferRef
    let em: BufferRef
    let vel: BufferRef
    let size: BufferRef
    let off: BufferRef
}

// MARK: - 可见性 / 碎块 / AO

struct VisibilityInfo: Codable {
    let buffer: String
    let frames: Int
    let groups: Int
    let layout: String
}

struct DebrisEvent: Codable {
    let frame: Float
    let group: Int
    let groupName: String?
    let offset: Int
    let count: Int
    let floor: Float
}

struct DebrisInfo: Codable {
    let buffer: String
    let events: [DebrisEvent]
}

struct AOInfo: Codable {
    let buffer: String
    let kernelCount: Int
    let noiseSize: Int
}

// MARK: - 渲染默认值

struct DebrisDefaults: Codable {
    let count: Int
    let life: Float
    let gravity: Float
    let jump: Float
    let shade: Float
}

struct RenderDefaults: Codable {
    var exposure: Float
    var gamma: Float
    var tonemap: String
    var bloom: Bool
    var bloomThreshold: Float
    var bloomStrength: Float
    var glare: Bool
    var glareThreshold: Float
    var glareStrength: Float
    var glareSize: Float
    var glareSmoothness: Float
    var shadow: Bool
    var shadowSamples: Int
    var shadowSoftness: Float
    var shadowDistance: Float
    var ao: Bool
    var aoSamples: Int
    var aoIntensity: Float
    var aoRadius: Float
    var ssr: Bool
    var ambientIntensity: Float
    var lightColor: [Float]
    var skyColor: [Float]
    var groundColor: [Float]
    var specStrength: Float
    var roughness: Float
    var pointScale: Float
    var pointSoft: Float
    var particleScale: Float
    var particleStreak: Float
    var particleWidth: Float
    var debris: DebrisDefaults
}
