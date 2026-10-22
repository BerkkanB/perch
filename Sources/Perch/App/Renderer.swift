import AppKit
import SwiftUI

/// Command-line rendering of the app icon, used by `scripts/make-icon.sh`.
@MainActor
enum Renderer {
    enum Command {
        case icon(directory: String)

        init?(arguments: [String]) {
            guard let index = arguments.firstIndex(of: "--render-icon"), index + 1 < arguments.count else { return nil }
            self = .icon(directory: arguments[index + 1])
        }
    }

    static func run(_ command: Command) -> Bool {
        switch command {
        case .icon(let directory):
            return renderIconSet(to: directory)
        }
    }

    /// Writes an `.iconset` folder for `iconutil`.
    static func renderIconSet(to directory: String) -> Bool {
        let sizes: [(points: Int, scale: Int)] = [
            (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
        ]
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            for size in sizes {
                let pixels = CGFloat(size.points * size.scale)
                let name = "icon_\(size.points)x\(size.points)\(size.scale == 2 ? "@2x" : "").png"
                try writePNG(PerchMark(size: pixels, iconMargin: true), to: "\(directory)/\(name)")
            }
            return true
        } catch {
            print("Icon rendering failed: \(error.localizedDescription)")
            return false
        }
    }

    private static func writePNG(_ view: some View, to path: String) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        guard let image = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: URL(fileURLWithPath: path))
    }
}
