import CoreGraphics
import Darwin
import Foundation
import ImageIO

@MainActor
func watchDesktopInTerminal(_ connection: any SessionConnection) async throws {
    guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1,
          let terminal = ProcessInfo.processInfo.environment["TERM"], !terminal.isEmpty, terminal != "dumb" else {
        throw Failure("Run --terminal in an interactive terminal with ANSI color support")
    }

    let display = TerminalDesktopView()
    let task = Task {
        try await watchDesktopFrames(connection) { frame in
            try display.draw(frame?.jpeg)
        }
    }
    let signals = [SIGINT, SIGTERM].map { number in
        let previous = signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler { task.cancel() }
        source.resume()
        return (number, previous, source)
    }
    defer {
        display.restore()
        for (number, previous, source) in signals {
            source.cancel()
            signal(number, previous)
        }
    }
    do {
        try await task.value
    } catch where task.isCancelled {
        // Ctrl+C exits the viewer and restores the caller's terminal.
    }
}

private final class TerminalDesktopView {
    private let output = FileHandle.standardOutput
    private var image: CGImage?
    private var lastSize = (0, 0)
    private var active = false

    func draw(_ jpeg: Data?) throws {
        if let jpeg {
            guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
                  let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw Failure("Cannot decode the live desktop frame")
            }
            image = decoded
        }
        guard let image else { return }

        var window = winsize()
        guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &window) == 0 else {
            throw Failure("Cannot read the terminal window size")
        }
        let size = (Int(window.ws_col), Int(window.ws_row))
        guard size.0 >= 2, size.1 >= 2, jpeg != nil || lastSize != size else { return }

        var screen = ""
        if !active {
            screen += "\u{1b}[?1049h\u{1b}[?25l"
            active = true
        }
        screen += "\u{1b}[H"
        screen += String("Agent Desktop · Read only · Ctrl+C to stop".prefix(size.0 - 1))
        screen += "\u{1b}[K\r\n"

        // Two stacked pixels per character approximate the aspect of a
        // terminal cell. Leave one column free to avoid automatic wrapping.
        let scale = min(Double(min(size.0 - 1, 300)) / Double(image.width),
                        Double(min(size.1 - 1, 150) * 2) / Double(image.height))
        let width = max(1, Int(Double(image.width) * scale))
        let rows = max(1, Int(Double(image.height) * scale) / 2)
        guard let bitmap = CGContext(data: nil, width: width, height: rows * 2,
                                     bitsPerComponent: 8, bytesPerRow: width * 4,
                                     space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let data = bitmap.data else { throw Failure("Cannot resize the desktop frame") }
        bitmap.interpolationQuality = .medium
        bitmap.draw(image, in: CGRect(x: 0, y: 0, width: width, height: rows * 2))
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        for row in 0..<rows {
            var foreground = -1
            var background = -1
            for column in 0..<width {
                let upper = ((row * 2) * width + column) * 4
                let lower = upper + width * 4
                let top = Self.color(pixels + upper)
                let bottom = Self.color(pixels + lower)
                if top != foreground {
                    screen += "\u{1b}[38;5;\(top)m"
                    foreground = top
                }
                if bottom != background {
                    screen += "\u{1b}[48;5;\(bottom)m"
                    background = bottom
                }
                screen += "▀"
            }
            screen += "\u{1b}[0m\u{1b}[K"
            if row + 1 < rows { screen += "\r\n" }
        }
        screen += "\u{1b}[J"
        try output.write(contentsOf: Data(screen.utf8))
        lastSize = size
    }

    func restore() {
        guard active else { return }
        try? output.write(contentsOf: Data("\u{1b}[0m\u{1b}[?25h\u{1b}[?1049l".utf8))
    }

    private static let cube: [Int] = (0...255).map { value in
        switch value {
        case 0...47: return 0
        case 48...114: return 1
        case 115...154: return 2
        case 155...194: return 3
        case 195...234: return 4
        default: return 5
        }
    }

    private static func color(_ pixel: UnsafePointer<UInt8>) -> Int {
        let red = Int(pixel[0]), green = Int(pixel[1]), blue = Int(pixel[2])
        if max(red, green, blue) - min(red, green, blue) <= 10 {
            let gray = (red + green + blue) / 3
            if gray < 4 { return 16 }
            if gray > 248 { return 231 }
            return 232 + min(23, max(0, (gray - 3) / 10))
        }
        return 16 + 36 * cube[red] + 6 * cube[green] + cube[blue]
    }
}
