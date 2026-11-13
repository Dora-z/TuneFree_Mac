import Foundation
import SwiftUI

enum TrackStatus: Equatable {
    case pending
    case decrypting
    case decrypted
    case transcoding
    case done
    case skipped
    case failed(String)

    var isFailure: Bool { if case .failed = self { return true }; return false }
    var isActive: Bool { self == .decrypting || self == .transcoding }
}

struct Track: Identifiable, Equatable {
    let id: String              // 源文件绝对路径
    let path: String
    let fileName: String
    let title: String
    let artist: String
    let ext: String
    let size: Int64
    var kind: String = ""       // qtag / v1 / musicex / qmc1
    var format: String = ""     // flac / ogg
    var needsLogin = false      // musicex 且没读到登录态
    var decryptedPath: String?  // 解密产物（转码阶段用它对上号）
    var outputPath: String?     // 最终产物
    var status: TrackStatus = .pending

    init(path: String, size: Int64) {
        self.id = path
        self.path = path
        let url = URL(fileURLWithPath: path)
        self.fileName = url.lastPathComponent
        self.ext = url.pathExtension.lowercased()
        self.size = size
        let stem = url.deletingPathExtension().lastPathComponent
        // QQ音乐缓存名：歌手-歌名
        if let dash = stem.range(of: "-"), dash.lowerBound != stem.startIndex {
            self.artist = String(stem[..<dash.lowerBound]).trimmingCharacters(in: .whitespaces)
            self.title = String(stem[dash.upperBound...]).trimmingCharacters(in: .whitespaces)
        } else {
            self.artist = ""
            self.title = stem
        }
    }

    var displayFormat: String {
        let f = format.isEmpty ? Track.guessFormat(ext) : format
        return f.uppercased()
    }

    var isLossless: Bool { displayFormat == "FLAC" }

    var kindLabel: String {
        switch kind {
        case "qtag": return "QTag"
        case "v1": return "V1"
        case "musicex": return "musicex"
        case "qmc1": return "QMC1"
        default: return ext.uppercased()
        }
    }

    static func guessFormat(_ ext: String) -> String {
        switch ext {
        case "mflac", "mflac0", "mflach", "qmcflac": return "flac"
        case "mgg", "mgg0", "mgg1", "mggl", "qmcogg", "qmc2": return "ogg"
        case "qmc0", "qmc3": return "mp3"
        default: return ext
        }
    }

    /// 与后端 decrypt.OUTPUT_EXT 保持一致
    static let supportedExtensions: Set<String> = [
        "mflac", "mflac0", "mflach", "mgg", "mgg0", "mgg1", "mggl",
        "qmcflac", "qmcogg", "qmc0", "qmc3", "qmc2",
    ]

    /// 由名字派生一个稳定的色相，给「封面」上色
    var hue: Double {
        var h: UInt64 = 1469598103934665603
        for b in (artist + title).utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return Double(h % 360) / 360.0
    }

    var initials: String {
        let base = title.isEmpty ? fileName : title
        return String(base.prefix(1))
    }
}

extension Int64 {
    var byteString: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}
