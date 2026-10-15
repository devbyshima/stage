// Makes the app icon, an Icon Composer document (Stage/AppIcon.icon), and the
// logo with its wordmark. The logo is a doodle, drawn in parts by
// scripts/make_doodles.py in the style of the empty screen, so run that first:
//
//   python3 scripts/make_doodles.py
//   swiftc -module-cache-path $TMPDIR/mc scripts/make_icon.swift -o $TMPDIR/make_icon && $TMPDIR/make_icon
//
// Light mode: the screen in white on the brand green, the dot still red. Dark
// mode: the logo in its own colours on the system's dark background. The gap round the dot is a
// hole in the screen, so either background shows through it.
//
// Centring goes by what shows, not by the drawing's canvas, which has a
// margin. The script renders the finished icon in both appearances with
// Icon Composer's ictool, into design/, and prints the margins round the mark
// in each as a check.
import AppKit

func svg(_ name: String) -> NSImage {
    guard let image = NSImage(contentsOf: URL(filePath: "design/logo/\(name).svg")) else {
        fatalError("No logo yet: run python3 scripts/make_doodles.py first.")
    }
    return image
}

let face = svg("Logo-Face"), edge = svg("Logo-Edge"), bite = svg("Logo-Bite"), dot = svg("Logo-Dot"), whole = svg("Logo")
let logoSize = whole.size

/// The icon's canvas, and how tall the mark's visible part is on it.
let canvas = 1024
let markShare: CGFloat = 0.6
/// The brand green, light mode's background.
let brandGreen = "srgb:0.00000,0.85098,0.34118,1.00000"
/// The edge under the screen, in light mode: white let partly through, so it
/// still reads as the screen's darker side.
let lightEdgeOpacity: CGFloat = 0.5

func bitmap(_ width: Int, _ height: Int) -> NSBitmapImageRep {
    NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                     bytesPerRow: 0, bitsPerPixel: 0)!
}

func drawing(into rep: NSBitmapImageRep, _ body: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    body()
    NSGraphicsContext.restoreGraphicsState()
}

/// The box round every pixel that passes `counts`, in drawing coordinates
/// (origin bottom left), optionally only inside `area`.
func bounds(of rep: NSBitmapImageRep, inside area: CGRect? = nil, where counts: (NSColor) -> Bool) -> CGRect {
    let width = rep.pixelsWide, height = rep.pixelsHigh
    var minX = width, maxX = -1, minY = height, maxY = -1
    for row in 0..<height {
        for column in 0..<width {
            let y = height - 1 - row
            if let area, !area.contains(CGPoint(x: column, y: y)) { continue }
            guard let color = rep.colorAt(x: column, y: row), counts(color) else { continue }
            minX = min(minX, column); maxX = max(maxX, column)
            minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
}

let opaque: (NSColor) -> Bool = { $0.alphaComponent > 0.5 }

/// One part of the mark, cut by the bite if asked, in its own colours or
/// in white, on a canvas of `size` with the logo at `rect`.
func part(_ image: NSImage, cut: Bool, white: Bool, opacity: CGFloat = 1, size: Int, rect: CGRect) -> NSBitmapImageRep {
    let shape = bitmap(size, size)
    drawing(into: shape) {
        image.draw(in: rect)
        if cut { bite.draw(in: rect, from: .zero, operation: .destinationOut, fraction: 1) }
        if white {
            NSColor.white.setFill()
            CGRect(x: 0, y: 0, width: size, height: size).fill(using: .sourceAtop)
        }
    }
    guard opacity < 1 else { return shape }
    let faded = bitmap(size, size)
    drawing(into: faded) {
        NSImage(cgImage: shape.cgImage!, size: NSSize(width: size, height: size))
            .draw(in: CGRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .sourceOver, fraction: opacity)
    }
    return faded
}

/// The mark's visible part, in the logo's own points: drawn large, measured.
let visibleLogo: CGRect = {
    let scale: CGFloat = 4
    let size = Int(max(logoSize.width, logoSize.height) * scale)
    let rect = CGRect(x: 0, y: 0, width: logoSize.width * scale, height: logoSize.height * scale)
    let rep = bitmap(size, size)
    drawing(into: rep) {
        for layer in [part(edge, cut: true, white: false, size: size, rect: rect),
                      part(face, cut: true, white: false, size: size, rect: rect),
                      part(dot, cut: false, white: false, size: size, rect: rect)] {
            NSImage(cgImage: layer.cgImage!, size: NSSize(width: size, height: size)).draw(in: CGRect(x: 0, y: 0, width: size, height: size))
        }
    }
    let lit = bounds(of: rep, where: opaque)
    return CGRect(x: lit.minX / scale, y: lit.minY / scale, width: lit.width / scale, height: lit.height / scale)
}()

/// Where the whole logo goes so its visible part is `height` tall, centred on `center`.
func logoRect(visibleHeight height: CGFloat, centeredOn center: CGPoint) -> CGRect {
    let scale = height / visibleLogo.height
    return CGRect(x: center.x - visibleLogo.midX * scale, y: center.y - visibleLogo.midY * scale,
                  width: logoSize.width * scale, height: logoSize.height * scale)
}

// MARK: The Icon Composer document

let document = URL(filePath: "Stage/AppIcon.icon")
let assets = document.appending(path: "Assets")
try? FileManager.default.removeItem(at: document)
try! FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

// Each part on the full canvas, so they line up without any positioning:
// the colours for dark mode, and for light the screen in white with the dot
// keeping its red.
let markRect = logoRect(visibleHeight: CGFloat(canvas) * markShare,
                        centeredOn: CGPoint(x: canvas / 2, y: canvas / 2))
let parts: [(name: String, image: NSImage, cut: Bool, lightWhite: Bool, lightOpacity: CGFloat)] = [
    ("Edge", edge, true, true, lightEdgeOpacity),
    ("Face", face, true, true, 1),
    ("Dot", dot, false, false, 1),
]
for item in parts {
    for (suffix, light) in [("", false), ("-Light", true)] {
        let white = light && item.lightWhite
        let rep = part(item.image, cut: item.cut, white: white, opacity: light ? item.lightOpacity : 1, size: canvas, rect: markRect)
        try! rep.representation(using: .png, properties: [:])!.write(to: assets.appending(path: "\(item.name)\(suffix).png"))
    }
}

// The front layer first. The mark stays flat, as the doodles are, with only
// a soft shadow under it.
let layers = parts.reversed().map { item in
    """
        {
          "name" : "\(item.name)",
          "image-name-specializations" : [
            { "value" : "\(item.name)-Light.png" },
            { "appearance" : "dark", "value" : "\(item.name).png" }
          ],
          "glass" : false
        }
    """
}.joined(separator: ",\n")
let json = """
{
  "fill-specializations" : [
    { "value" : { "solid" : "\(brandGreen)" } },
    { "appearance" : "dark", "value" : "system-dark" }
  ],
  "groups" : [
    {
      "name" : "Mark",
      "layers" : [
\(layers)
      ],
      "shadow" : { "kind" : "neutral", "opacity" : 0.4 },
      "specular" : false,
      "translucency" : { "enabled" : false, "value" : 0 }
    }
  ],
  "supported-platforms" : {
    "squares" : [ "macOS" ]
  }
}

"""
try! json.write(to: document.appending(path: "icon.json"), atomically: false, encoding: .utf8)

// MARK: The check

let ictool = "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
for (rendition, file) in [("Default", "design/AppIcon-light.png"), ("Dark", "design/AppIcon-dark.png")] {
    let process = Process()
    process.executableURL = URL(filePath: ictool)
    process.arguments = [document.path, "--export-image", "--output-file", file, "--platform", "macOS",
                         "--rendition", rendition, "--width", "1024", "--height", "1024", "--scale", "1"]
    process.standardOutput = FileHandle.nullDevice
    try! process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0, let data = try? Data(contentsOf: URL(filePath: file)),
          let rendered = NSBitmapImageRep(data: data) else {
        print("\(rendition): ictool could not render the icon")
        continue
    }
    // The icon's shape (whatever isn't transparent), and the mark: anything
    // well off the background's colour, sampled at the middle of the left
    // side, leaving out the shape's lit rim and rounded corners.
    let shape = bounds(of: rendered, where: opaque)
    let background = rendered.colorAt(x: Int(shape.minX) + 80, y: rendered.pixelsHigh / 2)!.usingColorSpace(.deviceRGB)!
    let mark = bounds(of: rendered, inside: shape.insetBy(dx: 140, dy: 140)) { color in
        guard let c = color.usingColorSpace(.deviceRGB), c.alphaComponent > 0.5 else { return false }
        let distance = abs(c.redComponent - background.redComponent) + abs(c.greenComponent - background.greenComponent)
            + abs(c.blueComponent - background.blueComponent)
        return distance > 0.25
    }
    print(String(format: "\(rendition): margins left %.0f, right %.0f, top %.0f, bottom %.0f",
                 mark.minX - shape.minX, shape.maxX - mark.maxX, shape.maxY - mark.maxY, mark.minY - shape.minY))
}

// MARK: The wordmark

// The logo with its wordmark, in Gochi Hand, on black, for anywhere outside the app.
CTFontManagerRegisterFontsForURL(URL(filePath: "Stage/Resources/Fonts/GochiHand-Regular.ttf") as CFURL, .process, nil)
let word = NSAttributedString(string: "Stage", attributes: [
    .font: NSFont(name: "GochiHand-Regular", size: 330)!,
    .foregroundColor: NSColor(white: 244 / 255, alpha: 1),
])
let markHeight: CGFloat = 400
let markWidth = visibleLogo.width * markHeight / visibleLogo.height
// The word's own lit box, to centre its letters rather than its line height.
let wordRep = bitmap(Int(word.size().width) + 40, Int(word.size().height) + 40)
drawing(into: wordRep) { word.draw(at: NSPoint(x: 20, y: 20)) }
let wordInk = bounds(of: wordRep, where: opaque)
let gap: CGFloat = 90
let lockupSize = CGSize(width: 1800, height: 720)
let left = (lockupSize.width - (markWidth + gap + wordInk.width)) / 2
let lockup = bitmap(Int(lockupSize.width), Int(lockupSize.height))
drawing(into: lockup) {
    NSColor.black.setFill()
    CGRect(origin: .zero, size: lockupSize).fill()
    whole.draw(in: logoRect(visibleHeight: markHeight, centeredOn: CGPoint(x: left + markWidth / 2, y: lockupSize.height / 2)))
    word.draw(at: NSPoint(x: left + markWidth + gap - (wordInk.minX - 20), y: lockupSize.height / 2 - (wordInk.midY - 20)))
}
try! lockup.representation(using: .png, properties: [:])!.write(to: URL(filePath: "design/Stage-logo.png"))
let group = bounds(of: lockup, where: { opaque($0) && max($0.redComponent, $0.greenComponent, $0.blueComponent) > 0.25 })
print(String(format: "logo: margins left %.0f, right %.0f, top %.0f, bottom %.0f",
             group.minX, lockupSize.width - group.maxX, lockupSize.height - group.maxY, group.minY))
