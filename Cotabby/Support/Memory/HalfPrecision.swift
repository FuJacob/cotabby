import Accelerate
import Foundation

/// File overview:
/// Converts embedding vectors to and from IEEE half precision, the form memory stores and keeps
/// them in (half the bytes of Float32, with no measurable loss for cosine similarity).
///
/// Why bit patterns (`UInt16`) instead of Swift's `Float16`: `Float16` does not exist on Intel
/// Macs, and Cotabby ships a universal binary. vImage converts between the two layouts on both
/// architectures, vectorized.
nonisolated enum HalfPrecision {
    static func encode(_ values: [Float]) -> [UInt16] {
        guard !values.isEmpty else { return [] }
        var output = [UInt16](repeating: 0, count: values.count)
        values.withUnsafeBufferPointer { input in
            output.withUnsafeMutableBufferPointer { out in
                var source = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: input.baseAddress!), height: 1,
                                           width: vImagePixelCount(values.count), rowBytes: values.count * 4)
                var target = vImage_Buffer(data: out.baseAddress!, height: 1,
                                           width: vImagePixelCount(values.count), rowBytes: values.count * 2)
                vImageConvert_PlanarFtoPlanar16F(&source, &target, 0)
            }
        }
        return output
    }

    static func decode(_ halves: [UInt16]) -> [Float] {
        guard !halves.isEmpty else { return [] }
        var output = [Float](repeating: 0, count: halves.count)
        halves.withUnsafeBufferPointer { input in
            output.withUnsafeMutableBufferPointer { out in
                var source = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: input.baseAddress!), height: 1,
                                           width: vImagePixelCount(halves.count), rowBytes: halves.count * 2)
                var target = vImage_Buffer(data: out.baseAddress!, height: 1,
                                           width: vImagePixelCount(halves.count), rowBytes: halves.count * 4)
                vImageConvert_Planar16FtoPlanarF(&source, &target, 0)
            }
        }
        return output
    }
}
