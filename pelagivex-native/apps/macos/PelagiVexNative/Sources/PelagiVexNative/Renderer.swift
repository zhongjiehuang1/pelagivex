#if os(macOS)
import MetalKit
import CoreVideo
import VisionCore

struct RenderMeasurement {
    let sequence: UInt64
    let received: Double
    let finished: Double
    let gpuMS: Double
}

/// Core ML does inference; Metal reconstructs instance masks and composites the exact source frame.
final class Renderer: NSObject, MTKViewDelegate {
    struct LiveStyle: Equatable { let trackID: Int? }
    let liveStyle = Snapshot<LiveStyle>()

    private struct DrawKey: Equatable {
        let view: ObjectIdentifier
        let size: CGSize
        let sequence: UInt64?
        let refinementFresh: Bool
        let mirrored: Bool
        let outlineWidth: Float
        let style: LiveStyle?
    }

    let measurements = Snapshot<RenderMeasurement>()
    let displayedObjects = Snapshot<(Packet, [Int: SIMD4<Float>])>()
    let contourCoverage = Snapshot<(refined: Int, total: Int, age: Double)>()
    let displayMeter = FrameMeter()
    private let pipeline: Pipeline
    private let device: MTLDevice
    private let commands: MTLCommandQueue
    private let renderState: MTLRenderPipelineState
    private let maskState: MTLComputePipelineState
    private let propagationState: MTLComputePipelineState
    private let renderBaseline = ProcessInfo.processInfo.environment["PELAGIVEX_RENDER_BASELINE"] == "1"
    var preferredPollRate: Int { renderBaseline ? 60 : 120 }
    private var cache: CVMetalTextureCache!
    private let inFlight = DispatchSemaphore(value: 2)
    private var sequence: UInt64 = 0
    private var lastDraw: DrawKey?
    private var ids: MTLTexture?
    private var idsUseSourceCoordinates = false
    private var refinementSequence: UInt64?
    private var uploadedRefinementSequence: UInt64?
    private var refinementTexture: MTLTexture?
    private var colors: MTLBuffer?
    private var colorSlots: [Int: Int] = [:]
    private var colorizedTrackID: Int?
    private let focusColor = SIMD4<Float>(0.31, 0.81, 1, 1)
    // The first colors are deliberately well separated; a slot is unique among visible tracks.
    private let palette: [SIMD4<Float>] = {
        let base: [SIMD4<Float>] = [
        SIMD4(1, 0.20, 0.20, 1), SIMD4(0.10, 0.85, 1, 1), SIMD4(1, 0.85, 0.05, 1),
        SIMD4(0.70, 0.25, 1, 1), SIMD4(0.10, 0.95, 0.30, 1), SIMD4(1, 0.35, 0.80, 1),
        SIMD4(1, 0.50, 0.05, 1), SIMD4(0.20, 0.40, 1, 1), SIMD4(0.65, 1, 0.05, 1),
        SIMD4(1, 0.55, 0.55, 1), SIMD4(0.15, 0.85, 0.65, 1), SIMD4(0.85, 0.65, 1, 1),
        SIMD4(0.90, 0.20, 0.45, 1), SIMD4(0.45, 0.75, 1, 1), SIMD4(0.95, 0.95, 0.55, 1),
        SIMD4(0.40, 0.95, 0.60, 1), SIMD4(0.95, 0.65, 0.25, 1), SIMD4(0.55, 0.45, 1, 1),
        SIMD4(1, 0.75, 0.85, 1), SIMD4(0.10, 0.60, 0.85, 1), SIMD4(0.70, 0.80, 0.15, 1),
        SIMD4(0.95, 0.30, 0.05, 1), SIMD4(0.35, 1, 0.95, 1), SIMD4(0.90, 0.45, 1, 1),
        SIMD4(0.65, 0.85, 0.45, 1)
        ]
        return base + (25..<256).map { index in
            let hue = Float(Double(index) * 0.618033988749895).truncatingRemainder(dividingBy: 1) * 6
            let sector = Int(hue), fraction = hue - Float(sector)
            let p: Float = 0.18, q: Float = 1 - fraction * 0.82, t: Float = 0.18 + fraction * 0.82
            switch sector {
            case 0: return SIMD4(1, t, p, 1)
            case 1: return SIMD4(q, 1, p, 1)
            case 2: return SIMD4(p, 1, t, 1)
            case 3: return SIMD4(p, q, 1, 1)
            case 4: return SIMD4(t, p, 1, 1)
            default: return SIMD4(1, p, q, 1)
            }
        }
    }()
    var mirrored = false
    var outlineWidth: Float = 1.5
    var onError: ((String) -> Void)?

    init(device: MTLDevice, pipeline: Pipeline) throws {
        self.device = device; self.pipeline = pipeline
        guard let commands = device.makeCommandQueue() else { throw PipelineError.invalid("Metal command queue unavailable.") }
        self.commands = commands
        let library = try device.makeLibrary(source: Self.shader, options: nil)
        guard let vertex = library.makeFunction(name: "renderQuad"), let fragment = library.makeFunction(name: "overlay"),
              let masks = library.makeFunction(name: "masks"),
              let propagate = library.makeFunction(name: renderBaseline ? "propagateContours" : "propagateEligibleContours") else {
            throw PipelineError.invalid("Metal shaders unavailable.")
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex; descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        renderState = try device.makeRenderPipelineState(descriptor: descriptor)
        maskState = try device.makeComputePipelineState(function: masks)
        propagationState = try device.makeComputePipelineState(function: propagate)
        super.init()
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess else {
            throw PipelineError.invalid("Could not create camera texture cache.")
        }
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    private func buffer<T>(_ values: [T]) -> MTLBuffer? {
        values.withUnsafeBytes { raw in
            guard let base = raw.baseAddress, raw.count > 0 else { return nil }
            return device.makeBuffer(bytes: base, length: raw.count, options: .storageModeShared)
        }
    }
    private func texture(_ mask: InstanceMask) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Uint,
            width: mask.width, height: mask.height, mipmapped: false)
        descriptor.usage = [.shaderRead]; descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        mask.pixels.withUnsafeBytes { pixels in
            texture.replace(region: MTLRegionMake2D(0, 0, mask.width, mask.height), mipmapLevel: 0,
                            withBytes: pixels.baseAddress!, bytesPerRow: mask.width)
        }
        return texture
    }
    private func instanceColors(_ trackIDs: [Int], retained: [Int]) -> [SIMD4<Float>] {
        let remembered = Set(trackIDs + retained)
        colorSlots = colorSlots.filter { remembered.contains($0.key) }
        var used = Set(colorSlots.values)
        return trackIDs.map { id in
            if let slot = colorSlots[id] { return palette[slot] }
            let slot = palette.indices.first { !used.contains($0) } ?? 0
            colorSlots[id] = slot
            used.insert(slot)
            return palette[slot]
        }
    }
    func draw(in view: MTKView) {
        let packet = pipeline.packets.get()
        let now = ProcessInfo.processInfo.systemUptime
        let lineWidth = max(0, min(4, outlineWidth))
        let style = liveStyle.get()
        let refinement = packet?.refinement.flatMap { evidence -> RefinedFrame? in
            if let focused = evidence.focusTrackID, focused != style?.trackID { return nil }
            return evidence
        }
        let maximumAge = style?.trackID == nil ? ContourPropagation.defaultMaximumAge : 0.42
        let freshRefinement = refinement.map {
            let age = now - $0.received
            return age >= 0 && age <= maximumAge
        } ?? false
        let drawKey = DrawKey(view: ObjectIdentifier(view), size: view.drawableSize,
                              sequence: packet?.frame.sequence, refinementFresh: freshRefinement,
                              mirrored: mirrored, outlineWidth: lineWidth, style: style)
        // Poll at the display cadence so a fresh packet can draw promptly, while skipping
        // duplicate GPU work. An expired fine contour still triggers a native-mask redraw.
        guard renderBaseline || drawKey != lastDraw else { return }
        guard inFlight.wait(timeout: .now()) == .success else { return }
        var committed = false
        defer { if !committed { inFlight.signal() } }
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let command = commands.makeCommandBuffer() else { return }
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.02, green: 0.025, blue: 0.035, alpha: 1)
        guard let packet else {
            ids = nil; colors = nil
            refinementTexture = nil; uploadedRefinementSequence = nil; refinementSequence = nil
            idsUseSourceCoordinates = false
            sequence = 0; colorSlots.removeAll(); colorizedTrackID = nil; displayedObjects.set(nil)
            contourCoverage.set(nil)
            let encoder = command.makeRenderCommandEncoder(descriptor: pass); encoder?.endEncoding()
            command.present(drawable); command.addCompletedHandler { [inFlight] _ in inFlight.signal() }
            command.commit(); lastDraw = drawKey; committed = true; return
        }
        let width = CVPixelBufferGetWidth(packet.frame.pixels), height = CVPixelBufferGetHeight(packet.frame.pixels)
        var cameraReference: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, packet.frame.pixels, nil, .bgra8Unorm,
                                                       width, height, 0, &cameraReference) == kCVReturnSuccess,
              let cameraReference, let cameraTexture = CVMetalTextureGetTexture(cameraReference) else { return }
        let warps: [ContourWarp]
        if !packet.textGuided, packet.sourceMask == nil, let refined = refinement, let contract = packet.contract {
            warps = ContourPropagation.warps(source: refined.detections, current: packet.detections,
                sourceWidth: refined.width, sourceHeight: refined.height, currentWidth: width, currentHeight: height,
                inputSize: contract.inputSize, sourceReceived: refined.received, currentReceived: packet.frame.received,
                now: now, maximumAge: maximumAge).filter {
                    // Shared instance maps can fully occlude a lower-priority object.
                    // An absent SAM instance must retain its current native contour.
                    refined.representedInstances.contains(UInt8($0.sourceIndex + 1)) &&
                        (refined.focusTrackID == nil || $0.sourceBox.iou($0.currentBox) >= 0.60)
                }
        } else { warps = [] }
        let activeRefinement = warps.isEmpty ? nil : refinement
        contourCoverage.set((refined: warps.count, total: packet.detections.count,
            age: refinement.map { max(0, now-$0.received) } ?? 0))
        if refinement == nil {
            refinementTexture = nil; uploadedRefinementSequence = nil
        }
        let focusID = drawKey.style?.trackID
        if ids == nil || sequence != packet.frame.sequence || refinementSequence != activeRefinement?.sequence ||
            colorizedTrackID != focusID {
            let contract = packet.contract
            let w = contract?.prototypeWidth ?? 1, h = contract?.prototypeHeight ?? 1
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Uint, width: w, height: h, mipmapped: false)
            descriptor.usage = [.shaderRead, .shaderWrite]; descriptor.storageMode = .private
            guard let nextIDs = device.makeTexture(descriptor: descriptor) else { return }
            let size = Float(contract?.inputSize ?? 1)
            let boxes = packet.detections.map { SIMD4<Float>($0.box.x1/size,$0.box.y1/size,$0.box.x2/size,$0.box.y2/size) }
            let coefficients = packet.detections.flatMap(\.coefficients)
            let trackIDs = packet.detections.map(\.trackID)
            var paletteColors = instanceColors(trackIDs, retained: packet.tracks.map(\.id))
            if let focusID, let index = trackIDs.firstIndex(of: focusID) { paletteColors[index] = focusColor }
            guard let proto = buffer(packet.prototypes.isEmpty ? [Float(0)] : packet.prototypes),
                  let coeff = buffer(coefficients.isEmpty ? [Float(0)] : coefficients),
                  let box = buffer(boxes.isEmpty ? [SIMD4<Float>(repeating: 0)] : boxes),
                  let colorBuffer = buffer(paletteColors.isEmpty ? [SIMD4<Float>(repeating: 0)] : paletteColors),
                  let compute = command.makeComputeCommandEncoder() else { return }
            // Text-guided detections have boxes only. Never read empty mask coefficients.
            var shape = SIMD4<UInt32>(UInt32(w),UInt32(h),packet.textGuided ? 0 : UInt32(packet.detections.count),UInt32(contract?.maskChannels ?? 1))
            compute.setComputePipelineState(maskState)
            compute.setBuffer(proto, offset: 0, index: 0); compute.setBuffer(coeff, offset: 0, index: 1)
            compute.setBuffer(box, offset: 0, index: 2); compute.setBytes(&shape, length: MemoryLayout.size(ofValue: shape), index: 3)
            compute.setTexture(nextIDs, index: 0)
            compute.dispatchThreads(MTLSize(width: w, height: h, depth: 1), threadsPerThreadgroup: MTLSize(width: 8,height: 8,depth: 1))
            compute.endEncoding()
            ids = nextIDs; colors = colorBuffer; sequence = packet.frame.sequence; colorizedTrackID = focusID
            idsUseSourceCoordinates = false; refinementSequence = activeRefinement?.sequence
            if let mask = packet.sourceMask {
                guard let sourceTexture = texture(mask) else { return }
                ids = sourceTexture; idsUseSourceCoordinates = true
            } else if let refined = activeRefinement {
                if uploadedRefinementSequence != refined.sequence || refinementTexture == nil {
                    refinementTexture = texture(refined.mask)
                    uploadedRefinementSequence = refinementTexture == nil ? nil : refined.sequence
                }
                let detailed = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Uint,
                    width: refined.mask.width, height: refined.mask.height, mipmapped: false)
                detailed.usage = [.shaderRead, .shaderWrite]; detailed.storageMode = .private
                var oldBoxes = [SIMD4<Float>](repeating: .zero, count: max(1, packet.detections.count))
                var currentBoxes = oldBoxes
                var sourceIDs = [UInt32](repeating: 0, count: oldBoxes.count)
                for warp in warps {
                    let old = warp.sourceBox, new = warp.currentBox
                    oldBoxes[warp.currentIndex] = SIMD4(old.x1, old.y1, old.x2, old.y2)
                    currentBoxes[warp.currentIndex] = SIMD4(new.x1, new.y1, new.x2, new.y2)
                    sourceIDs[warp.currentIndex] = UInt32(warp.sourceIndex+1)
                }
                guard let sourceTexture = refinementTexture, let composed = device.makeTexture(descriptor: detailed),
                      let old = buffer(oldBoxes), let current = buffer(currentBoxes), let source = buffer(sourceIDs),
                      let propagate = command.makeComputeCommandEncoder() else { return }
                let geometry = Letterbox(width: width, height: height, size: contract?.inputSize ?? 1)
                var nativeCrop = SIMD4(geometry.padX/geometry.size, geometry.padY/geometry.size,
                    Float(width)*geometry.scale/geometry.size, Float(height)*geometry.scale/geometry.size)
                var compositionShape = SIMD4<UInt32>(UInt32(refined.mask.width), UInt32(refined.mask.height),
                                                     UInt32(packet.detections.count), UInt32(warps.count))
                propagate.setComputePipelineState(propagationState)
                propagate.setBuffer(old, offset: 0, index: 0); propagate.setBuffer(current, offset: 0, index: 1)
                propagate.setBuffer(source, offset: 0, index: 2)
                propagate.setBytes(&compositionShape, length: MemoryLayout.size(ofValue: compositionShape), index: 3)
                propagate.setBytes(&nativeCrop, length: MemoryLayout.size(ofValue: nativeCrop), index: 4)
                if !renderBaseline {
                    // ContourPropagation returns warps in current detection order.
                    warps.map { UInt32($0.currentIndex) }.withUnsafeBytes {
                        propagate.setBytes($0.baseAddress!, length: $0.count, index: 5)
                    }
                }
                propagate.setTexture(nextIDs, index: 0); propagate.setTexture(sourceTexture, index: 1)
                propagate.setTexture(composed, index: 2)
                propagate.dispatchThreads(MTLSize(width: refined.mask.width, height: refined.mask.height, depth: 1),
                                          threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
                propagate.endEncoding()
                ids = composed; idsUseSourceCoordinates = true
            }
        }
        guard let ids, let colors, let render = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        let fit = min(view.drawableSize.width/Double(width), view.drawableSize.height/Double(height))
        let vw = Double(width)*fit, vh = Double(height)*fit
        render.setViewport(MTLViewport(originX: (view.drawableSize.width-vw)/2, originY: (view.drawableSize.height-vh)/2,
                                       width: vw,height: vh,znear: 0,zfar: 1))
        var crop = SIMD4<Float>(0,0,1,1)
        if let contract = packet.contract, !idsUseSourceCoordinates {
            let geometry = Letterbox(width: width,height: height,size: contract.inputSize)
            crop = SIMD4(geometry.padX/geometry.size,geometry.padY/geometry.size,
                         Float(width)*geometry.scale/geometry.size,Float(height)*geometry.scale/geometry.size)
        }
        var mirror: UInt32 = drawKey.mirrored ? 1 : 0
        var fillOpacity: Float = drawKey.style == nil ? 0.18 : 0.04
        var edge = SIMD2<Float>(lineWidth/Float(max(vw,1)),lineWidth/Float(max(vh,1)))
        render.setRenderPipelineState(renderState)
        render.setFragmentTexture(cameraTexture,index: 0); render.setFragmentTexture(ids,index: 1)
        render.setFragmentBuffer(colors,offset: 0,index: 0)
        render.setFragmentBytes(&crop,length: MemoryLayout.size(ofValue: crop),index: 1)
        render.setFragmentBytes(&mirror,length: MemoryLayout.size(ofValue: mirror),index: 2)
        render.setFragmentBytes(&edge,length: MemoryLayout.size(ofValue: edge),index: 3)
        render.setFragmentBytes(&fillOpacity,length: MemoryLayout.size(ofValue: fillOpacity),index: 4)
        render.drawPrimitives(type: .triangle,vertexStart: 0,vertexCount: 3); render.endEncoding()
        command.present(drawable)
        var frameColors = colorSlots.mapValues { palette[$0] }
        if let focusID, frameColors[focusID] != nil { frameColors[focusID] = focusColor }
        let displayedColors = frameColors
        command.addCompletedHandler { [inFlight, measurements, displayMeter, displayedObjects, packet, cameraReference, weak self] command in
            // Keep the CVPixelBuffer/texture wrapper alive until the GPU has finished reading it.
            _ = cameraReference; _ = packet.frame.pixels
            if command.status == .completed {
                displayedObjects.set((packet, displayedColors))
                displayMeter.add(sequence: packet.frame.sequence, finished: ProcessInfo.processInfo.systemUptime, received: packet.frame.received)
                measurements.set(RenderMeasurement(sequence: packet.frame.sequence, received: packet.frame.received,
                    finished: ProcessInfo.processInfo.systemUptime, gpuMS: max(0,command.gpuEndTime-command.gpuStartTime)*1000))
            } else { self?.onError?(command.error?.localizedDescription ?? "Metal command failed.") }
            inFlight.signal()
        }
        command.commit(); lastDraw = drawKey; committed = true
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct Vertex { float4 position [[position]]; float2 uv; };
    vertex Vertex renderQuad(uint i [[vertex_id]]) {
        float2 p = i == 0 ? float2(-1,-1) : (i == 1 ? float2(3,-1) : float2(-1,3));
        return {float4(p,0,1), float2((p.x+1)*0.5,(1-p.y)*0.5)};
    }
    kernel void masks(device const float* proto [[buffer(0)]], device const float* coeff [[buffer(1)]],
                      device const float4* boxes [[buffer(2)]], constant uint4& shape [[buffer(3)]],
                      texture2d<uint,access::write> ids [[texture(0)]], uint2 p [[thread_position_in_grid]]) {
        if (p.x >= shape.x || p.y >= shape.y) return;
        float2 uv = (float2(p)+0.5)/float2(shape.xy); uint id = 0;
        for (uint n=0;n<shape.z;n++) {
            float4 b = boxes[n];
            if (uv.x < b.x || uv.y < b.y || uv.x >= b.z || uv.y >= b.w) continue;
            float sum = 0;
            for (uint c=0;c<shape.w;c++) sum += coeff[n*shape.w+c]*proto[c*shape.x*shape.y+p.y*shape.x+p.x];
            if (sum > 0) { id = n+1; break; }
        }
        ids.write(uint4(id),p);
    }
    uint instanceAt(texture2d<uint,access::read> ids,float2 uv,float4 crop) {
        if (any(uv < 0.0) || any(uv >= 1.0)) return 0;
        float2 p = crop.xy+uv*crop.zw;
        uint2 dims = uint2(ids.get_width(),ids.get_height());
        return ids.read(min(uint2(clamp(p,0.0,1.0)*float2(dims)),dims-1)).r;
    }
    kernel void propagateContours(device const float4* oldBoxes [[buffer(0)]],
                                  device const float4* currentBoxes [[buffer(1)]],
                                  device const uint* sourceIDs [[buffer(2)]],
                                  constant uint4& shape [[buffer(3)]], constant float4& nativeCrop [[buffer(4)]],
                                  texture2d<uint,access::read> nativeIDs [[texture(0)]],
                                  texture2d<uint,access::read> refinedIDs [[texture(1)]],
                                  texture2d<uint,access::write> output [[texture(2)]],
                                  uint2 p [[thread_position_in_grid]]) {
        if (p.x >= shape.x || p.y >= shape.y) return;
        float2 uv = (float2(p)+0.5)/float2(shape.xy);
        uint nativeID = instanceAt(nativeIDs,uv,nativeCrop), id = 0;
        // Keep current detection order, including at overlaps. An eligible object uses SAM only;
        // every other object uses its current native mask. Never copy an old instance ID directly.
        for (uint n=0;n<shape.z;n++) {
            if (sourceIDs[n] == 0) {
                if (nativeID == n+1) { id = n+1; break; }
                continue;
            }
            float4 current = currentBoxes[n];
            if (any(uv < current.xy) || any(uv >= current.zw)) continue;
            float4 old = oldBoxes[n];
            float2 oldUV = old.xy+(uv-current.xy)/(current.zw-current.xy)*(old.zw-old.xy);
            if (instanceAt(refinedIDs,oldUV,float4(0,0,1,1)) == sourceIDs[n]) { id = n+1; break; }
        }
        output.write(uint4(id),p);
    }
    kernel void propagateEligibleContours(device const float4* oldBoxes [[buffer(0)]],
                                          device const float4* currentBoxes [[buffer(1)]],
                                          device const uint* sourceIDs [[buffer(2)]],
                                          constant uint4& shape [[buffer(3)]], constant float4& nativeCrop [[buffer(4)]],
                                          constant uint* eligibleIndices [[buffer(5)]],
                                          texture2d<uint,access::read> nativeIDs [[texture(0)]],
                                          texture2d<uint,access::read> refinedIDs [[texture(1)]],
                                          texture2d<uint,access::write> output [[texture(2)]],
                                          uint2 p [[thread_position_in_grid]]) {
        if (p.x >= shape.x || p.y >= shape.y) return;
        float2 uv = (float2(p)+0.5)/float2(shape.xy);
        uint id = instanceAt(nativeIDs,uv,nativeCrop);
        // A refined object cannot also claim its old native pixels. An unrefined
        // native winner only competes with higher-priority eligible objects.
        if (id != 0 && sourceIDs[id-1] != 0) id = 0;
        for (uint i=0;i<shape.w;i++) {
            uint n = eligibleIndices[i];
            if (id != 0 && n+1 >= id) break;
            float4 current = currentBoxes[n];
            if (any(uv < current.xy) || any(uv >= current.zw)) continue;
            float4 old = oldBoxes[n];
            float2 oldUV = old.xy+(uv-current.xy)/(current.zw-current.xy)*(old.zw-old.xy);
            if (instanceAt(refinedIDs,oldUV,float4(0,0,1,1)) == sourceIDs[n]) { id = n+1; break; }
        }
        output.write(uint4(id),p);
    }
    fragment float4 overlay(Vertex v [[stage_in]],texture2d<float> camera [[texture(0)]],
                            texture2d<uint,access::read> ids [[texture(1)]],device const float4* colors [[buffer(0)]],
                            constant float4& crop [[buffer(1)]],constant uint& mirror [[buffer(2)]],
                            constant float2& step [[buffer(3)]],constant float& fillOpacity [[buffer(4)]]) {
        constexpr sampler s(filter::linear,address::clamp_to_edge);
        float2 uv = v.uv; if (mirror != 0) uv.x = 1-uv.x;
        float4 image = camera.sample(s,uv);
        uint id = instanceAt(ids,uv,crop);
        if (id == 0) return float4(image.rgb,1);
        float3 color = colors[id-1].rgb;
        bool boundary = instanceAt(ids,uv+float2(step.x,0),crop)!=id || instanceAt(ids,uv-float2(step.x,0),crop)!=id ||
                        instanceAt(ids,uv+float2(0,step.y),crop)!=id || instanceAt(ids,uv-float2(0,step.y),crop)!=id;
        return float4(mix(image.rgb,color,boundary ? 0.95 : fillOpacity),1);
    }
    """
}
#endif
