import SceneKit
import SwiftUI
import UIKit

/// 读 GLB（glTF 2.0 二进制）。只支持大橘模型用到的部分：网格的顶点、法线、UV、索引，
/// 基础颜色贴图或颜色，节点的矩阵或平移旋转缩放。没有骨骼和动画。
enum GLBLoader {
    struct Failure: Error {}

    static func load(url: URL) throws -> SCNNode {
        let data = try Data(contentsOf: url)
        guard data.count > 20 else { throw Failure() }
        func u32(_ offset: Int) -> UInt32 {
            data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
        }
        guard u32(0) == 0x4654_6C67 else { throw Failure() } // "glTF"
        var json: [String: Any] = [:]
        var bin = Data()
        var offset = 12
        while offset + 8 <= data.count {
            let length = Int(u32(offset))
            let type = u32(offset + 4)
            let end = min(data.count, offset + 8 + length)
            let chunk = data.subdata(in: (offset + 8) ..< end)
            if type == 0x4E4F_534A { // "JSON"
                json = (try JSONSerialization.jsonObject(with: chunk)) as? [String: Any] ?? [:]
            } else if type == 0x004E_4942 { // "BIN\0"
                bin = chunk
            }
            offset += 8 + length
        }
        return try Builder(json: json, bin: bin).scene()
    }

    private struct Builder {
        let json: [String: Any]
        let bin: Data

        private func list(_ key: String) -> [[String: Any]] { json[key] as? [[String: Any]] ?? [] }

        func scene() throws -> SCNNode {
            let root = SCNNode()
            let scenes = list("scenes")
            let sceneIndex = json["scene"] as? Int ?? 0
            let nodeIndices = (scenes.indices.contains(sceneIndex) ? scenes[sceneIndex]["nodes"] as? [Int] : nil) ?? Array(list("nodes").indices)
            for index in nodeIndices { root.addChildNode(try node(index)) }
            return root
        }

        private func node(_ index: Int) throws -> SCNNode {
            let nodes = list("nodes")
            guard nodes.indices.contains(index) else { throw Failure() }
            let info = nodes[index]
            let result = SCNNode()
            if let m = (info["matrix"] as? [NSNumber])?.map(\.floatValue), m.count == 16 {
                // glTF 的矩阵按列存
                result.simdTransform = simd_float4x4(columns: (
                    SIMD4(m[0], m[1], m[2], m[3]),
                    SIMD4(m[4], m[5], m[6], m[7]),
                    SIMD4(m[8], m[9], m[10], m[11]),
                    SIMD4(m[12], m[13], m[14], m[15])
                ))
            } else {
                if let t = (info["translation"] as? [NSNumber])?.map(\.floatValue), t.count == 3 { result.simdPosition = SIMD3(t[0], t[1], t[2]) }
                if let r = (info["rotation"] as? [NSNumber])?.map(\.floatValue), r.count == 4 { result.simdOrientation = simd_quatf(ix: r[0], iy: r[1], iz: r[2], r: r[3]) }
                if let s = (info["scale"] as? [NSNumber])?.map(\.floatValue), s.count == 3 { result.simdScale = SIMD3(s[0], s[1], s[2]) }
            }
            if let meshIndex = info["mesh"] as? Int {
                for geometry in try geometries(meshIndex) { result.addChildNode(SCNNode(geometry: geometry)) }
            }
            for child in info["children"] as? [Int] ?? [] { result.addChildNode(try node(child)) }
            return result
        }

        private struct Accessor {
            let data: Data
            let count: Int
            let components: Int
            let componentSize: Int
            let stride: Int
        }

        private func accessor(_ index: Int) throws -> Accessor {
            let accessors = list("accessors")
            let views = list("bufferViews")
            guard accessors.indices.contains(index) else { throw Failure() }
            let info = accessors[index]
            guard let viewIndex = info["bufferView"] as? Int, views.indices.contains(viewIndex), let count = info["count"] as? Int, count > 0 else { throw Failure() }
            let view = views[viewIndex]
            let components = ["SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4][info["type"] as? String ?? ""] ?? 1
            let componentSize = [5120: 1, 5121: 1, 5122: 2, 5123: 2, 5125: 4, 5126: 4][info["componentType"] as? Int ?? 0] ?? 4
            let stride = view["byteStride"] as? Int ?? components * componentSize
            let start = (view["byteOffset"] as? Int ?? 0) + (info["byteOffset"] as? Int ?? 0)
            let length = stride * (count - 1) + components * componentSize
            guard start >= 0, start + length <= bin.count else { throw Failure() }
            return Accessor(data: bin.subdata(in: start ..< start + length), count: count, components: components, componentSize: componentSize, stride: stride)
        }

        private func geometries(_ meshIndex: Int) throws -> [SCNGeometry] {
            let meshes = list("meshes")
            guard meshes.indices.contains(meshIndex) else { throw Failure() }
            var result: [SCNGeometry] = []
            for primitive in meshes[meshIndex]["primitives"] as? [[String: Any]] ?? [] {
                guard (primitive["mode"] as? Int ?? 4) == 4, let attributes = primitive["attributes"] as? [String: Int], let position = attributes["POSITION"] else { continue }
                var sources: [SCNGeometrySource] = []
                let semantics: [(String, SCNGeometrySource.Semantic)] = [("POSITION", .vertex), ("NORMAL", .normal), ("TEXCOORD_0", .texcoord)]
                for (name, semantic) in semantics {
                    guard let index = attributes[name] else { continue }
                    let item = try accessor(index)
                    sources.append(SCNGeometrySource(
                        data: item.data, semantic: semantic, vectorCount: item.count, usesFloatComponents: true,
                        componentsPerVector: item.components, bytesPerComponent: item.componentSize, dataOffset: 0, dataStride: item.stride
                    ))
                }
                let element: SCNGeometryElement
                if let indices = primitive["indices"] as? Int {
                    let item = try accessor(indices)
                    element = SCNGeometryElement(data: item.data, primitiveType: .triangles, primitiveCount: item.count / 3, bytesPerIndex: item.componentSize)
                } else {
                    let count = try accessor(position).count
                    element = SCNGeometryElement(indices: (0 ..< UInt32(count)).map { $0 }, primitiveType: .triangles)
                }
                let geometry = SCNGeometry(sources: sources, elements: [element])
                geometry.materials = [material(primitive["material"] as? Int)]
                result.append(geometry)
            }
            return result
        }

        private func material(_ index: Int?) -> SCNMaterial {
            let material = SCNMaterial()
            material.isDoubleSided = false
            let materials = list("materials")
            guard let index, materials.indices.contains(index) else { return material }
            let info = materials[index]
            let pbr = info["pbrMetallicRoughness"] as? [String: Any] ?? [:]
            let unlit = (info["extensions"] as? [String: Any])?["KHR_materials_unlit"] != nil
            material.lightingModel = unlit ? .constant : .lambert
            if let texture = (pbr["baseColorTexture"] as? [String: Any])?["index"] as? Int, let image = image(texture: texture) {
                material.diffuse.contents = image
                material.diffuse.wrapS = .repeat
                material.diffuse.wrapT = .repeat
                material.diffuse.mipFilter = .linear
            } else if let factor = (pbr["baseColorFactor"] as? [NSNumber])?.map(\.doubleValue), factor.count == 4 {
                material.diffuse.contents = UIColor(red: factor[0], green: factor[1], blue: factor[2], alpha: factor[3])
            }
            return material
        }

        private func image(texture: Int) -> UIImage? {
            let textures = list("textures")
            let images = list("images")
            let views = list("bufferViews")
            guard textures.indices.contains(texture), let source = textures[texture]["source"] as? Int, images.indices.contains(source),
                  let viewIndex = images[source]["bufferView"] as? Int, views.indices.contains(viewIndex) else { return nil }
            let view = views[viewIndex]
            let start = view["byteOffset"] as? Int ?? 0
            let length = view["byteLength"] as? Int ?? 0
            guard length > 0, start + length <= bin.count else { return nil }
            return UIImage(data: bin.subdata(in: start ..< start + length))
        }
    }
}

/// 大橘的 3D 模型：左右拖动转身，点一下摸摸它；每次互动做一个小动作
struct CatModelView: UIViewRepresentable {
    /// 每次互动加一，触发一次动作
    let reaction: Int
    let reactionKind: String
    let sleeping: Bool
    let onTap: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> CatSceneView {
        let view = CatSceneView()
        view.onTap = onTap
        context.coordinator.lastReaction = reaction
        return view
    }

    func updateUIView(_ view: CatSceneView, context: Context) {
        view.onTap = onTap
        view.setSleeping(sleeping)
        if context.coordinator.lastReaction != reaction {
            context.coordinator.lastReaction = reaction
            view.react(reactionKind)
        }
    }

    final class Coordinator {
        var lastReaction = 0
    }
}

final class CatSceneView: UIView {
    private let sceneView = SCNView()
    private let placeholder = UIImageView(image: UIImage(systemName: "pawprint.fill"))
    private var pivot: SCNNode?
    private var sleeping = false
    var onTap: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        sceneView.backgroundColor = .clear
        sceneView.antialiasingMode = .multisampling4X
        sceneView.preferredFramesPerSecond = 60
        sceneView.rendersContinuously = false
        sceneView.isPlaying = true
        addSubview(sceneView)
        placeholder.tintColor = UIColor.systemOrange.withAlphaComponent(0.3)
        placeholder.contentMode = .scaleAspectFit
        addSubview(placeholder)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        sceneView.addGestureRecognizer(pan)
        sceneView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap)))
        load()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        sceneView.frame = bounds
        placeholder.frame = CGRect(x: bounds.midX - 40, y: bounds.midY - 40, width: 80, height: 80)
    }

    private func load() {
        Task.detached(priority: .userInitiated) {
            guard let url = Bundle.main.url(forResource: "cute_cat", withExtension: "glb"), let model = try? GLBLoader.load(url: url) else { return }
            let scene = CatSceneView.makeScene(model)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.sceneView.scene = scene.scene
                self.pivot = scene.pivot
                self.placeholder.isHidden = true
                self.startIdle()
            }
        }
    }

    private nonisolated static func makeScene(_ model: SCNNode) -> (scene: SCNScene, pivot: SCNNode) {
        let scene = SCNScene()
        let content = SCNNode()
        content.addChildNode(model)
        // 缩放到最长边 1.5，放到原点
        let (minimum, maximum) = content.boundingBox
        let largest = max(maximum.x - minimum.x, max(maximum.y - minimum.y, maximum.z - minimum.z))
        if largest > 0 {
            let scale = 1.5 / largest
            content.scale = SCNVector3(scale, scale, scale)
            content.position = SCNVector3(-(minimum.x + maximum.x) * scale / 2, -(minimum.y + maximum.y) * scale / 2 - 0.05, -(minimum.z + maximum.z) * scale / 2)
        }
        let pivot = SCNNode()
        // 模型的正面朝 +X，转过来面向镜头
        pivot.eulerAngles.y = -.pi / 2
        pivot.addChildNode(content)
        scene.rootNode.addChildNode(pivot)
        let camera = SCNCamera()
        camera.fieldOfView = 34
        camera.zNear = 0.01
        camera.zFar = 100
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0.12, 4.1)
        cameraNode.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(cameraNode)
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 600
        scene.rootNode.addChildNode(ambient)
        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .omni
        key.light?.intensity = 700
        key.position = SCNVector3(-2.2, 2.8, 3.2)
        scene.rootNode.addChildNode(key)
        return (scene, pivot)
    }

    /// 呼吸一样轻轻起伏；睡着时更慢
    private func startIdle() {
        guard let pivot else { return }
        pivot.removeAction(forKey: "idle")
        let duration = sleeping ? 2.4 : 1.6
        let breathe = SCNAction.sequence([
            .scale(to: sleeping ? 0.985 : 1.015, duration: duration),
            .scale(to: 1, duration: duration),
        ])
        breathe.timingMode = .easeInEaseOut
        pivot.runAction(.repeatForever(breathe), forKey: "idle")
    }

    func setSleeping(_ value: Bool) {
        guard value != sleeping else { return }
        sleeping = value
        sceneView.alpha = value ? 0.75 : 1
        startIdle()
    }

    func react(_ kind: String) {
        guard let pivot else { return }
        let action: SCNAction
        switch kind {
        case "feed", "treat":
            action = .sequence([.scale(by: 1.05, duration: 0.16), .scale(by: 1 / 1.05, duration: 0.22)])
        case "play":
            action = .sequence([.moveBy(x: 0, y: 0.18, z: 0, duration: 0.15), .moveBy(x: 0, y: -0.18, z: 0, duration: 0.22)])
        case "bathe":
            action = .sequence([
                .rotateBy(x: 0, y: 0, z: 0.08, duration: 0.08), .rotateBy(x: 0, y: 0, z: -0.16, duration: 0.12),
                .rotateBy(x: 0, y: 0, z: 0.08, duration: 0.08),
            ])
        case "sleep":
            action = .sequence([.scale(by: 0.95, duration: 0.25), .wait(duration: 0.18), .scale(by: 1 / 0.95, duration: 0.24)])
        case "wake":
            action = .sequence([
                .scale(by: 1.08, duration: 0.16), .moveBy(x: 0, y: 0.1, z: 0, duration: 0.12),
                .moveBy(x: 0, y: -0.1, z: 0, duration: 0.18), .scale(by: 1 / 1.08, duration: 0.2),
            ])
        default:
            action = .sequence([.scale(by: 1.06, duration: 0.14), .scale(by: 1 / 1.06, duration: 0.22)])
        }
        pivot.childNodes.first?.removeAction(forKey: "reaction")
        pivot.childNodes.first?.runAction(action, forKey: "reaction")
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let pivot else { return }
        let translation = gesture.translation(in: sceneView)
        pivot.eulerAngles.y += Float(translation.x) * 0.012
        gesture.setTranslation(.zero, in: sceneView)
    }

    @objc private func handleTap() {
        onTap?()
    }
}
