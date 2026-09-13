#!/usr/bin/env swift

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 3 else {
    fputs("usage: prepare-app-icon.swift INPUT.png OUTPUT.png\n", stderr)
    exit(64)
}

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2]) as CFURL

guard let source = CGImageSourceCreateWithURL(inputURL, nil),
      let sourceImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
else {
    fputs("could not read input image\n", stderr)
    exit(65)
}

let colorSpace = CGColorSpaceCreateDeviceRGB()
let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
    | CGImageAlphaInfo.premultipliedLast.rawValue
let sourceWidth = sourceImage.width
let sourceHeight = sourceImage.height
let sourceBytesPerRow = sourceWidth * 4
var sourcePixels = [UInt8](repeating: 0, count: sourceBytesPerRow * sourceHeight)

let maskedImage: CGImage? = sourcePixels.withUnsafeMutableBytes { bytes in
    guard let address = bytes.baseAddress,
          let sourceContext = CGContext(
              data: address,
              width: sourceWidth,
              height: sourceHeight,
              bitsPerComponent: 8,
              bytesPerRow: sourceBytesPerRow,
              space: colorSpace,
              bitmapInfo: bitmapInfo
          )
    else { return nil }

    sourceContext.draw(
        sourceImage,
        in: CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight)
    )

    // ImageGen rendered an opaque checkerboard around the squircle. Flood-fill
    // the low-chroma background from the canvas edges; the saturated blue rim
    // naturally forms the exact icon boundary and preserves its continuous curve.
    let pixels = address.assumingMemoryBound(to: UInt8.self)
    let pixelCount = sourceWidth * sourceHeight
    var outside = [UInt8](repeating: 0, count: pixelCount)
    var queue: [Int] = []
    queue.reserveCapacity(pixelCount / 2)

    func enqueueBackground(_ index: Int) {
        guard outside[index] == 0 else { return }
        let offset = index * 4
        let red = Int(pixels[offset])
        let green = Int(pixels[offset + 1])
        let blue = Int(pixels[offset + 2])
        let alpha = Int(pixels[offset + 3])
        let chroma = max(red, green, blue) - min(red, green, blue)
        guard alpha == 0 || chroma <= 32 else { return }
        outside[index] = 1
        queue.append(index)
    }

    for x in 0..<sourceWidth {
        enqueueBackground(x)
        enqueueBackground((sourceHeight - 1) * sourceWidth + x)
    }
    for y in 0..<sourceHeight {
        enqueueBackground(y * sourceWidth)
        enqueueBackground(y * sourceWidth + sourceWidth - 1)
    }

    var cursor = 0
    while cursor < queue.count {
        let index = queue[cursor]
        cursor += 1
        let x = index % sourceWidth
        let y = index / sourceWidth
        if x > 0 { enqueueBackground(index - 1) }
        if x + 1 < sourceWidth { enqueueBackground(index + 1) }
        if y > 0 { enqueueBackground(index - sourceWidth) }
        if y + 1 < sourceHeight { enqueueBackground(index + sourceWidth) }
    }

    for index in 0..<pixelCount where outside[index] == 1 {
        let offset = index * 4
        pixels[offset] = 0
        pixels[offset + 1] = 0
        pixels[offset + 2] = 0
        pixels[offset + 3] = 0
    }
    return sourceContext.makeImage()
}

let canvasSize = 1_024
let canvas = CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize)
guard let maskedImage,
      let outputContext = CGContext(
          data: nil,
          width: canvasSize,
          height: canvasSize,
          bitsPerComponent: 8,
          bytesPerRow: 0,
          space: colorSpace,
          bitmapInfo: bitmapInfo
      )
else {
    fputs("could not create bitmap context\n", stderr)
    exit(70)
}

outputContext.clear(canvas)
outputContext.interpolationQuality = .high
outputContext.draw(maskedImage, in: canvas)

guard let outputImage = outputContext.makeImage(),
      let destination = CGImageDestinationCreateWithURL(
          outputURL,
          UTType.png.identifier as CFString,
          1,
          nil
      )
else {
    fputs("could not create output image\n", stderr)
    exit(73)
}

CGImageDestinationAddImage(destination, outputImage, nil)
guard CGImageDestinationFinalize(destination) else {
    fputs("could not write output image\n", stderr)
    exit(74)
}
