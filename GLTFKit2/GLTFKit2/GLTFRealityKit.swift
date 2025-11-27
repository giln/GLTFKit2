#if !os(tvOS)

    import Accelerate
    import ModelIO
    import RealityKit

    @available(macOS 12.0, iOS 15.0, visionOS 1.0, *)
    public struct GLTFMaterialBindingsComponent: Component {
        public struct Binding {
            public let partID: String
            public let primitive: GLTFPrimitive
        }

        public var bindings: [String: Binding]

        public init(bindings: [String: Binding]) {
            self.bindings = bindings
        }
    }

    #if os(macOS)
        typealias PlatformColor = NSColor
    #else
        typealias PlatformColor = UIColor
    #endif

    // Omit support for RealityKit entirely on platforms (such as macOS 11 Big Sur)
    // that don't have the required API or language features from the RealityKit 2
    // era.
    // We would, of course, prefer to use a check that actually corresponds to the
    // minimum supported SDKs (macOS 12 Monterey, iOS 15, etc.), but we lack the
    // tools necessary to do so, so we fall back on compiler version.
    // https://forums.swift.org/t/do-we-need-something-like-if-available/40349/34
    #if compiler(>=5.6)

        func packedStride(for accessor: GLTFAccessor) -> Int {
            var size = 0
            switch accessor.componentType {
            case .byte: fallthrough
            case .unsignedByte:
                size = 1
            case .short: fallthrough
            case .unsignedShort:
                size = 2
            case .unsignedInt: fallthrough
            case .float:
                size = 4
            default:
                break
            }
            switch accessor.dimension {
            case .scalar:
                break
            case .vector2:
                size *= 2
            case .vector3:
                size *= 3
            case .vector4:
                size *= 4
            default:
                break
            }
            return size
        }

        func packedFloatArray(for accessor: GLTFAccessor) -> [Float]? {
            if accessor.dimension != .scalar { return nil }
            if accessor.componentType != .float {
                print(
                    "[GLTFKit2] Unsupported scalar component type for conversion to packed float array: \(accessor.componentType). Please file an issue if you see this message."
                )
                return nil
            }
            guard let bufferView = accessor.bufferView else { return nil }
            guard let bufferData = bufferView.buffer.data else { return nil }
            let valueCount = accessor.count
            let offset = bufferView.offset + accessor.offset
            let inputStride = bufferView.stride == 0 ? MemoryLayout<Float>
                .stride : bufferView.stride
            let values =
                [Float](unsafeUninitializedCapacity: valueCount) { buffer, initializedCount in
                    bufferData.withUnsafeBytes { rawPtr in
                        // TODO: Fast path when stride == 4
                        for i in 0 ..< valueCount {
                            guard let floatPtr = rawPtr.baseAddress?
                                .advanced(by: offset + inputStride * i)
                                .assumingMemoryBound(to: Float.self)
                            else { initializedCount = 0; return }
                            buffer[i] = floatPtr.pointee
                        }
                        initializedCount = valueCount
                    }
                }
            return values
        }

        func packedFloat2Array(
            for accessor: GLTFAccessor,
            flipVertically: Bool = false
        ) -> [SIMD2<Float>]? {
            if accessor.dimension != .vector2 {
                return nil
            }
            if accessor.componentType != .float {
                print(
                    "[GLTFKit2] Unsupported vector component type for conversion to packed float2 array: \(accessor.componentType). Please file an issue if you see this message."
                )
                return nil
            }

            guard let bufferView = accessor.bufferView else { return nil }
            guard let bufferData = bufferView.buffer.data else { return nil }

            let vertexCount = accessor.count
            let offset = bufferView.offset + accessor.offset
            let elementStride = (bufferView.stride != 0) ? bufferView
                .stride : packedStride(for: accessor)
            let vectors =
                [SIMD2<
                    Float
                >](unsafeUninitializedCapacity: vertexCount) { buffer, initializedCount in
                    bufferData.withUnsafeBytes { rawPtr in
                        guard let basePtr = rawPtr.baseAddress?
                            .advanced(by: offset)
                        else { initializedCount = 0; return }
                        for v in 0 ..< vertexCount {
                            let elementPtr = basePtr
                                .advanced(by: elementStride * v)
                                .bindMemory(to: Float.self, capacity: 3)
                            buffer[v] = SIMD2(elementPtr[0],
                                              flipVertically ? 1 -
                                                  elementPtr[1] : elementPtr[1])
                        }
                        initializedCount = vertexCount
                    }
                }
            return vectors
        }

        func packedFloat3Array(for accessor: GLTFAccessor) -> [SIMD3<Float>]? {
            if accessor.dimension != .vector3, accessor.dimension != .vector4 {
                return nil
            }

            let componentCount = (accessor.dimension == .vector4) ? 4 : 3
            let vectorCount = accessor.count

            // Use the shared helper so sparse accessors are expanded to their dense
            // representation before we reinterpret the bytes as floats.
            let packedData = GLTFPackedDataForAccessor(accessor) as Data
            let floatData = GLTFTransformPackedDataToFloat(
                packedData,
                accessor
            ) as Data

            var vectors = [SIMD3<Float>]()
            vectors.reserveCapacity(vectorCount)

            floatData.withUnsafeBytes { rawBuffer in
                guard let floatPtr = rawBuffer.bindMemory(to: Float.self)
                    .baseAddress
                else { return }
                for index in 0 ..< vectorCount {
                    let base = floatPtr.advanced(by: index * componentCount)
                    vectors.append(SIMD3(base[0], base[1], base[2]))
                }
            }

            return vectors
        }

        func packedQuatfArray(for accessor: GLTFAccessor) -> [simd_quatf]? {
            if accessor.dimension != .vector4 {
                return nil
            }
            if accessor.componentType != .float {
                print(
                    "[GLTFKit2] Unsupported quaternion component type: \(accessor.componentType). Please file an issue if you see this message."
                )
                return nil
            }
            guard let bufferView = accessor.bufferView else { return nil }
            guard let bufferData = bufferView.buffer.data else { return nil }
            let vertexCount = accessor.count
            let offset = bufferView.offset + accessor.offset
            let elementStride = (bufferView.stride != 0) ? bufferView
                .stride : packedStride(for: accessor)
            let vectors =
                [simd_quatf](unsafeUninitializedCapacity: vertexCount) { buffer, initializedCount in
                    bufferData.withUnsafeBytes { rawPtr in
                        guard let basePtr = rawPtr.baseAddress?
                            .advanced(by: offset)
                        else { initializedCount = 0; return }
                        for v in 0 ..< vertexCount {
                            let elementPtr = basePtr
                                .advanced(by: elementStride * v)
                                .bindMemory(to: Float.self, capacity: 4)
                            buffer[v] = simd_quaternion(
                                elementPtr[0],
                                elementPtr[1],
                                elementPtr[2],
                                elementPtr[3]
                            )
                        }
                        initializedCount = vertexCount
                    }
                }
            return vectors
        }

        func packedFloat4Array(for accessor: GLTFAccessor) -> [SIMD4<Float>]? {
            if accessor.dimension != .vector4 {
                return nil
            }
            if accessor.componentType != .float {
                print(
                    "[GLTFKit2] Unsupported component type for conversion to packed float4 array: \(accessor.componentType). Please file an issue if you see this message."
                )
                return nil
            }

            guard let bufferView = accessor.bufferView else { return nil }
            guard let bufferData = bufferView.buffer.data else { return nil }

            let vertexCount = accessor.count
            let offset = bufferView.offset + accessor.offset
            let elementStride = (bufferView.stride != 0) ? bufferView
                .stride : packedStride(for: accessor)
            let vectors =
                [SIMD4<
                    Float
                >](unsafeUninitializedCapacity: vertexCount) { buffer, initializedCount in
                    bufferData.withUnsafeBytes { rawPtr in
                        guard let basePtr = rawPtr.baseAddress?
                            .advanced(by: offset)
                        else { initializedCount = 0; return }
                        for v in 0 ..< vertexCount {
                            let elementPtr = basePtr
                                .advanced(by: elementStride * v)
                                .bindMemory(to: Float.self, capacity: 4)
                            buffer[v] = SIMD4(elementPtr[0], elementPtr[1],
                                              elementPtr[2],
                                              elementPtr[3])
                        }
                        initializedCount = vertexCount
                    }
                }
            return vectors
        }

        func packedUInt32Array(for accessor: GLTFAccessor) -> [UInt32]? {
            guard let bufferView = accessor.bufferView else { return nil }
            guard let bufferData = bufferView.buffer.data else { return nil }

            let indexCount = accessor.count
            let offset = bufferView.offset + accessor.offset
            let indices =
                [UInt32](unsafeUninitializedCapacity: indexCount) { buffer, initializedCount in
                    bufferData.withUnsafeBytes { rawPtr in
                        switch accessor.componentType {
                        case .unsignedByte:
                            guard let ubytePtr = rawPtr.baseAddress?
                                .advanced(by: offset)
                                .bindMemory(
                                    to: UInt8.self,
                                    capacity: indexCount
                                )
                            else { initializedCount = 0; return }
                            for i in 0 ..< indexCount {
                                buffer[i] = UInt32(ubytePtr[i])
                            }
                            initializedCount = indexCount
                        case .unsignedShort:
                            guard let ushortPtr = rawPtr.baseAddress?
                                .advanced(by: offset)
                                .bindMemory(
                                    to: UInt16.self,
                                    capacity: indexCount
                                )
                            else { initializedCount = 0; return }
                            for i in 0 ..< indexCount {
                                buffer[i] = UInt32(ushortPtr[i])
                            }
                            initializedCount = indexCount
                        case .unsignedInt:
                            guard let uintPtr = rawPtr.baseAddress?
                                .advanced(by: offset)
                            else { initializedCount = 0; return }
                            memcpy(
                                UnsafeMutableRawPointer(buffer.baseAddress!),
                                uintPtr,
                                MemoryLayout<UInt32>.stride * indexCount
                            )
                            initializedCount = indexCount
                        default:
                            break
                        }
                    }
                }
            return indices
        }

        func packedUShort4Array(for accessor: GLTFAccessor)
            -> [SIMD4<UInt16>]?
        {
            if (accessor.componentType != .unsignedByte && accessor
                .componentType != .unsignedShort) ||
                (accessor.dimension != .vector4)
            {
                return nil
            }
            guard let bufferView = accessor.bufferView else { return nil }
            guard let bufferData = bufferView.buffer.data else { return nil }

            let vectorCount = accessor.count
            let offset = bufferView.offset + accessor.offset
            let vectors =
                [SIMD4<
                    UInt16
                >](unsafeUninitializedCapacity: vectorCount) { destPtr, initializedCount in
                    bufferData.withUnsafeBytes { sourcePtr in
                        initializedCount = 0
                        guard let accessorBase = sourcePtr.baseAddress?
                            .advanced(by: offset) else { return }
                        switch accessor.componentType {
                        case .unsignedByte:
                            let sourceStride = (bufferView.stride == 0) ?
                                MemoryLayout<SIMD4<UInt8>>.stride : bufferView
                                .stride
                            for i in 0 ..< vectorCount {
                                let components = accessorBase
                                    .advanced(by: sourceStride * i)
                                    .bindMemory(to: UInt8.self, capacity: 4)
                                destPtr[i] = SIMD4<UInt16>(
                                    UInt16(components[0]),
                                    UInt16(components[1]),
                                    UInt16(components[2]),
                                    UInt16(components[3])
                                )
                            }
                            initializedCount = vectorCount
                        case .unsignedShort:
                            let sourceStride = (bufferView.stride == 0) ?
                                MemoryLayout<SIMD4<UInt16>>.stride : bufferView
                                .stride
                            if sourceStride == MemoryLayout<SIMD4<UInt16>>
                                .stride
                            {
                                // Source buffer view is packed; copy everything in one shot
                                memcpy(
                                    UnsafeMutableRawPointer(destPtr
                                        .baseAddress!),
                                    accessorBase,
                                    sourceStride * vectorCount
                                )
                                initializedCount = vectorCount
                            } else {
                                // We're not packed, so copy each vector individually
                                for i in 0 ..< vectorCount {
                                    let components = accessorBase
                                        .advanced(by: sourceStride * i)
                                        .bindMemory(
                                            to: UInt16.self,
                                            capacity: 4
                                        )
                                    destPtr[i] = SIMD4<UInt16>(components[0],
                                                               components[1],
                                                               components[2],
                                                               components[3])
                                }
                                initializedCount = vectorCount
                            }
                        default:
                            break
                        }
                    }
                }
            return vectors
        }

        func packedFloat4x4(for accessor: GLTFAccessor) -> [simd_float4x4]? {
            if (accessor.componentType != .float) ||
                (accessor.dimension != .matrix4)
            {
                return nil
            }
            guard let bufferView = accessor.bufferView else { return nil }
            guard let bufferData = bufferView.buffer.data else { return nil }

            let sourceStride = bufferView
                .stride == 0 ? MemoryLayout<simd_float4x4>
                .stride : bufferView.stride
            let offset = bufferView.offset + accessor.offset
            let matrices = [simd_float4x4]
                .init(unsafeUninitializedCapacity: accessor
                    .count) { destPtr, initializedCount in
                        bufferData.withUnsafeBytes { sourceBase in
                            guard let accessorBase = sourceBase.baseAddress?
                                .advanced(by: offset)
                            else { initializedCount = 0; return }
                            if sourceStride == MemoryLayout<simd_float4x4>
                                .stride
                            {
                                memcpy(
                                    &destPtr[0],
                                    accessorBase,
                                    sourceStride * accessor.count
                                )
                            } else {
                                for i in 0 ..< accessor.count {
                                    let srcMatrix = accessorBase
                                        .advanced(by: sourceStride * i)
                                    memcpy(
                                        &destPtr[i],
                                        srcMatrix,
                                        MemoryLayout<simd_float4x4>.size
                                    )
                                }
                            }
                            initializedCount = accessor.count
                        }
                }
            return matrices
        }

        func convertMinMipFilters(from filter: GLTFMinMipFilter)
            -> (MTLSamplerMinMagFilter, MTLSamplerMipFilter)
        {
            switch filter {
            case .linear:
                return (.linear, .notMipmapped)
            case .nearest:
                return (.nearest, .notMipmapped)
            case .nearestNearest:
                return (.nearest, .nearest)
            case .linearNearest:
                return (.linear, .nearest)
            case .nearestLinear:
                return (.nearest, .linear)
            default:
                return (.linear, .linear)
            }
        }

        func convertMagFilter(from filter: GLTFMagFilter)
            -> MTLSamplerMinMagFilter
        {
            switch filter {
            case .nearest:
                return .nearest
            default:
                return .linear
            }
        }

        func convertAddressMode(from addressMode: GLTFAddressMode)
            -> MTLSamplerAddressMode
        {
            switch addressMode {
            case .repeat:
                return .repeat
            case .mirroredRepeat:
                return .mirrorRepeat
            default:
                return .clampToEdge
            }
        }

        extension MTLSamplerDescriptor {
            convenience init(from sampler: GLTFTextureSampler) {
                self.init()
                normalizedCoordinates = true
                let (
                    minFilter,
                    mipFilter
                ) = convertMinMipFilters(from: sampler.minMipFilter)
                self.minFilter = minFilter
                self.mipFilter = mipFilter
                magFilter = convertMagFilter(from: sampler.magFilter)
                sAddressMode = convertAddressMode(from: sampler.wrapS)
                tAddressMode = convertAddressMode(from: sampler.wrapT)
            }
        }

        fileprivate class UniqueNameGenerator {
            private var countsForPrefixes = [String: Int]()

            func nextUniqueName(prefix: String) -> String {
                if let existingCount = countsForPrefixes[prefix] {
                    countsForPrefixes[prefix] = existingCount + 1
                    return "\(prefix)\(existingCount + 1)"
                } else {
                    countsForPrefixes[prefix] = 1
                    return "\(prefix)"
                }
            }
        }

        #if compiler(>=6.0) || os(visionOS)
            /// Tracks the RealityKit identifiers and ordering that we assign to a mesh's
            /// blend shapes so later animation and entity wiring can address them
            /// consistently.
            @available(macOS 15.0, iOS 18.0, visionOS 2.0, *)
            fileprivate struct BlendShapeInfo {
                var weightNames: [String]
                var setInfos: [BlendShapeWeightsData.ID: [String]] = [:]
            }
        #endif

        @available(macOS 12.0, iOS 15.0, *)
        class GLTFRealityKitResourceContext {
            enum ColorMask: Int {
                case red
                case green
                case blue
                case all

                var textureSwizzle: MTLTextureSwizzleChannels {
                    switch self {
                    case .red:
                        return MTLTextureSwizzleChannels(
                            red: .red,
                            green: .red,
                            blue: .red,
                            alpha: .alpha
                        )
                    case .green:
                        return MTLTextureSwizzleChannels(
                            red: .green,
                            green: .green,
                            blue: .green,
                            alpha: .alpha
                        )
                    case .blue:
                        return MTLTextureSwizzleChannels(
                            red: .blue,
                            green: .blue,
                            blue: .blue,
                            alpha: .alpha
                        )
                    case .all:
                        return MTLTextureSwizzleChannels(
                            red: .red,
                            green: .green,
                            blue: .blue,
                            alpha: .alpha
                        )
                    }
                }
            }

            let device: MTLDevice
            let commandQueue: MTLCommandQueue
            private var cgImagesForImageIdentifiers = [UUID: CGImage]()
            private var textureResourcesForImageIdentifiers =
                [UUID: [(RealityKit.TextureResource, ColorMask)]]()
            #if compiler(>=6.0) || os(visionOS)
                var jointIndexRemapsBySkeletonID: [String: [UInt16]] = [:]
            #endif

            var defaultMaterial: any Material {
                return RealityKit.SimpleMaterial(
                    color: .init(white: 0.5, alpha: 1.0),
                    isMetallic: false
                )
            }

            init() {
                guard let metalDevice = MTLCreateSystemDefaultDevice() else {
                    fatalError("Unable to create Metal system default device")
                }
                device = metalDevice
                commandQueue = metalDevice.makeCommandQueue()!
            }

            @MainActor func texture(
                for gltfTextureParams: GLTFTextureParams,
                channels: ColorMask,
                semantic: RealityKit.TextureResource.Semantic
            ) -> RealityKit.PhysicallyBasedMaterial.Texture? {
                let gltfTexture = gltfTextureParams.texture
                guard let image = (gltfTexture.basisUSource ?? gltfTexture
                    .webpSource ?? gltfTexture.source) else { return nil }
                if let resource = textureResource(
                    for: image,
                    channels: channels,
                    semantic: semantic
                ) {
                    let descriptor = MTLSamplerDescriptor(from: gltfTexture
                        .sampler ?? GLTFTextureSampler())
                    let sampler = MaterialParameters.Texture.Sampler(descriptor)
                    return RealityKit.PhysicallyBasedMaterial.Texture(
                        resource,
                        sampler: sampler
                    )
                }
                return nil
            }

            @MainActor func textureResource(
                for gltfImage: GLTFImage,
                channels: ColorMask,
                semantic: RealityKit.TextureResource.Semantic
            ) -> RealityKit.TextureResource? {
                let existingResources =
                    textureResourcesForImageIdentifiers[gltfImage.identifier]
                if let existingMatch = existingResources?
                    .first(where: { $0.1 == channels })?.0
                {
                    return existingMatch
                }

                #if compiler(>=6.0)
                    if #available(macOS 15.0, iOS 18.0, visionOS 2.0, *) {
                        if gltfImage.inferMediaType() == GLTFMediaTypeKTX2 {
                            let mtlTexture = gltfImage.newTexture(with: device)
                            guard let sourceTexture = mtlTexture
                            else { return nil }
                            do {
                                let lowLevelDesc = LowLevelTexture.Descriptor(
                                    textureType: sourceTexture.textureType,
                                    pixelFormat: sourceTexture.pixelFormat,
                                    width: sourceTexture.width,
                                    height: sourceTexture.height,
                                    depth: sourceTexture.depth,
                                    mipmapLevelCount: sourceTexture
                                        .mipmapLevelCount,
                                    arrayLength: sourceTexture.arrayLength,
                                    textureUsage: [.shaderRead],
                                    swizzle: channels.textureSwizzle
                                )
                                let lowLevelTexture =
                                    try LowLevelTexture(
                                        descriptor: lowLevelDesc
                                    )
                                if let commandBuffer = commandQueue
                                    .makeCommandBuffer()
                                {
                                    let targetTexture = lowLevelTexture
                                        .replace(using: commandBuffer)
                                    if let blitEncoder = commandBuffer
                                        .makeBlitCommandEncoder()
                                    {
                                        blitEncoder.copy(
                                            from: sourceTexture,
                                            to: targetTexture
                                        )
                                        blitEncoder.endEncoding()
                                    }
                                    commandBuffer.commit()
                                }
                                let resource =
                                    try TextureResource(from: lowLevelTexture)
                                if textureResourcesForImageIdentifiers[
                                    gltfImage
                                        .identifier
                                ] != nil {
                                    textureResourcesForImageIdentifiers[
                                        gltfImage
                                            .identifier
                                    ]!.append((resource, channels))
                                } else {
                                    textureResourcesForImageIdentifiers[
                                        gltfImage
                                            .identifier
                                    ] = [(resource, channels)]
                                }
                                return resource
                            } catch {
                                print(
                                    "[GLTFKit2] Error occurred when converting KTX2 texture to RealityKit TextureResource: \(error)"
                                )
                                return nil
                            }
                        }
                    }
                #endif

                var cgImage = cgImagesForImageIdentifiers[gltfImage.identifier]
                if cgImage == nil {
                    cgImage = gltfImage.newCGImage()?.takeRetainedValue()
                    if cgImage != nil {
                        #if os(visionOS)
                            // Image decoding is not as robust on visionOS as on other platforms,
                            // so we "pre-decode" here into a known-good image layout.
                            cgImage = decodeCGImage(cgImage!)
                        #endif
                        cgImagesForImageIdentifiers[gltfImage.identifier] =
                            cgImage
                    }
                }
                guard let originalImage = cgImage else { return nil }

                guard let sourceImage = (channels == .all) ? originalImage :
                    singleChannelImage(from: originalImage, channels: channels)
                else { return nil }

                let options = TextureResource.CreateOptions(semantic: semantic)
                guard let resource = try? TextureResource.generate(
                    from: sourceImage,
                    options: options
                ) else { return nil }
                if textureResourcesForImageIdentifiers[gltfImage.identifier] !=
                    nil
                {
                    textureResourcesForImageIdentifiers[gltfImage.identifier]!
                        .append((resource, channels))
                } else {
                    textureResourcesForImageIdentifiers[gltfImage.identifier] =
                        [(resource, channels)]
                }

                return resource
            }

            func singleChannelImage(
                from cgImage: CGImage,
                channels: ColorMask
            ) -> CGImage? {
                guard cgImage.colorSpace?.model == .rgb else {
                    // Can't extract from a non-RGB[A] image with this method. Fall back to the input image hoping it's monochrome.
                    return cgImage
                }
                guard let inputFormat = vImage_CGImageFormat(cgImage: cgImage)
                else { return nil }
                guard var inputBuffer = try? vImage_Buffer(
                    cgImage: cgImage,
                    format: inputFormat
                ) else { return nil }
                defer { inputBuffer.free() }
                var outputBuffer = vImage_Buffer()
                vImageBuffer_Init(
                    &outputBuffer,
                    inputBuffer.height,
                    inputBuffer.width,
                    inputFormat.bitsPerPixel,
                    vImage_Flags()
                )
                defer { outputBuffer.data.deallocate() }
                var channel = 0
                switch channels {
                case .red: channel = 0; case .green: channel =
                    1; case .blue: channel = 2; default: break
                }
                let outputColorSpace = CGColorSpace(name: CGColorSpace
                    .linearGray)!
                let outputFormat = vImage_CGImageFormat(
                    bitsPerComponent: 8,
                    bitsPerPixel: 8,
                    colorSpace: outputColorSpace,
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none
                        .rawValue),
                    renderingIntent: .defaultIntent
                )!
                vImageExtractChannel_ARGB8888(
                    &inputBuffer,
                    &outputBuffer,
                    channel,
                    vImage_Flags()
                )
                let outputImage = try? outputBuffer
                    .createCGImage(format: outputFormat)
                return outputImage
            }

            func decodeCGImage(_ image: CGImage) -> CGImage? {
                let isSingleChannel = (image.colorSpace?.model == .monochrome)
                let wantsAlpha = ![
                    CGImageAlphaInfo.none,
                    CGImageAlphaInfo.noneSkipLast,
                    CGImageAlphaInfo.noneSkipFirst
                ].contains(image.alphaInfo)
                let bitsPerComponent = 8
                let width = image.width, height = image.height
                let bytesPerPixel = isSingleChannel ? 1 : 4
                let bytesPerRow = bytesPerPixel * width
                let colorSpace =
                    CGColorSpace(name: isSingleChannel ? CGColorSpace
                        .genericGrayGamma2_2 : CGColorSpace.sRGB)!
                var bitmapInfo: UInt32 = 0
                if wantsAlpha {
                    if image.alphaInfo == .alphaOnly {
                        bitmapInfo |= image.alphaInfo.rawValue
                    } else {
                        bitmapInfo |= CGImageAlphaInfo.premultipliedLast
                            .rawValue
                    }
                } else {
                    if isSingleChannel {
                        bitmapInfo |= CGImageAlphaInfo.none.rawValue
                    } else {
                        bitmapInfo |= CGImageAlphaInfo.noneSkipLast.rawValue
                    }
                }
                guard let context = CGContext(
                    data: nil,
                    width: width,
                    height: height,
                    bitsPerComponent: bitsPerComponent,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: bitmapInfo
                ) else { return nil }
                context.draw(
                    image,
                    in: CGRect(x: 0, y: 0, width: width, height: height),
                    byTiling: false
                )
                let image = context.makeImage()
                return image
            }
        }

        @available(macOS 12.0, iOS 15.0, *)
        extension GLTFNode {
            var bindPath: BindTarget.EntityPath {
                if let parent = parent {
                    return parent.bindPath.entity(name ?? "")
                }
                return BindTarget.entity(name ?? "")
            }
        }

        @available(iOS 13.0, *)
        fileprivate extension GLTFTransformSampler {
            func transform(at time: Float) -> Transform {
                let translation = translation.value(at: time)
                let rotation = rotation.value(at: time)
                let scale = scale.value(at: time)
                return Transform(
                    scale: scale,
                    rotation: rotation,
                    translation: translation
                )
            }
        }

        @available(macOS 12.0, iOS 15.0, *)
        public class GLTFRealityKitLoader {
            #if os(macOS)
                let colorSpace =
                    NSColorSpace(cgColorSpace: CGColorSpace(name: CGColorSpace
                            .linearSRGB)!)!
            #endif
            private let nameGenerator = UniqueNameGenerator()
            public static var usdRawAnimationDefinitions: [
                String: AnimationGroup
            ] =
                [:]

            private var pathsForSkeletonIDs: [ /* MeshResource.Skeleton.ID */
                String: BindTarget
                    .EntityPath
            ] = [:]
            private var skeletonIDsByJointName: [
                String: [ /* MeshResource.Skeleton.ID */ String]
            ] =
                [:]
            private var skeletonTransformsByJointName: [String: Transform] = [:]

            private func absoluteTransform(for node: GLTFNode)
                -> simd_float4x4
            {
                var transform = node.matrix
                var current = node.parent
                while let parent = current {
                    transform = parent.matrix * transform
                    current = parent.parent
                }
                return transform
            }

            #if compiler(>=6.0) || os(visionOS)
                private var jointNamesBySkeletonID: [String: [String]] = [:]
                private var restPoseTransformsBySkeletonID: [
                    String: [Transform]
                ] =
                    [:]
                private var mergedSkeletonPlanStorage: Any?
                @available(macOS 15.0, iOS 18.0, visionOS 2.0, *)
                private var mergedSkeletonPlan: MergedSkeletonPlan? {
                    get { mergedSkeletonPlanStorage as? MergedSkeletonPlan }
                    set { mergedSkeletonPlanStorage = newValue }
                }

                /// RealityKit only exposes blend-shape bindings via generated identifiers,
                /// so we memoise per-mesh metadata here to rehydrate weight sets when
                /// meshes are instanced in the entity graph.
                private var blendShapeInfoStorage = [ObjectIdentifier: Any]()
            #endif

            #if compiler(>=6.0) || os(visionOS)
                @available(macOS 15.0, iOS 18.0, visionOS 2.0, *)
                private func blendShapeInfo(for identifier: ObjectIdentifier)
                    -> BlendShapeInfo?
                {
                    return blendShapeInfoStorage[identifier] as? BlendShapeInfo
                }

                @available(macOS 15.0, iOS 18.0, visionOS 2.0, *)
                private func setBlendShapeInfo(
                    _ info: BlendShapeInfo?,
                    for identifier: ObjectIdentifier
                ) {
                    if let info {
                        blendShapeInfoStorage[identifier] = info
                    } else {
                        blendShapeInfoStorage.removeValue(forKey: identifier)
                    }
                }

                @available(macOS 15.0, iOS 18.0, visionOS 2.0, *)
                private struct SkeletonBuildResult {
                    let skeletonName: String
                    let jointNames: [String]
                    let parentIndices: [Int?]
                    let inverseBindPoseMatrices: [simd_float4x4]
                    let restPoseTransforms: [Transform]
                    let jointIndexRemap: [UInt16]
                }

                @available(macOS 15.0, iOS 18.0, visionOS 2.0, *)
                private struct MergedSkeletonPlan {
                    let skeleton: MeshResource.Skeleton
                    let remapBySkin: [ObjectIdentifier: [UInt16]]
                    let restPoseTransforms: [Transform]
                    let jointNames: [String]
                    let skeletonRootTransforms: [String: Transform]
                }
            #endif

            public static func load(from url: URL) async throws -> RealityKit
                .Entity
            {
                let asset = try GLTFAsset(url: url)
                if let scene = asset.defaultScene {
                    return await MainActor.run {
                        return convert(scene: scene, asset: asset)
                    }
                } else {
                    throw NSError(domain: GLTFErrorDomain,
                                  code: 1020,
                                  userInfo: [
                                      NSLocalizedDescriptionKey: "The glTF asset did not specify a default scene",
                                  ])
                }
            }

            @MainActor public static func convert(scene: GLTFScene)
                -> RealityKit
                .Entity
            {
                let instance = GLTFRealityKitLoader()
                return instance.convert(scene: scene, asset: nil)
            }

            @MainActor public static func convert(
                scene: GLTFScene,
                asset: GLTFAsset?
            ) -> RealityKit.Entity {
                GLTFRealityKitLoader.usdRawAnimationDefinitions = [:]
                let instance = GLTFRealityKitLoader()
                return instance.convert(scene: scene, asset: asset)
            }

            @MainActor func convert(
                scene: GLTFScene,
                asset: GLTFAsset? = nil
            ) -> RealityKit.Entity {
                let context = GLTFRealityKitResourceContext()

                #if compiler(>=6.0) || os(visionOS)
                    if #available(macOS 15.0, iOS 18.0, visionOS 2.0, *),
                       mergedSkeletonPlan == nil
                    {
                        mergedSkeletonPlan = prepareMergedSkeletonPlan(
                            asset: asset
                        )
                    }
                #endif

                let rootEntity = Entity()
                rootEntity.name = "glTF_\(scene.name ?? "Scene")_Root"

                do {
                    let rootNodes = try scene.nodes
                        .compactMap {
                            try self.convert(node: $0, context: context)
                        }

                    for rootNode in rootNodes {
                        rootEntity.addChild(rootNode)
                    }
                } catch {
                    fatalError("Error when converting scene: \(error)")
                }

                // TODO: Morph targets

                if #available(macOS 14.0, iOS 17.0, visionOS 2.0, *) {
                    for animation in asset?.animations ?? [] {
                        let rkAnimation = try? convert(animation: animation)
                        rkAnimation?.store(in: rootEntity)
                    }
                }

                return rootEntity
            }

            @available(macOS 15.0, iOS 18.0, visionOS 2.0, *)
            @MainActor func convertBlendshape(
                gltfNode: GLTFNode,
                gltfMesh: GLTFMesh,
                nodeEntity: Entity,
                meshComponent: ModelComponent
            ) {
                let meshIdentifier = ObjectIdentifier(gltfMesh)
                if var blendShapeInfo =
                    blendShapeInfo(for: meshIdentifier),
                    !blendShapeInfo.weightNames.isEmpty
                {
                    var blendShapeComponent =
                        BlendShapeWeightsComponent(
                            weightsMapping: BlendShapeWeightsMapping(meshResource: meshComponent
                                .mesh)
                        )
                    var weightSet = blendShapeComponent.weightSet
                    if !weightSet.isEmpty {
                        // Seed the component with the glTF default weights so the
                        // entity matches the authoring pose before animation
                        // begins and cache the ordering RealityKit assigned to
                        // each weight set.
                        let defaultWeights =
                            defaultBlendShapeWeights(for: gltfNode)
                        var weightsByName = [String: Float]()
                        for (index, name) in blendShapeInfo
                            .weightNames
                            .enumerated()
                        {
                            if index < defaultWeights.count {
                                weightsByName[name] =
                                    defaultWeights[index]
                            } else {
                                weightsByName[name] = 0.0
                            }
                        }

                        var setInfos =
                            [BlendShapeWeightsData.ID: [String]]()
                        for data in weightSet {
                            let names = data.weightNames
                            let values = names
                                .map { weightsByName[$0] ?? 0.0 }
                            var updated = data
                            updated
                                .weights = BlendShapeWeights(values)
                            weightSet.set(updated)
                            setInfos[updated.id] = names
                        }

                        if var defaultEntry = weightSet.default {
                            let defaultValues = defaultEntry
                                .weightNames
                                .map { weightsByName[$0] ?? 0.0 }
                            defaultEntry
                                .weights =
                                BlendShapeWeights(defaultValues)
                            weightSet.default = defaultEntry
                        }

                        blendShapeComponent.weightSet = weightSet
                        nodeEntity.components
                            .set(blendShapeComponent)

                        blendShapeInfo.setInfos = setInfos
                        setBlendShapeInfo(
                            blendShapeInfo,
                            for: meshIdentifier
                        )
                    }
                }
            }

            @MainActor func convert(
                node gltfNode: GLTFNode,
                context: GLTFRealityKitResourceContext
            ) throws -> RealityKit.Entity {
                let nodeEntity = ModelEntity()
                var skinIdentifier: ObjectIdentifier?

                // TODO: This only ensures uniqueness for unnamed nodes; the asset could still contain duplicate names.
                nodeEntity.name = gltfNode.name ?? nameGenerator
                    .nextUniqueName(prefix: "Node")

                nodeEntity.transform = Transform(matrix: gltfNode.matrix)

                var skeleton: Any?
                #if compiler(>=6.0)
                    if #available(macOS 15.0, iOS 18.0, visionOS 2.0, *) {
                        if let skin = gltfNode.skin {
                            skinIdentifier = ObjectIdentifier(skin)
                            if let plan = mergedSkeletonPlan,
                               let remap = plan.remapBySkin[skinIdentifier!]
                            {
                                skeleton = plan.skeleton
                                if pathsForSkeletonIDs[plan.skeleton.id] ==
                                    nil
                                {
                                    pathsForSkeletonIDs[plan.skeleton.id] =
                                        gltfNode.bindPath
                                }
                                for (jointName, transform) in plan
                                    .skeletonRootTransforms
                                {
                                    skeletonTransformsByJointName[jointName] =
                                        transform
                                }
                                for jointName in plan.jointNames {
                                    if let existing = skeletonIDsByJointName[
                                        jointName
                                    ] {
                                        if !existing
                                            .contains(plan.skeleton.id)
                                        {
                                            skeletonIDsByJointName[jointName] =
                                                existing +
                                                [plan.skeleton.id]
                                        }
                                    } else {
                                        skeletonIDsByJointName[jointName] = [
                                            plan.skeleton.id,
                                        ]
                                    }
                                }
                                context.jointIndexRemapsBySkeletonID[
                                    plan.skeleton.id
                                ] = remap
                            } else if let meshSkeleton = convert(
                                skin: skin,
                                bindingNode: gltfNode,
                                context: context
                            ) {
                                skeleton = meshSkeleton
                                // Cache some associations between joints, entities, and skeletons so we can look them up later.
                                pathsForSkeletonIDs[meshSkeleton.id] = gltfNode
                                    .bindPath
                                for joint in meshSkeleton.joints {
                                    if joint.parentIndex == nil,
                                       let referenceNode = skin.skeleton
                                    {
                                        // TODO: Calculate the total transformation between the joint and the skeleton node?
                                        skeletonTransformsByJointName[
                                            joint
                                                .name
                                        ] =
                                            Transform(matrix: referenceNode
                                                .matrix)
                                    }
                                    if let existingJointCache =
                                        skeletonIDsByJointName[joint.name]
                                    {
                                        skeletonIDsByJointName[joint.name] =
                                            existingJointCache +
                                            [meshSkeleton.id]
                                    } else {
                                        skeletonIDsByJointName[joint.name] =
                                            [meshSkeleton.id]
                                    }
                                }
                            }
                        }
                    }
                #endif

                if let gltfMesh = gltfNode.mesh,
                   let (meshComponent, materialBindings) = try convert(
                       mesh: gltfMesh,
                       skeleton: skeleton,
                       skinIdentifier: skinIdentifier,
                       context: context
                   )
                {
                    nodeEntity.components.set(meshComponent)

                    if !materialBindings.isEmpty {
                        nodeEntity.components
                            .set(
                                GLTFMaterialBindingsComponent(
                                    bindings: materialBindings
                                )
                            )
                    }

                    #if compiler(>=6.0) || os(visionOS)
                        if #available(macOS 15.0, iOS 18.0, visionOS 2.0, *) {
                            convertBlendshape(
                                gltfNode: gltfNode,
                                gltfMesh: gltfMesh,
                                nodeEntity: nodeEntity,
                                meshComponent: meshComponent
                            )
                        }
                    #endif
                }

                if #available(visionOS 2.0, *) {
                    if let gltfLight = gltfNode.light {
                        switch gltfLight.type {
                        case .directional:
                            nodeEntity.components
                                .set(convert(directionalLight: gltfLight))
                        case .point:
                            nodeEntity.components
                                .set(convert(pointLight: gltfLight))
                        case .spot:
                            nodeEntity.components
                                .set(convert(spotLight: gltfLight))
                        default:
                            break
                        }
                    }
                }

                if let gltfCamera = gltfNode.camera,
                   let cameraComponent = convert(camera: gltfCamera)
                {
                    nodeEntity.components.set(cameraComponent)
                }

                for childNode in gltfNode.childNodes {
                    nodeEntity
                        .addChild(try convert(node: childNode,
                                              context: context))
                }

                return nodeEntity
            }

            #if compiler(>=6.0) || os(visionOS)
                @available(macOS 15.0, iOS 18.0, visionOS 2.0, *)
                private func defaultBlendShapeWeights(for node: GLTFNode)
                    -> [Float]
                {
                    if let nodeWeights = node.weights {
                        return nodeWeights.map { Float(truncating: $0) }
                    }
                    if let meshWeights = node.mesh?.weights {
                        return meshWeights.map { Float(truncating: $0) }
                    }
                    return []
                }

                @available(macOS 15.0, iOS 18.0, visionOS 2.0, *)
                private func buildSkeletonData(for gltfSkin: GLTFSkin)
                    -> SkeletonBuildResult?
                {
                    let skeletonName = gltfSkin.name ?? nameGenerator
                        .nextUniqueName(prefix: "Skin")
                    let joints = gltfSkin.joints

                    guard !joints.isEmpty else { return nil }

                    var providedInverseBindMatricesByNode =
                        [UUID: simd_float4x4]()
                    var meshBindTransform: simd_float4x4? = nil

                    if let accessor = gltfSkin.inverseBindMatrices,
                       let matrices = packedFloat4x4(for: accessor)
                    {
                        for (joint, matrix) in zip(joints, matrices) {
                            providedInverseBindMatricesByNode[joint.identifier] = matrix

                            if meshBindTransform == nil {
                                let globalJoint = absoluteTransform(for: joint)
                                meshBindTransform = globalJoint * matrix
                            }
                        }
                    }

                    var jointNames = [String]()
                    var parentIndices = [Int?]()
                    var inverseBindMatrices = [simd_float4x4]()
                    var restPoseTransforms = [Transform]()
                    var indexByNodeID = [UUID: Int]()

                    func ensureEntry(for node: GLTFNode) -> Int {
                        if let existing = indexByNodeID[node.identifier] {
                            return existing
                        }

                        let parentIndex: Int?
                        if let parent = node.parent {
                            parentIndex = ensureEntry(for: parent)
                        } else {
                            parentIndex = nil
                        }

                        let name: String
                        if let existingName = node.name, !existingName.isEmpty {
                            name = existingName
                        } else {
                            name = nameGenerator.nextUniqueName(prefix: "Joint")
                            node.name = name
                        }

                        node.isJoint = true

                        let index = jointNames.count
                        indexByNodeID[node.identifier] = index
                        jointNames.append(name)
                        parentIndices.append(parentIndex)
                        print(meshBindTransform)
                        let inverseBindMatrix: simd_float4x4
                        if let provided = providedInverseBindMatricesByNode[node.identifier] {
                            inverseBindMatrix = provided
                        } else if let bind = meshBindTransform {
                            // Bring this node into the same mesh-space as the provided IBMs
                            inverseBindMatrix = simd_inverse(absoluteTransform(for: node)) * bind
                        } else {
                            // Fallback for skins without any provided IBMs at all
                            inverseBindMatrix = simd_inverse(absoluteTransform(for: node))
                        }
                        inverseBindMatrices.append(inverseBindMatrix)
                        restPoseTransforms
                            .append(Transform(matrix: node.matrix))
                        return index
                    }

                    var jointIndexRemap = [UInt16](repeating: 0,
                                                   count: joints.count)
                    for (originalIndex, joint) in joints.enumerated() {
                        let mappedIndex = ensureEntry(for: joint)
                        guard let remapped = UInt16(exactly: mappedIndex) else {
                            return nil
                        }
                        jointIndexRemap[originalIndex] = remapped
                    }

                    let rootCount = parentIndices
                        .reduce(0) { $0 + ($1 == nil ? 1 : 0) }
                    if rootCount > 1 {
                        let rootName = nameGenerator
                            .nextUniqueName(prefix: "\(skeletonName)_Root")
                        jointNames.insert(rootName, at: 0)
                        parentIndices = [nil] + parentIndices
                            .map { parentIndex -> Int? in
                                if let parentIndex = parentIndex {
                                    return parentIndex + 1
                                } else {
                                    return 0
                                }
                            }
                        inverseBindMatrices.insert(
                            matrix_identity_float4x4,
                            at: 0
                        )
                        restPoseTransforms.insert(Transform(), at: 0)
                        jointIndexRemap = jointIndexRemap.map { originalIndex in
                            let incremented = Int(originalIndex) + 1
                            if let remapped = UInt16(exactly: incremented) {
                                return remapped
                            } else {
                                return originalIndex
                            }
                        }
                    }

                    guard parentIndices.count == jointNames.count,
                          inverseBindMatrices.count == jointNames.count
                    else {
                        return nil
                    }

                    return SkeletonBuildResult(
                        skeletonName: skeletonName,
                        jointNames: jointNames,
                        parentIndices: parentIndices,
                        inverseBindPoseMatrices: inverseBindMatrices,
                        restPoseTransforms: restPoseTransforms,
                        jointIndexRemap: jointIndexRemap
                    )
                }

                @available(macOS 15.0, iOS 18.0, visionOS 2.0, *)
                private func prepareMergedSkeletonPlan(asset: GLTFAsset?)
                    -> MergedSkeletonPlan?
                {
                    guard let skins = asset?.skins,
                          skins.count > 1 else { return nil }

                    var mergedJointNames: [String] = []
                    var mergedParentIndices: [Int?] = []
                    var mergedInverseBindMatrices: [simd_float4x4] = []
                    var mergedRestPoseTransforms: [Transform] = []
                    var remapBySkin: [ObjectIdentifier: [UInt16]] = [:]
                    var rootTransforms: [String: Transform] = [:]

                    for skin in skins {
                        guard let data = buildSkeletonData(for: skin) else {
                            continue
                        }
                        let offset = mergedJointNames.count

                        let adjustedParents = data.parentIndices.map { parent
                            -> Int? in
                            if let parent {
                                return parent + offset
                            }
                            return nil
                        }
                        mergedJointNames.append(contentsOf: data.jointNames)
                        mergedParentIndices
                            .append(contentsOf: adjustedParents)
                        mergedInverseBindMatrices.append(contentsOf: data
                            .inverseBindPoseMatrices)
                        mergedRestPoseTransforms
                            .append(contentsOf: data.restPoseTransforms)

                        let remapped = data.jointIndexRemap.map { index in
                            UInt16(Int(index) + offset)
                        }
                        remapBySkin[ObjectIdentifier(skin)] = remapped

                        if let referenceNode = skin.skeleton {
                            let transform = Transform(matrix: referenceNode
                                .matrix)
                            for (jointName, parent) in zip(data.jointNames,
                                                           data.parentIndices)
                                where parent == nil
                            {
                                rootTransforms[jointName] = transform
                            }
                        }
                    }

                    guard !remapBySkin.isEmpty else { return nil }

                    if mergedJointNames.count > Int(UInt16.max) {
                        #if DEBUG
                            print(
                                "[GLTFKit2] Merged skeleton exceeds supported joint count (\(mergedJointNames.count) > 65535)"
                            )
                        #endif
                        return nil
                    }

                    let mergedID = skins.first?.name ??
                        nameGenerator.nextUniqueName(prefix: "Skeleton")
                    guard let skeleton = MeshResource.Skeleton(
                        id: mergedID,
                        jointNames: mergedJointNames,
                        inverseBindPoseMatrices: mergedInverseBindMatrices,
                        parentIndices: mergedParentIndices
                    ) else { return nil }

                    jointNamesBySkeletonID[mergedID] = mergedJointNames
                    restPoseTransformsBySkeletonID[mergedID] =
                        mergedRestPoseTransforms
                    for jointName in mergedJointNames {
                        if var existing = skeletonIDsByJointName[jointName] {
                            if !existing.contains(mergedID) {
                                existing.append(mergedID)
                            }
                            skeletonIDsByJointName[jointName] = existing
                        } else {
                            skeletonIDsByJointName[jointName] = [mergedID]
                        }
                    }

                    return MergedSkeletonPlan(
                        skeleton: skeleton,
                        remapBySkin: remapBySkin,
                        restPoseTransforms: mergedRestPoseTransforms,
                        jointNames: mergedJointNames,
                        skeletonRootTransforms: rootTransforms
                    )
                }
            #endif

            #if compiler(>=6.0) || os(visionOS)
                @available(macOS 15.0, iOS 18.0, visionOS 2.0, *)
                func convert(
                    skin gltfSkin: GLTFSkin,
                    bindingNode _: GLTFNode,
                    context: GLTFRealityKitResourceContext
                ) -> MeshResource.Skeleton? {
                    guard let data = buildSkeletonData(for: gltfSkin) else {
                        return nil
                    }

                    print(data.jointNames)
                    print(data.inverseBindPoseMatrices)
                    guard let skeleton = MeshResource.Skeleton(
                        id: data.skeletonName,
                        jointNames: data.jointNames,
                        inverseBindPoseMatrices: data.inverseBindPoseMatrices,
                        parentIndices: data.parentIndices
                    ) else {
                        return nil
                    }

                    #if compiler(>=6.0) || os(visionOS)
                        context
                            .jointIndexRemapsBySkeletonID[data.skeletonName] =
                            data.jointIndexRemap
                        jointNamesBySkeletonID[data.skeletonName] =
                            data.jointNames
                        restPoseTransformsBySkeletonID[data.skeletonName] =
                            data.restPoseTransforms
                    #endif

                    return skeleton
                }
            #endif

            @MainActor func convert(
                mesh gltfMesh: GLTFMesh,
                skeleton: Any? /* MeshResource.Skeleton? */ = nil,
                skinIdentifier: ObjectIdentifier? = nil,
                context: GLTFRealityKitResourceContext
            ) throws
                -> (RealityKit.ModelComponent,
                    [String: GLTFMaterialBindingsComponent.Binding])?
            {
                var skeletonID: String?
                #if compiler(>=6.0) || os(visionOS)
                    if #available(macOS 15.0, iOS 18.0, *) {
                        if let skeleton = skeleton as? MeshResource.Skeleton {
                            skeletonID = skeleton.id
                        }
                    }
                #endif

                let jointIndexRemapForSkin: [UInt16]?
                #if compiler(>=6.0) || os(visionOS)
                    if #available(macOS 15.0, iOS 18.0, *) {
                        if let skinIdentifier,
                           let remap = mergedSkeletonPlan?
                           .remapBySkin[skinIdentifier]
                        {
                            jointIndexRemapForSkin = remap
                        } else if let skeletonID,
                                  let remap = context
                                  .jointIndexRemapsBySkeletonID[skeletonID]
                        {
                            jointIndexRemapForSkin = remap
                        } else {
                            jointIndexRemapForSkin = nil
                        }
                    } else {
                        jointIndexRemapForSkin = nil
                    }
                #else
                    jointIndexRemapForSkin = nil
                #endif

                var blendShapeNames: [String] = []
                #if compiler(>=6.0) || os(visionOS)
                    if #available(macOS 15.0, iOS 18.0, *),
                       let maxTargetCount = gltfMesh.primitives
                       .map({ $0.targets.count })
                       .max(),
                       maxTargetCount > 0
                    {
                        // RealityKit expects deterministic labels for every blend shape
                        // across a mesh, so derive a unique name for each target up-front.
                        let providedNames = gltfMesh.targetNames ?? []
                        var usedNames = Set<String>()
                        blendShapeNames = (0 ..< maxTargetCount)
                            .map { index -> String in
                                let baseName: String
                                if index < providedNames.count {
                                    let trimmed = providedNames[index]
                                        .trimmingCharacters(
                                            in: .whitespacesAndNewlines
                                        )
                                    baseName = trimmed
                                        .isEmpty ? "BlendShape\(index)" :
                                        trimmed
                                } else {
                                    baseName = "BlendShape\(index)"
                                }
                                var candidate = baseName
                                var suffix = 1
                                while usedNames.contains(candidate) {
                                    candidate = "\(baseName)_\(suffix)"
                                    suffix += 1
                                }
                                usedNames.insert(candidate)
                                return candidate
                            }
                    }
                #endif

                typealias PrimitiveConversion = (
                    part: MeshResource.Part,
                    material: any RealityKit.Material,
                    hasBlendShapes: Bool,
                    primitive: GLTFPrimitive
                )
                var primitiveMaterialIndex: Int = 0
                let primitiveConversions = try gltfMesh.primitives
                    .compactMap { primitive -> PrimitiveConversion? in
                        guard let (part, hasBlendShapes) = self.convert(
                            primitive: primitive,
                            materialIndex: primitiveMaterialIndex,
                            skeletonID: skeletonID,
                            blendShapeNames: blendShapeNames,
                            jointIndexRemap: jointIndexRemapForSkin,
                            context: context
                        ) else {
                            return nil
                        }

                        let material = try self.convert(
                            material: primitive.material,
                            context: context
                        )
                        primitiveMaterialIndex += 1
                        return (part, material, hasBlendShapes, primitive)
                    }

                if primitiveConversions.isEmpty {
                    // If we weren't able to successfully build any parts for our primitives, don't bother generating a mesh.
                    return nil
                }

                let parts = primitiveConversions.map { $0.part }
                let materials = primitiveConversions.map { $0.material }
                #if compiler(>=6.0) || os(visionOS)
                    let meshIdentifier = ObjectIdentifier(gltfMesh)
                    if #available(macOS 15.0, iOS 18.0, *),
                       !blendShapeNames.isEmpty
                    {
                        if primitiveConversions
                            .contains(where: { $0.hasBlendShapes })
                        {
                            var info = blendShapeInfo(for: meshIdentifier) ??
                                BlendShapeInfo(weightNames: blendShapeNames)
                            info.weightNames = blendShapeNames
                            setBlendShapeInfo(info, for: meshIdentifier)
                        } else {
                            setBlendShapeInfo(nil, for: meshIdentifier)
                        }
                    } else {
                        blendShapeInfoStorage
                            .removeValue(forKey: meshIdentifier)
                    }
                #endif

                // TODO: This only ensures uniqueness for unnamed meshes; the asset could still contain duplicate names.
                let modelName = gltfMesh.name ?? nameGenerator
                    .nextUniqueName(prefix: "Mesh")
                let model = MeshResource.Model(id: modelName, parts: parts)

                var meshContents = MeshResource.Contents()
                meshContents.models = MeshModelCollection([model])
                #if compiler(>=6.0) || os(visionOS)
                    if #available(macOS 15.0, iOS 18.0, *) {
                        if let skeleton = skeleton as? MeshResource.Skeleton {
                            meshContents
                                .skeletons = MeshSkeletonCollection([skeleton])
                        }
                    }
                #endif

                let meshResource = try MeshResource.generate(from: meshContents)
                let modelComponent = ModelComponent(
                    mesh: meshResource,
                    materials: materials
                )

                var materialBindings: [
                    String: GLTFMaterialBindingsComponent
                        .Binding
                ] = [:]
                for conversion in primitiveConversions {
                    let binding = GLTFMaterialBindingsComponent.Binding(
                        partID: conversion.part.id,
                        primitive: conversion.primitive
                    )
                    materialBindings[conversion.part.id] = binding
                }

                return (modelComponent, materialBindings)
            }

            func convert(
                primitive gltfPrimitive: GLTFPrimitive,
                materialIndex: Int = 0,
                skeletonID: String? = nil,
                blendShapeNames: [String] = [],
                jointIndexRemap: [UInt16]? = nil,
                context: GLTFRealityKitResourceContext
            ) -> (MeshResource.Part, Bool)? {
                if gltfPrimitive.primitiveType != .triangles {
                    return nil
                }

                let partName = nameGenerator.nextUniqueName(prefix: "Primitive")
                var part = MeshResource.Part(
                    id: partName,
                    materialIndex: materialIndex
                )
                var vertexCount = 0

                if let positionAttribute = gltfPrimitive
                    .attribute(forName: "POSITION"),
                    let positionArray = packedFloat3Array(for: positionAttribute
                        .accessor)
                {
                    part[MeshBuffers.positions] = MeshBuffers
                        .Positions(positionArray)
                    vertexCount = positionArray.count
                } else if let positionAttribute = gltfPrimitive
                    .attribute(forName: "POSITION")
                {
                    vertexCount = positionAttribute.accessor.count
                }

                if let normalAttribute = gltfPrimitive
                    .attribute(forName: "NORMAL"),
                    let normalArray = packedFloat3Array(for: normalAttribute
                        .accessor)
                {
                    part[MeshBuffers.normals] = MeshBuffers.Normals(normalArray)
                }

                if let tangentAttribute = gltfPrimitive
                    .attribute(forName: "TANGENT"),
                    let tangentArray = packedFloat3Array(for: tangentAttribute
                        .accessor)
                {
                    part[MeshBuffers.tangents] = MeshBuffers
                        .Tangents(tangentArray)
                }

                if let texCoords0Attribute = gltfPrimitive
                    .attribute(forName: "TEXCOORD_0"),
                    let texCoordsArray = packedFloat2Array(
                        for: texCoords0Attribute.accessor,
                        flipVertically: true
                    )
                {
                    part[MeshBuffers.textureCoordinates] = MeshBuffers
                        .TextureCoordinates(texCoordsArray)
                }

                var emittedBlendShapeOffsets = false

                #if compiler(>=6.0) || os(visionOS)
                    if #available(macOS 15.0, iOS 18.0, *),
                       !blendShapeNames.isEmpty,
                       !gltfPrimitive.targets.isEmpty,
                       vertexCount > 0
                    {
                        for (targetIndex, targetAttributes) in gltfPrimitive
                            .targets
                            .enumerated()
                        {
                            guard targetIndex < blendShapeNames.count
                            else { break }

                            guard let positionAttribute = targetAttributes
                                .first(where: { $0.name == "POSITION" })
                            else {
                                continue
                            }

                            guard let offsets =
                                packedFloat3Array(for: positionAttribute
                                    .accessor)
                            else {
                                continue
                            }

                            guard offsets.count == vertexCount else {
                                continue
                            }

                            // RealityKit expects absolute offsets, so decode the accessor
                            // (handling sparse encodings) and stash them under the target
                            // name we assigned above.
                            part[
                                MeshBuffers
                                    .blendShapeOffsets(
                                        named: blendShapeNames[targetIndex]
                                    )
                            ] =
                                MeshBuffers.BlendShapeOffsets(offsets)
                            emittedBlendShapeOffsets = true
                        }
                    }
                #endif

                #if compiler(>=6.0) || os(visionOS)
                    if #available(macOS 15.0, iOS 18.0, *) {
                        if let joints0Attribute = gltfPrimitive
                            .attribute(forName: "JOINTS_0"),
                            let weights0Attribute = gltfPrimitive
                            .attribute(forName: "WEIGHTS_0"),
                            let jointsArray0 =
                            packedUShort4Array(for: joints0Attribute
                                .accessor),
                            let weightsArray0 =
                            packedFloat4Array(for: weights0Attribute
                                .accessor)
                        {
                            let jointIndexRemap = jointIndexRemap ?? skeletonID
                                .flatMap {
                                    context.jointIndexRemapsBySkeletonID[$0]
                                }

                            func remappedIndex(for original: UInt16) -> UInt16 {
                                guard let remap = jointIndexRemap
                                else { return original }
                                let index = Int(original)
                                return index < remap
                                    .count ? remap[index] : original
                            }

                            let vertexCount = jointsArray0.count
                            var influences = [MeshJointInfluence]()
                            influences.reserveCapacity(vertexCount * 8)

                            func appendInfluences(
                                jointVectors: [SIMD4<UInt16>],
                                weightVectors: [SIMD4<Float>]
                            ) {
                                for (jointVector,
                                     weightVector) in zip(jointVectors,
                                                          weightVectors)
                                {
                                    influences.append(MeshJointInfluence(
                                        jointIndex: Int(
                                            remappedIndex(for: jointVector[0])
                                        ),
                                        weight: weightVector[0]
                                    ))
                                    influences.append(MeshJointInfluence(
                                        jointIndex: Int(
                                            remappedIndex(for: jointVector[1])
                                        ),
                                        weight: weightVector[1]
                                    ))
                                    influences.append(MeshJointInfluence(
                                        jointIndex: Int(
                                            remappedIndex(for: jointVector[2])
                                        ),
                                        weight: weightVector[2]
                                    ))
                                    influences.append(MeshJointInfluence(
                                        jointIndex: Int(
                                            remappedIndex(for: jointVector[3])
                                        ),
                                        weight: weightVector[3]
                                    ))
                                }
                            }

                            appendInfluences(
                                jointVectors: jointsArray0,
                                weightVectors: weightsArray0
                            )

                            var influencesPerVertex = 4
                            if let joints1Attribute = gltfPrimitive
                                .attribute(forName: "JOINTS_1"),
                                let weights1Attribute = gltfPrimitive
                                .attribute(forName: "WEIGHTS_1"),
                                let jointsArray1 =
                                packedUShort4Array(for: joints1Attribute
                                    .accessor),
                                let weightsArray1 =
                                packedFloat4Array(for: weights1Attribute
                                    .accessor)
                            {
                                appendInfluences(
                                    jointVectors: jointsArray1,
                                    weightVectors: weightsArray1
                                )
                                influencesPerVertex = 8
                            }

                            part.jointInfluences = MeshResource.JointInfluences(
                                influences: MeshBuffers
                                    .JointInfluences(influences),
                                influencesPerVertex: influencesPerVertex
                            )
                            part.skeletonID = skeletonID
                        }
                    }
                #endif

                // TODO: Support explicit bitangents and other user attributes?

                if let indexAccessor = gltfPrimitive.indices,
                   let indices = packedUInt32Array(for: indexAccessor)
                {
                    part.triangleIndices = MeshBuffers.TriangleIndices(indices)
                } else {
                    let vertexCount = gltfPrimitive
                        .attribute(forName: "POSITION")?
                        .accessor.count ?? 0
                    let indices = [UInt32](UInt32(0) ..< UInt32(vertexCount))
                    part.triangleIndices = MeshBuffers.TriangleIndices(indices)
                }

                return (part, emittedBlendShapeOffsets)
            }

            @MainActor func convert(
                material gltfMaterial: GLTFMaterial?,
                context: GLTFRealityKitResourceContext
            ) throws -> any RealityKit.Material {
                guard let gltfMaterial = gltfMaterial
                else { return context.defaultMaterial }

                if gltfMaterial.isUnlit {
                    var material = UnlitMaterial()
                    if let metallicRoughness = gltfMaterial.metallicRoughness {
                        material.color
                            .tint = platformColor(for: metallicRoughness
                                .baseColorFactor)
                        if let baseColorTexture = metallicRoughness
                            .baseColorTexture
                        {
                            material.color.texture = context.texture(
                                for: baseColorTexture,
                                channels: .all,
                                semantic: .color
                            )
                        }
                    }
                    if gltfMaterial.alphaMode == .mask {
                        material.opacityThreshold = gltfMaterial.alphaCutoff
                    } else if gltfMaterial.alphaMode == .blend {
                        // TODO: Convert base color alpha channel into opacity map?
                        material.blending = .transparent(opacity: 1.0)
                    }
                    return material
                } else {
                    var material = PhysicallyBasedMaterial()
                    if let metallicRoughness = gltfMaterial.metallicRoughness {
                        material.baseColor
                            .tint = platformColor(for: metallicRoughness
                                .baseColorFactor)
                        if let baseColorTexture = metallicRoughness
                            .baseColorTexture
                        {
                            material.baseColor.texture = context.texture(
                                for: baseColorTexture,
                                channels: .all,
                                semantic: .color
                            )
                        }
                        material.roughness.scale = metallicRoughness
                            .roughnessFactor
                        material.metallic.scale = metallicRoughness
                            .metallicFactor
                        if let metallicRoughnessTexture = metallicRoughness
                            .metallicRoughnessTexture
                        {
                            material.roughness.texture = context.texture(
                                for: metallicRoughnessTexture,
                                channels: .green,
                                semantic: .scalar
                            )
                            material.metallic.texture = context.texture(
                                for: metallicRoughnessTexture,
                                channels: .blue,
                                semantic: .scalar
                            )
                        }
                    }
                    if let normal = gltfMaterial.normalTexture {
                        material.normal.texture = context.texture(
                            for: normal,
                            channels: .all,
                            semantic: .normal
                        )
                    }
                    if let emissive = gltfMaterial.emissive {
                        material.emissiveIntensity = emissive.emissiveStrength
                        if let emissiveTexture = emissive.emissiveTexture {
                            material.emissiveColor.texture = context.texture(
                                for: emissiveTexture,
                                channels: .all,
                                semantic: .color
                            )
                        }
                    }
                    if let occlusion = gltfMaterial.occlusionTexture {
                        material.ambientOcclusion.texture = context.texture(
                            for: occlusion,
                            channels: .red,
                            semantic: .scalar
                        )
                    }
                    if let clearcoat = gltfMaterial.clearcoat {
                        material.clearcoat.scale = clearcoat.clearcoatFactor
                        if let clearcoatTexture = clearcoat.clearcoatTexture {
                            material.clearcoat.texture = context.texture(
                                for: clearcoatTexture,
                                channels: .red,
                                semantic: .raw
                            )
                        }
                        material.clearcoatRoughness.scale = clearcoat
                            .clearcoatRoughnessFactor
                        if let clearcoatRoughnessTexture = clearcoat
                            .clearcoatRoughnessTexture
                        {
                            material.clearcoatRoughness.texture = context
                                .texture(
                                    for: clearcoatRoughnessTexture,
                                    channels: .green,
                                    semantic: .raw
                                )
                        }
                    }
                    if gltfMaterial.alphaMode == .mask {
                        material.opacityThreshold = gltfMaterial.alphaCutoff
                    } else if gltfMaterial.alphaMode == .blend {
                        // TODO: Convert base color alpha channel into opacity map?
                        material.blending = .transparent(opacity: 1.0)
                    }
                    material.faceCulling = gltfMaterial
                        .isDoubleSided ? .none : .back

                    // TODO: sheen
                    return material
                }
            }

            @available(macOS 12.0, iOS 15.0, visionOS 2.0, *)
            func convert(spotLight gltfLight: GLTFLight) -> SpotLightComponent {
                let light = SpotLightComponent(
                    color: platformColor(for: simd_make_float4(gltfLight.color,
                                                               1.0)),
                    intensity: gltfLight.intensity,
                    innerAngleInDegrees: GLTFDegFromRad(gltfLight
                        .innerConeAngle),
                    outerAngleInDegrees: GLTFDegFromRad(gltfLight
                        .outerConeAngle),
                    attenuationRadius: gltfLight.range
                )
                return light
            }

            @available(macOS 12.0, iOS 15.0, visionOS 2.0, *)
            func convert(pointLight gltfLight: GLTFLight)
                -> PointLightComponent
            {
                let light = PointLightComponent(
                    color: platformColor(for: simd_make_float4(gltfLight.color,
                                                               1.0)),
                    intensity: gltfLight.intensity,
                    attenuationRadius: gltfLight.range
                )
                return light
            }

            @available(macOS 12.0, iOS 15.0, visionOS 2.0, *)
            func convert(directionalLight gltfLight: GLTFLight)
                -> DirectionalLightComponent
            {
                #if os(visionOS)
                    let light = DirectionalLightComponent(
                        color: platformColor(for: simd_make_float4(gltfLight
                                .color, 1.0)),
                        intensity: gltfLight.intensity
                    )
                #else
                    let light = DirectionalLightComponent(
                        color: platformColor(for: simd_make_float4(gltfLight
                                .color, 1.0)),
                        intensity: gltfLight.intensity,
                        isRealWorldProxy: false
                    )
                #endif
                return light
            }

            func convert(camera: GLTFCamera) -> PerspectiveCameraComponent? {
                if let perspectiveParams = camera.perspective {
                    let camera = PerspectiveCameraComponent(near: camera.zNear,
                                                            far: camera.zFar,
                                                            fieldOfViewInDegrees: GLTFDegFromRad(perspectiveParams
                                                                .yFOV))
                    return camera
                }
                return nil
            }

            func convert(animation: GLTFAnimation) throws -> AnimationResource {
                let groupedChannels = animation.channels
                    .reduce(into: [UUID: [GLTFAnimationChannel]]()) { partialResult, channel in
                        guard let targetIdentifier = channel.target.node?
                            .identifier
                        else { return }
                        if let _ = partialResult[targetIdentifier] {
                            partialResult[targetIdentifier]! += [channel]
                        } else {
                            partialResult[targetIdentifier] = [channel]
                        }
                    }
                let name = animation.name ?? nameGenerator
                    .nextUniqueName(prefix: "Animation")

                struct AnimatedJointData {
                    var jointNames = [String]()
                    var jointTransformSamplers = [GLTFTransformSampler]()
                    var minTime: Float = 0
                    var maxTime: Float = 0
                    var sampleInterval: Float = 1 / 30.0
                }
                var jointAnimation = AnimatedJointData()
                var animations = [AnimationDefinition]()
                for (_, channels) in groupedChannels {
                    guard let targetNode = channels.first?.target.node else {
                        continue // Can't create an animation without at least one channel and a target
                    }

                    #if compiler(>=6.0) || os(visionOS)
                        if #available(macOS 15.0, iOS 18.0, visionOS 2.0, *),
                           let mesh = targetNode.mesh
                        {
                            animations
                                .append(
                                    contentsOf: convertWeightAnimations(
                                        for: targetNode,
                                        mesh: mesh,
                                        channels: channels
                                    )
                                )
                        }
                    #endif

                    let translationChannel = channels
                        .first {
                            $0.target.path == GLTFAnimationPath.translation
                                .rawValue
                        }
                    let rotationChannel = channels
                        .first {
                            $0.target.path == GLTFAnimationPath.rotation
                                .rawValue
                        }
                    let scaleChannel = channels
                        .first {
                            $0.target.path == GLTFAnimationPath.scale.rawValue
                        }
                    let hasTransformChannel = translationChannel != nil ||
                        rotationChannel != nil || scaleChannel != nil
                    if !hasTransformChannel {
                        continue
                    }
                    let transformSampler = GLTFTransformSampler(
                        target: targetNode,
                        translationChannel: translationChannel,
                        rotationChannel: rotationChannel,
                        scaleChannel: scaleChannel,
                        maximumSampleInterval: 1 /
                            30.0
                    ) // TODO: Make sample interval an option

                    let transformFrames = stride(
                        from: transformSampler.startTime,
                        through: transformSampler.endTime,
                        by: transformSampler.recommendedSampleInterval
                    ).map { time in
                        transformSampler.transform(at: time)
                    }

                    if !transformFrames.isEmpty {
                        // Even when a mesh is skinned, the authoring rig often keeps
                        // attachments (eyes, teeth, accessories) as child nodes of the
                        // head. Baking node animations ensures those attachments follow
                        // the driven skeleton.
                        let transformAnimation = SampledAnimation(
                            frames: transformFrames,
                            tweenMode: transformSampler
                                .hasStepChannel ? .hold : .linear,
                            frameInterval: transformSampler
                                .recommendedSampleInterval,
                            bindTarget: targetNode.bindPath.transform,
                            repeatMode: .repeat,
                            delay: TimeInterval(transformSampler.startTime)
                        )
                        animations.append(transformAnimation)
                    }

                    if targetNode.isJoint {
                        jointAnimation.jointNames.append(targetNode.name!)
                        jointAnimation.jointTransformSamplers
                            .append(transformSampler)
                        jointAnimation.minTime = min(
                            jointAnimation.minTime,
                            transformSampler.startTime
                        )
                        jointAnimation.maxTime = max(
                            jointAnimation.maxTime,
                            transformSampler.endTime
                        )
                        jointAnimation.sampleInterval = min(
                            jointAnimation.sampleInterval,
                            transformSampler.recommendedSampleInterval
                        )
                    }
                }
                if !jointAnimation.jointNames.isEmpty {
                    var sampleTimes = Array(stride(from: jointAnimation.minTime,
                                                   through: jointAnimation
                                                       .maxTime,
                                                   by: jointAnimation
                                                       .sampleInterval))
                    if sampleTimes.isEmpty {
                        sampleTimes = [jointAnimation.minTime]
                    }
                    let sampleCount = sampleTimes.count

                    var sampledTransformsByJointName = [String: [Transform]]()
                    for (jointName, transformSampler) in zip(
                        jointAnimation.jointNames,
                        jointAnimation.jointTransformSamplers
                    ) {
                        print(jointName)
                        var samples = [Transform]()
                        samples.reserveCapacity(sampleCount)
                        for t in sampleTimes {
                            let jointTransform = transformSampler
                                .transform(at: t)
//                            if let ancestorTransform =
//                                skeletonTransformsByJointName[
//                                    jointName
//                                ]
//                            {
//                                jointTransform =
//                                    Transform(matrix: ancestorTransform
//                                        .matrix * jointTransform
//                                        .matrix)
//                            }
                            samples.append(jointTransform)
                        }
                        sampledTransformsByJointName[jointName] = samples
                    }

                    let delay = TimeInterval(jointAnimation.minTime)

                    var animatedSkeletonIDs =
                        Set</* MeshResource.Skeleton.ID */ String>()
                    for jointName in jointAnimation.jointNames {
                        if let skeletonIDs = skeletonIDsByJointName[jointName] {
                            animatedSkeletonIDs.formUnion(skeletonIDs)
                        }
                    }

                    for skeletonID in animatedSkeletonIDs {
                        guard let bindPath = pathsForSkeletonIDs[skeletonID],
                              let orderedJointNames =
                              jointNamesBySkeletonID[skeletonID]
                        else {
                            continue
                        }

                        let restTransforms = restPoseTransformsBySkeletonID[
                            skeletonID
                        ] ??
                            []

                        print("RESTPOSETRANSFORM")
                        print(restPoseTransformsBySkeletonID)
                        
                        let jointFrames = (0 ..< sampleCount)
                            .map { sampleIndex -> JointTransforms in
                                let transforms = orderedJointNames.enumerated()
                                    .map { jointIndex, jointName -> Transform in
                                        // RealityKit consumes joint transforms in skeleton (local)
                                        // space; fall back to the rest pose when a joint lacks keyframes.
                                        if let samples =
                                            sampledTransformsByJointName[
                                                jointName
                                            ],
                                            sampleIndex < samples.count
                                        {
                                            return samples[sampleIndex]
                                        }
//                                        if restTransforms.indices
//                                            .contains(jointIndex)
//                                        {
//                                            return restTransforms[jointIndex]
//                                        }
                                        return Transform()
                                    }
                                return JointTransforms(transforms)
                            }

                        let skeletalAnimation = SampledAnimation(
                            jointNames: orderedJointNames,
                            frames: jointFrames,
                            tweenMode: .linear, // TODO: Support .hold?
                            frameInterval: jointAnimation.sampleInterval,
                            bindTarget: bindPath.jointTransforms,
                            repeatMode: .repeat,
                            delay: delay
                        )
                        animations.append(skeletalAnimation)
                    }
                }


                let groupAnimation = AnimationGroup(
                    group: animations,
                    name: name
                )
                GLTFRealityKitLoader.usdRawAnimationDefinitions[name] =
                    groupAnimation
                return try AnimationResource.generate(with: groupAnimation)
            }

            #if compiler(>=6.0) || os(visionOS)
                @available(macOS 15.0, iOS 18.0, visionOS 2.0, *)
                private func convert(
                    weightChannel: GLTFAnimationChannel,
                    info: BlendShapeInfo,
                    defaultWeights: [Float],
                    entityPath: BindTarget.EntityPath
                ) -> [AnimationDefinition] {
                    let sampler = weightChannel.sampler

                    guard !info.weightNames.isEmpty,
                          let sampleTimes = packedFloatArray(for: sampler
                              .input),
                          let weightValues = packedFloatArray(for: sampler
                              .output)
                    else {
                        return []
                    }

                    let sampleCount = sampleTimes.count
                    guard sampleCount > 0 else { return [] }
                    guard weightValues.count % sampleCount == 0
                    else { return [] }

                    let weightsPerSample = weightValues.count / sampleCount
                    guard weightsPerSample > 0 else { return [] }

                    // Build a dense frame table for the overall weight order as well as
                    // each RealityKit weight set so we can drive either binding depending
                    // on what the mesh exposes.
                    var frames = [BlendShapeWeights]()
                    frames.reserveCapacity(sampleCount)
                    var framesBySet =
                        [BlendShapeWeightsData.ID: [BlendShapeWeights]]()
                    for (id, _) in info.setInfos {
                        framesBySet[id] = []
                    }

                    for sampleIndex in 0 ..< sampleCount {
                        let baseIndex = sampleIndex * weightsPerSample
                        var valuesByName = [String: Float]()
                        valuesByName.reserveCapacity(info.weightNames.count)

                        for (nameIndex, name) in info.weightNames.enumerated() {
                            let value: Float
                            if nameIndex < weightsPerSample {
                                value = weightValues[baseIndex + nameIndex]
                            } else if nameIndex < defaultWeights.count {
                                value = defaultWeights[nameIndex]
                            } else {
                                value = 0.0
                            }
                            valuesByName[name] = value
                        }

                        let orderedValues = info.weightNames
                            .map { valuesByName[$0] ?? 0.0 }
                        frames.append(BlendShapeWeights(orderedValues))

                        for (id, names) in info.setInfos {
                            let values = names.map { valuesByName[$0] ?? 0.0 }
                            framesBySet[id, default: []]
                                .append(BlendShapeWeights(values))
                        }
                    }

                    var frameInterval: Float = 1 / 30.0
                    if sampleCount > 1 {
                        let totalDuration = sampleTimes[sampleTimes.count - 1] -
                            sampleTimes[0]
                        if totalDuration > 0 {
                            frameInterval = totalDuration /
                                Float(sampleCount - 1)
                        } else {
                            var minInterval = Float.greatestFiniteMagnitude
                            for index in 1 ..< sampleTimes.count {
                                let delta = sampleTimes[index] -
                                    sampleTimes[index - 1]
                                if delta > 0 {
                                    minInterval = min(minInterval, delta)
                                }
                            }
                            if minInterval.isFinite, minInterval > 0 {
                                frameInterval = minInterval
                            }
                        }
                    }

                    let tweenMode: TweenMode = sampler
                        .interpolationMode == .step ? .hold : .linear
                    let delay = TimeInterval(sampleTimes.first ?? 0.0)

                    if info.setInfos.isEmpty {
                        // No individual weight sets were registered, so drive the aggregate
                        // blend-shape weight binding with the reordered frames we built.
                        let animation = SampledAnimation(
                            weightNames: info.weightNames,
                            frames: frames,
                            tweenMode: tweenMode,
                            frameInterval: frameInterval,
                            bindTarget: entityPath
                                .blendShapeWeights(
                                ),
                            repeatMode: .repeat,
                            delay: delay
                        )
                        return [animation]
                    } else {
                        var animations = [AnimationDefinition]()
                        for (id, names) in info.setInfos {
                            guard let setFrames = framesBySet[id],
                                  !setFrames.isEmpty else { continue }
                            // RealityKit inserts a weight set for each mesh part, so address
                            // the matching binding using the cached identifier and replay the
                            // per-set frames.
                            let animation = SampledAnimation(weightNames: names,
                                                             frames: setFrames,
                                                             tweenMode: tweenMode,
                                                             frameInterval: frameInterval,
                                                             bindTarget: entityPath
                                                                 .blendShapeWeightsWithID(
                                                                     id
                                                                 ),
                                                             repeatMode: .repeat,
                                                             delay: delay)
                            animations.append(animation)
                        }
                        if animations.isEmpty {
                            let animation = SampledAnimation(
                                weightNames: info.weightNames,
                                frames: frames,
                                tweenMode: tweenMode,
                                frameInterval: frameInterval,
                                bindTarget: entityPath
                                    .blendShapeWeights(
                                    ),
                                repeatMode: .repeat,
                                delay: delay
                            )
                            return [animation]
                        }
                        return animations
                    }
                }

                @available(macOS 15.0, iOS 18.0, visionOS 2.0, *)
                private func convertWeightAnimations(
                    for node: GLTFNode,
                    mesh: GLTFMesh,
                    channels: [GLTFAnimationChannel]
                ) -> [AnimationDefinition] {
                    let weightChannels = channels
                        .filter {
                            $0.target.path == GLTFAnimationPath.weights
                                .rawValue
                        }
                    guard !weightChannels.isEmpty else { return [] }

                    let meshIdentifier = ObjectIdentifier(mesh)
                    guard let info = blendShapeInfo(for: meshIdentifier),
                          !info.weightNames.isEmpty
                    else {
                        return []
                    }

                    print(
                        "[GLTFRealityKit] convertWeightAnimations node=\(node.name ?? "<unnamed>") weights=\(info.weightNames.count) channels=\(weightChannels.count)"
                    )

                    let defaultWeights = defaultBlendShapeWeights(for: node)

                    var animations = [AnimationDefinition]()
                    for weightChannel in weightChannels {
                        print(
                            "[GLTFRealityKit]  channel sampler input=\(weightChannel.sampler.input.name ?? "<unnamed>") output=\(weightChannel.sampler.output.name ?? "<unnamed>") target=\(weightChannel.target.path)"
                        )
                        // Each channel updates either the aggregate blend weight array or a
                        // specific weight set (for meshes with multiple materials), so we
                        // emit the appropriate SampledAnimation objects for whichever case
                        // applies.
                        animations
                            .append(
                                contentsOf: convert(
                                    weightChannel: weightChannel,
                                    info: info,
                                    defaultWeights: defaultWeights,
                                    entityPath: node
                                        .bindPath
                                )
                            )
                    }
                    return animations
                }
            #endif

            func platformColor(for vector: simd_float4) -> PlatformColor {
                #if os(macOS)
                    let components = [
                        CGFloat(vector.x),
                        CGFloat(vector.y),
                        CGFloat(vector.z),
                        CGFloat(vector.w),
                    ]
                    let color = NSColor(
                        colorSpace: colorSpace,
                        components: components,
                        count: components.count
                    )
                    return color
                #else
                    let components = [
                        CGFloat(vector.x),
                        CGFloat(vector.y),
                        CGFloat(vector.z),
                        CGFloat(vector.w),
                    ]
                    // TODO: Use proper color space (linear sRGB)
                    let color = UIColor(
                        red: components[0],
                        green: components[1],
                        blue: components[2],
                        alpha: components[3]
                    )
                    return color
                #endif
            }
        }

    #endif // compiler >=5.6

#endif // !tvOS

@available(macOS 12.0, *)
@MainActor
extension GLTFRealityKitLoader {
    func convertModel(
        mesh gltfMesh: GLTFMesh,
        skeleton: Any? /* MeshResource.Skeleton? */ = nil,
        context: GLTFRealityKitResourceContext
    ) throws -> MeshResource.Model? {
        var skeletonID: String?
        #if compiler(>=6.0) || os(visionOS)
            if #available(macOS 15.0, iOS 18.0, *) {
                if let skeleton = skeleton as? MeshResource.Skeleton {
                    skeletonID = skeleton.id
                }
            }
        #endif

        var blendShapeNames: [String] = []
        #if compiler(>=6.0) || os(visionOS)
            if #available(macOS 15.0, iOS 18.0, *),
               let maxTargetCount = gltfMesh.primitives
               .map({ $0.targets.count })
               .max(),
               maxTargetCount > 0
            {
                // RealityKit expects deterministic labels for every blend shape
                // across a mesh, so derive a unique name for each target up-front.
                let providedNames = gltfMesh.targetNames ?? []
                var usedNames = Set<String>()
                blendShapeNames = (0 ..< maxTargetCount)
                    .map { index -> String in
                        let baseName: String
                        if index < providedNames.count {
                            let trimmed = providedNames[index]
                                .trimmingCharacters(
                                    in: .whitespacesAndNewlines
                                )
                            baseName = trimmed
                                .isEmpty ? "BlendShape\(index)" :
                                trimmed
                        } else {
                            baseName = "BlendShape\(index)"
                        }
                        var candidate = baseName
                        var suffix = 1
                        while usedNames.contains(candidate) {
                            candidate = "\(baseName)_\(suffix)"
                            suffix += 1
                        }
                        usedNames.insert(candidate)
                        return candidate
                    }
            }
        #endif

        typealias PrimitiveConversion = (
            part: MeshResource.Part,
            material: any RealityKit.Material,
            hasBlendShapes: Bool,
            primitive: GLTFPrimitive
        )
        var primitiveMaterialIndex: Int = 0
        let primitiveConversions = try gltfMesh.primitives
            .compactMap { primitive -> PrimitiveConversion? in
                guard let (part, hasBlendShapes) = self.convert(
                    primitive: primitive,
                    materialIndex: primitiveMaterialIndex,
                    skeletonID: skeletonID,
                    blendShapeNames: blendShapeNames,
                    context: context
                ) else {
                    return nil
                }

                let material = try self.convert(
                    material: primitive.material,
                    context: context
                )
                primitiveMaterialIndex += 1
                return (part, material, hasBlendShapes, primitive)
            }

        if primitiveConversions.isEmpty {
            // If we weren't able to successfully build any parts for our primitives, don't bother generating a mesh.
            return nil
        }

        let parts = primitiveConversions.map { $0.part }
        let materials = primitiveConversions.map { $0.material }
        #if compiler(>=6.0) || os(visionOS)
            let meshIdentifier = ObjectIdentifier(gltfMesh)
            if #available(macOS 15.0, iOS 18.0, *),
               !blendShapeNames.isEmpty
            {
                if primitiveConversions
                    .contains(where: { $0.hasBlendShapes })
                {
                    var info = blendShapeInfo(for: meshIdentifier) ??
                        BlendShapeInfo(weightNames: blendShapeNames)
                    info.weightNames = blendShapeNames
                    setBlendShapeInfo(info, for: meshIdentifier)
                } else {
                    setBlendShapeInfo(nil, for: meshIdentifier)
                }
            } else {
                blendShapeInfoStorage
                    .removeValue(forKey: meshIdentifier)
            }
        #endif

        // TODO: This only ensures uniqueness for unnamed meshes; the asset could still contain duplicate names.
        let modelName = gltfMesh.name ?? nameGenerator
            .nextUniqueName(prefix: "Mesh")
        return MeshResource.Model(id: modelName, parts: parts)
    }
}

// MARK: - GLTFRealityKitLoader Extension -

@available(macOS 15.0, iOS 18.0, visionOS 2.0, *)
@MainActor
public extension GLTFRealityKitLoader {
    static func convertRootAsset(asset: GLTFAsset) throws -> Entity {
        let instance = GLTFRealityKitLoader()
        let rootEntity = Entity()
        rootEntity.name = "GLTF_Scene_Root"

        let context = GLTFRealityKitResourceContext()

//        // Unused
//        var materials = [UUID: RealityKit.Material]()
//        for gltfMaterial in asset.materials {
//            if let mat = try? instance.convert(material: gltfMaterial,
//                                               context: context)
//            {
//                materials.updateValue(mat, forKey: gltfMaterial.identifier)
//            }
//        }

        // TODO: Cameras

        // TODO: lights

        // Ensure unique node names
        for gltfNode in asset.nodes {
            gltfNode.name = instance.nameGenerator
                .nextUniqueName(prefix: gltfNode.name ?? "Node")
        }

        // Create all nodes
        var nodesForIdentifier = [UUID: Entity]()
        for gltfNode in asset.nodes {
            let entity = Entity()
            entity.name = gltfNode.name ?? instance.nameGenerator
                .nextUniqueName(prefix: "Node")

            // Ignore skin local transform
            // if gltfNode.skin == nil {
            entity.transform = Transform(matrix: gltfNode.matrix)
            // }

            nodesForIdentifier.updateValue(entity, forKey: gltfNode.identifier)
        }

        // Create the tree of nodes
        for gltfNode in asset.nodes {
            if let node = nodesForIdentifier[gltfNode.identifier] {
                for gltfChildNode in gltfNode.childNodes {
                    if let childNode =
                        nodesForIdentifier[gltfChildNode.identifier]
                    {
                        node.addChild(childNode)
                    }
                }
            }
        }

        for gltfNode in asset.nodes {
            guard let node = nodesForIdentifier[gltfNode.identifier]
            else { continue }

            // TODO: cameras
            if let _ = gltfNode.camera {}

            // TODO: Lights
            if let _ = gltfNode.light {}

            var skeleton: MeshResource.Skeleton?
            if let skin = gltfNode.skin {
                if let meshSkeleton = instance.convert(
                    skin: skin,
                    bindingNode: gltfNode,
                    context: context
                ) {
                    skeleton = meshSkeleton

                    // Cache some associations between joints, entities, and skeletons so we can look them up later.
                    instance.pathsForSkeletonIDs[meshSkeleton.id] = gltfNode
                        .bindPath
                    for joint in meshSkeleton.joints {
//                        if joint.parentIndex == nil,
//                           let referenceNode = skin.skeleton
//                        {
//                            print("====")
//                            print(joint.name)
//                            print(referenceNode.name)
//
//                            let abs = instance.absoluteTransform(for: gltfNode)
//                            let t = Transform(matrix: abs)
//                            print(t)
//                            print(Transform(matrix: referenceNode.matrix))
//                            // TODO: Calculate the total transformation between the joint and the skeleton node?
//                            instance.skeletonTransformsByJointName[
//                                joint
//                                    .name
//                            ] =
//                                Transform(matrix: abs)
//                        }
                        if let existingJointCache =
                            instance.skeletonIDsByJointName[joint.name]
                        {
                            instance.skeletonIDsByJointName[joint.name] =
                                existingJointCache +
                                [meshSkeleton.id]
                        } else {
                            instance.skeletonIDsByJointName[joint.name] =
                                [meshSkeleton.id]
                        }
                    }
                }
            }

//            // DEBUG Nodes
//            let g = ModelComponent(
//                mesh: .generateSphere(radius: 0.01),
//                materials: []
//            )
//            node.components.set(g)

            if let gltfMesh = gltfNode.mesh {
                if let (modelComponent, materialBindings) = try instance
                    .convert(
                        mesh: gltfMesh,
                        skeleton: skeleton,
                        context: context
                    )
                {
                    node.components.set(modelComponent)

                    instance.convertBlendshape(
                        gltfNode: gltfNode,
                        gltfMesh: gltfMesh,
                        nodeEntity: node,
                        meshComponent: modelComponent
                    )

                    if !materialBindings.isEmpty {
                        node.components
                            .set(
                                GLTFMaterialBindingsComponent(
                                    bindings: materialBindings
                                )
                            )
                    }
                }
            }
        }

        // add root nodes to entity
        for node in nodesForIdentifier.values {
            if node.parent == nil {
                rootEntity.addChild(node)
            }
        }

        for animation in asset.animations {
            let rkAnimation = try? instance.convert(animation: animation)
            rkAnimation?.store(in: rootEntity)
        }

        return rootEntity
    }
}
