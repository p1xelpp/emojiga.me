import Foundation
import GateEngine

@MainActor
enum GameAssets {
    static let whiteCubeTexture = Texture(path: "white_cube.png")
    static let greenCubeTexture = Texture(path: "green_cube.png")
    static let grayCubeTexture = Texture(path: "gray_cube.png")
    static let skyTexture = Texture(path: "sky_defaulr.png")
    static let marseyGeometry = Geometry(path: "marsey/model.obj")
    static let marseyTexture = Texture(path: "marsey/Material_baseColor.png")
    static let boxTexture = Texture(path: "box/box.png")

    static func attackTexture(named attack: String) -> Texture {
        Texture(path: "emojis/\(attack).png")
    }

    nonisolated static func resourceLocations(sourceFile: String) -> [String] {
        var candidates = [
            URL(fileURLWithPath: sourceFile)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Assets", isDirectory: true),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Assets", isDirectory: true),
        ]
        var seen = Set<String>()
        candidates = candidates.filter { candidate in
            let path = candidate.standardizedFileURL.path
            guard seen.insert(path).inserted else { return false }
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
        return candidates.map { $0.absoluteString }
    }
}

@MainActor
final class SkyDomeSystem: System {
    private var skyEntity: Entity?

    override func setup(game: Game, input: HID) async {
        let entity = Entity()
        entity.insert(Transform3Component.self) { component in
            component.scale = Size3(400)
        }
        entity.insert(RenderingGeometryComponent.self) { component in
            component.insert(Geometry(as: .unitSphere))
            component.flags = []
        }
        entity.insert(MaterialComponent.self) { component in
            component.fragmentShader = .textureSample
            component.channel(0) { channel in
                channel.texture = GameAssets.skyTexture
            }
        }
        skyEntity = entity
        game.insertEntity(entity)
    }

    override func update(game: Game, input: HID, withTimePassed deltaTime: Float) async {
        guard let skyEntity, let camera = game.cameraEntity,
              let cameraTransform = camera.component(ofType: Transform3Component.self) else {
            return
        }
        skyEntity[Transform3Component.self].position = cameraTransform.position
    }

    override class var phase: System.Phase { .simulation }
}
