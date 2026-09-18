import AppKit
import SceneKit
import OpenTileCore

/// Layered sprite puppet with hierarchical joints and spring-driven secondary motion.
@MainActor
final class CompanionCharacter {
    let scene = SCNScene()
    let body = SCNNode()
    private(set) var loadError: Error?
    private(set) var rig = CompanionRig()
    private(set) var behavior = CompanionBehavior()
    let waist = SCNNode()
    let neck = SCNNode()
    private var hair: [SCNNode] = []
    private var faceMaterial: SCNMaterial?
    private var lastTime: Double?

    nonisolated static var resourceBundle: Bundle {
        if let resources = Bundle.main.resourceURL,
           let bundled = Bundle(url: resources.appendingPathComponent("OpenTile_OpenTile.bundle")) { return bundled }
        return Bundle.module
    }

    init(modelURL: URL? = CompanionCharacter.resourceBundle.url(forResource: "NamiRig", withExtension: "png", subdirectory: "Companion")) {
        scene.rootNode.addChildNode(body)
        if let modelURL, let source = NSImage(contentsOf: modelURL),
           let atlas = source.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            // Atlas crops use top-left pixel coordinates. Overlapping neck and waist paint
            // lets the joints rotate without exposing a seam.
            func part(_ name: String, _ rect: CGRect, height: CGFloat, x: CGFloat, y: CGFloat, z: CGFloat, parent: SCNNode) -> SCNNode {
                let plane = SCNPlane(width: height * rect.width / rect.height, height: height)
                plane.widthSegmentCount = 12; plane.heightSegmentCount = 32
                let material = SCNMaterial()
                material.diffuse.contents = atlas.cropping(to: rect)
                material.lightingModel = .constant
                material.isDoubleSided = true
                material.blendMode = .alpha
                material.writesToDepthBuffer = false
                material.readsFromDepthBuffer = false
                plane.materials = [material]
                let node = SCNNode(geometry: plane)
                node.name = name; node.position = SCNVector3(x, y, z)
                node.renderingOrder = Int(z * 100)
                parent.addChildNode(node)
                return node
            }
            _ = part("legs", CGRect(x: 1020, y: 245, width: 516, height: 275), height: 1.10, x: 0, y: -0.95, z: 0.02, parent: body)
            waist.name = "waistJoint"; waist.position.y = -0.55; body.addChildNode(waist)
            _ = part("torso", CGRect(x: 585, y: 15, width: 350, height: 530), height: 1.65, x: 0, y: 0.22, z: 0.04, parent: waist)
            neck.name = "neckJoint"; neck.position.y = 1.0; waist.addChildNode(neck)
            let face = part("head", CGRect(x: 40, y: 30, width: 430, height: 410), height: 1.03, x: 0, y: 0.42, z: 0.08, parent: neck)
            (face.geometry as? SCNPlane)?.widthSegmentCount = 100
            (face.geometry as? SCNPlane)?.heightSegmentCount = 100
            faceMaterial = face.geometry?.firstMaterial
            faceMaterial?.shaderModifiers = [.geometry: Self.faceDeformation]
            let rear = part("rearHair", CGRect(x: 55, y: 505, width: 420, height: 500), height: 1.90, x: 0, y: -0.13, z: 0.01, parent: neck)
            let left = part("leftHair", CGRect(x: 665, y: 565, width: 145, height: 400), height: 1.16, x: -0.39, y: -0.31, z: 0.09, parent: neck)
            let right = part("rightHair", CGRect(x: 1230, y: 565, width: 140, height: 440), height: 1.22, x: 0.40, y: -0.34, z: 0.09, parent: neck)
            hair = [rear, left, right]
            for node in hair {
                guard let plane = node.geometry as? SCNPlane, let material = plane.firstMaterial else { continue }
                material.shaderModifiers = [.geometry: Self.hairDeformation]
                material.setValue(Float(plane.height), forKey: "partHeight")
            }
        } else { loadError = CocoaError(.fileReadCorruptFile) }
        let camera = SCNNode(); camera.camera = SCNCamera()
        camera.camera?.usesOrthographicProjection = true
        camera.camera?.orthographicScale = 1.7
        camera.position = SCNVector3(0, 0, 8)
        scene.rootNode.addChildNode(camera)
        applyRig()
    }

    func greet() { behavior.greet() }

    func pose(time: Double, spring: Double, intensity: Double, animated: Bool, attention: Double = 0) {
        guard animated, time.isFinite, spring.isFinite, intensity.isFinite, attention.isFinite else {
            rig.reset(); behavior.reset(); lastTime = nil; applyRig(); return
        }
        let delta = lastTime.map { max(0, min(1.0 / 30, time - $0)) } ?? 1.0 / 30
        lastTime = time
        behavior.step(delta: delta, time: time, attention: attention, drive: spring)
        rig.step(delta: delta, time: time, drive: spring - behavior.head.velocity * 0.4 - behavior.waist.velocity * 0.3, intensity: intensity)
        applyRig()
    }

    private func applyRig() {
        waist.eulerAngles.z = CGFloat(behavior.waist.position)
        waist.position.y = -0.55 + CGFloat(behavior.lift)
        waist.scale.y = 1 + CGFloat(behavior.breath)
        neck.eulerAngles.z = CGFloat(behavior.head.position)
        faceMaterial?.setValue(Float(rig.blink), forKey: "blinkAmount")
        for (index, node) in hair.enumerated() {
            node.geometry?.firstMaterial?.setValue(Float(rig.hair.position * (index == 0 ? 0.7 : 1)), forKey: "rootMotion")
            node.geometry?.firstMaterial?.setValue(Float(rig.tip.position), forKey: "tipMotion")
        }
    }

    private static let faceDeformation = """
    uniform float blinkAmount;
    #pragma body
    float x = _geometry.position.x / 1.08024 + 0.5;
    float y = 0.5 - _geometry.position.y / 1.03;
    float l = exp(-pow(abs((x - 0.416) / 0.10), 4.0) - pow(abs((y - 0.715) / 0.085), 4.0));
    float r = exp(-pow(abs((x - 0.674) / 0.10), 4.0) - pow(abs((y - 0.683) / 0.085), 4.0));
    _geometry.position.y += blinkAmount * 0.97 * 1.03 * ((y - 0.715) * l + (y - 0.683) * r);
    """

    private static let hairDeformation = """
    uniform float partHeight;
    uniform float rootMotion;
    uniform float tipMotion;
    #pragma body
    float t = clamp(0.5 - _geometry.position.y / partHeight, 0.0, 1.0);
    _geometry.position.x += partHeight * (rootMotion * t * t * 0.35 + tipMotion * t * t * t * 0.55);
    """
}
