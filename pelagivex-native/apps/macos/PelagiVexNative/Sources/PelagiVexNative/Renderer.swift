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
    let measurements = Snapshot<RenderMeasurement>()
    let displayedObjects = Snapshot<(Packet, [Int: SIMD4<Float>])>()
    let displayMeter = FrameMeter()
    private let pipeline: Pipeline
    private let device: MTLDevice
    private let commands: MTLCommandQueue
    private let renderState: MTLRenderPipelineState
    private let maskState: MTLComputePipelineState
    private var cache: CVMetalTextureCache!
    private let inFlight = DispatchSemaphore(value: 2)
    private var sequence: UInt64 = 0
    private var ids: MTLTexture?
    private var colors: MTLBuffer?
    private var colorSlots: [Int: Int] = [:]
    // The first colors are deliberately well separated; a slot is unique among visible tracks.
    private let palette: [SIMD4<Float>] = [
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
    var mirrored = false
    var onError: ((String) -> Void)?

    init(device: MTLDevice, pipeline: Pipeline) throws {
        self.device = device; self.pipeline = pipeline
        guard let commands = device.makeCommandQueue() else { throw PipelineError.invalid("Metal command queue unavailable.") }
        self.commands = commands
        let library = try device.makeLibrary(source: Self.shader, options: nil)
        guard let vertex = library.makeFunction(name: "renderQuad"), let fragment = library.makeFunction(name: "overlay"),
              let masks = library.makeFunction(name: "masks") else { throw PipelineError.invalid("Metal shaders unavailable.") }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex; descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        renderState = try device.makeRenderPipelineState(descriptor: descriptor)
        maskState = try device.makeComputePipelineState(function: masks)
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
    private func instanceColors(_ trackIDs: [Int]) -> [SIMD4<Float>] {
        let visible = Set(trackIDs)
        colorSlots = colorSlots.filter { visible.contains($0.key) }
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
        guard inFlight.wait(timeout: .now()) == .success else { return }
        var committed = false
        defer { if !committed { inFlight.signal() } }
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let command = commands.makeCommandBuffer() else { return }
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.02, green: 0.025, blue: 0.035, alpha: 1)
        guard let packet = pipeline.packets.get() else {
            ids = nil; colors = nil; sequence = 0; colorSlots.removeAll(); displayedObjects.set(nil)
            let encoder = command.makeRenderCommandEncoder(descriptor: pass); encoder?.endEncoding()
            command.present(drawable); command.addCompletedHandler { [inFlight] _ in inFlight.signal() }
            command.commit(); committed = true; return
        }
        let width = CVPixelBufferGetWidth(packet.frame.pixels), height = CVPixelBufferGetHeight(packet.frame.pixels)
        var cameraReference: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, packet.frame.pixels, nil, .bgra8Unorm,
                                                       width, height, 0, &cameraReference) == kCVReturnSuccess,
              let cameraReference, let cameraTexture = CVMetalTextureGetTexture(cameraReference) else { return }
        if ids == nil || sequence != packet.frame.sequence {
            let contract = packet.contract
            let w = contract?.prototypeWidth ?? 1, h = contract?.prototypeHeight ?? 1
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Uint, width: w, height: h, mipmapped: false)
            descriptor.usage = [.shaderRead, .shaderWrite]; descriptor.storageMode = .private
            guard let nextIDs = device.makeTexture(descriptor: descriptor) else { return }
            let size = Float(contract?.inputSize ?? 1)
            let boxes = packet.detections.map { SIMD4<Float>($0.box.x1/size,$0.box.y1/size,$0.box.x2/size,$0.box.y2/size) }
            let coefficients = packet.detections.flatMap(\.coefficients)
            guard let proto = buffer(packet.prototypes.isEmpty ? [Float(0)] : packet.prototypes),
                  let coeff = buffer(coefficients.isEmpty ? [Float(0)] : coefficients),
                  let box = buffer(boxes.isEmpty ? [SIMD4<Float>(repeating: 0)] : boxes),
                  let colorBuffer = buffer(packet.detections.isEmpty ? [SIMD4<Float>(repeating: 0)] : instanceColors(packet.detections.map(\.trackID))),
                  let compute = command.makeComputeCommandEncoder() else { return }
            var shape = SIMD4<UInt32>(UInt32(w),UInt32(h),UInt32(packet.detections.count),UInt32(contract?.maskChannels ?? 1))
            compute.setComputePipelineState(maskState)
            compute.setBuffer(proto, offset: 0, index: 0); compute.setBuffer(coeff, offset: 0, index: 1)
            compute.setBuffer(box, offset: 0, index: 2); compute.setBytes(&shape, length: MemoryLayout.size(ofValue: shape), index: 3)
            compute.setTexture(nextIDs, index: 0)
            compute.dispatchThreads(MTLSize(width: w, height: h, depth: 1), threadsPerThreadgroup: MTLSize(width: 8,height: 8,depth: 1))
            compute.endEncoding()
            ids = nextIDs; colors = colorBuffer; sequence = packet.frame.sequence
        }
        guard let ids, let colors, let render = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        let fit = min(view.drawableSize.width/Double(width), view.drawableSize.height/Double(height))
        let vw = Double(width)*fit, vh = Double(height)*fit
        render.setViewport(MTLViewport(originX: (view.drawableSize.width-vw)/2, originY: (view.drawableSize.height-vh)/2,
                                       width: vw,height: vh,znear: 0,zfar: 1))
        var crop = SIMD4<Float>(0,0,1,1)
        if let contract = packet.contract {
            let geometry = Letterbox(width: width,height: height,size: contract.inputSize)
            crop = SIMD4(geometry.padX/geometry.size,geometry.padY/geometry.size,
                         Float(width)*geometry.scale/geometry.size,Float(height)*geometry.scale/geometry.size)
        }
        var mirror: UInt32 = mirrored ? 1 : 0
        var edge = SIMD2<Float>(Float(4/max(vw,1)),Float(4/max(vh,1)))
        render.setRenderPipelineState(renderState)
        render.setFragmentTexture(cameraTexture,index: 0); render.setFragmentTexture(ids,index: 1)
        render.setFragmentBuffer(colors,offset: 0,index: 0)
        render.setFragmentBytes(&crop,length: MemoryLayout.size(ofValue: crop),index: 1)
        render.setFragmentBytes(&mirror,length: MemoryLayout.size(ofValue: mirror),index: 2)
        render.setFragmentBytes(&edge,length: MemoryLayout.size(ofValue: edge),index: 3)
        render.drawPrimitives(type: .triangle,vertexStart: 0,vertexCount: 3); render.endEncoding()
        command.present(drawable)
        let frameColors = colorSlots.mapValues { palette[$0] }
        command.addCompletedHandler { [inFlight, measurements, displayMeter, displayedObjects, packet, cameraReference, weak self] command in
            // Keep the CVPixelBuffer/texture wrapper alive until the GPU has finished reading it.
            _ = cameraReference; _ = packet.frame.pixels
            if command.status == .completed {
                displayedObjects.set((packet, frameColors))
                displayMeter.add(sequence: packet.frame.sequence, finished: ProcessInfo.processInfo.systemUptime, received: packet.frame.received)
                measurements.set(RenderMeasurement(sequence: packet.frame.sequence, received: packet.frame.received,
                    finished: ProcessInfo.processInfo.systemUptime, gpuMS: max(0,command.gpuEndTime-command.gpuStartTime)*1000))
            } else { self?.onError?(command.error?.localizedDescription ?? "Metal command failed.") }
            inFlight.signal()
        }
        command.commit(); committed = true
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
    fragment float4 overlay(Vertex v [[stage_in]],texture2d<float> camera [[texture(0)]],
                            texture2d<uint,access::read> ids [[texture(1)]],device const float4* colors [[buffer(0)]],
                            constant float4& crop [[buffer(1)]],constant uint& mirror [[buffer(2)]],
                            constant float2& step [[buffer(3)]]) {
        constexpr sampler s(filter::linear,address::clamp_to_edge);
        float2 uv = v.uv; if (mirror != 0) uv.x = 1-uv.x;
        float4 image = camera.sample(s,uv); uint id = instanceAt(ids,uv,crop);
        if (id == 0) return float4(image.rgb,1);
        float3 color = colors[id-1].rgb;
        bool boundary = instanceAt(ids,uv+float2(step.x,0),crop)!=id || instanceAt(ids,uv-float2(step.x,0),crop)!=id ||
                        instanceAt(ids,uv+float2(0,step.y),crop)!=id || instanceAt(ids,uv-float2(0,step.y),crop)!=id;
        return float4(mix(image.rgb,color,boundary ? 0.95 : 0.18),1);
    }
    """
}
#endif
