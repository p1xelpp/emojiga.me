import Foundation
import GateEngine
import WorldData

@main
final class GateEngineWorldGame: GameDelegate {
    nonisolated func customResourceLocations() -> [String] {
        GameAssets.resourceLocations(sourceFile: #filePath)
    }

    func createMainWindow(game: Game, identifier: String) throws -> Window {
        try game.windowManager.createWindow(
            identifier: identifier,
            style: .system,
            options: .default
        )
    }

    func didFinishLaunching(game: Game, options: LaunchOptions) async {
        game.insertSystem(Collision3DSystem.self)
        game.insertSystem(StandardRenderingSystem.self)
        game.insertSystem(SkyDomeSystem.self)

        let camera = Entity(components: [Transform3Component.self, CameraComponent.self])
        camera[Transform3Component.self].position = Position3(0, 3, -10)
        game.insertEntity(camera)

        game.windowManager.mainWindow?.title = "Emoji-ga.me World Builder"
        game.windowManager.mainWindow?.clearColor = .lightBlue

        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.count == 2, arguments[0] == "--player", !arguments[1].isEmpty {
            game.windowManager.mainWindow?.title = "Emoji-ga_me Player"
            game.insertSystem(PlayerHUDRenderingSystem.self)
            game.insertSystem(BaseWorldEnginePlayer(host: arguments[1]))
        } else if arguments.isEmpty || arguments == ["--builder"] {
            game.insertSystem(WorldBuilderSystem.self)
        } else {
            fatalError("Usage: swift [--builder | --player HOST]")
        }
    }
}

private final class WorldBuilderSystem: System {
    private let worldWidth = 50.0
    private let worldDepth = 50.0
    private let mapURL = URL(fileURLWithPath: "../world.json", relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        .standardizedFileURL
    private var world: WorldEngine?
    private var ground: Entity?
    private var blockEntities: [BlockPosition: Entity] = [:]
    private var yaw: Degrees = .zero
    private var pitch: Degrees = 18
    private var previousLeftButtonState = false
    private var previousRightButtonState = false
    private var previousSaveKeyState = false
    private var previousLoadKeyState = false
    private var previousEscapeKeyState = false
    private var isPointerLocked = false

    override func setup(game: Game, input: HID) async {
        do {
            var loadedWorld = try WorldEngine(savePath: mapURL)
            if FileManager.default.fileExists(atPath: mapURL.path) {
                try loadedWorld.loadMap()
                print("Loaded \(loadedWorld.blocks.count) blocks from \(mapURL.path)")
            } else {
                print("World file not found at \(mapURL.path); starting with an empty map.")
            }
            world = loadedWorld
        } catch {
            print("Could not load \(mapURL.path): \(error.localizedDescription)")
            print("Starting with an empty map; F7 will save a replacement map.")
            do {
                world = try WorldEngine(savePath: mapURL)
            } catch {
                print("Could not initialize the world: \(error.localizedDescription)")
                return
            }
        }

        let floor = makeCube(
            position: BlockPosition(x: 0, y: -0.5, z: 0),
            size: BlockPosition(x: worldWidth, y: 1, z: worldDepth),
            color: .white,
            texture: GameAssets.greenCubeTexture,
            textureScale: Size2(
                Float(worldWidth / (world?.blockSize ?? 1)),
                Float(worldDepth / (world?.blockSize ?? 1))
            )
        )
        floor.insert(Collision3DComponent.self) { component in
            component.collider = AxisAlignedBoundingBox3D(
                radius: Size3(Float(self.worldWidth / 2), 0.5, Float(self.worldDepth / 2))
            )
        }
        ground = floor
        game.insertEntity(floor)

        guard let world else { return }
        for block in world.blocks.values {
            insertBlock(block, into: game)
        }
        print("WASD: move | Click: capture pointer | Escape: release | Mouse: look | Left-click: place | Right-click: remove | Space/Shift: fly | F6: load | F7: save")
    }

    override func update(game: Game, input: HID, withTimePassed deltaTime: Float) async {
        guard let world, let camera = game.cameraEntity,
              let cameraTransform = camera.component(ofType: Transform3Component.self) else {
            return
        }

        let escapePressed = input.keyboard.button(.escape).isPressed
        if escapePressed && !previousEscapeKeyState {
            setPointerLocked(false, input: input)
        }
        previousEscapeKeyState = escapePressed
        let mouseDelta = mouseLookDelta(input: input)
        yaw += Degrees(mouseDelta.x * 0.15)
        pitch += Degrees(mouseDelta.y * 0.15)
        if pitch < -80 {
            pitch = -80
        } else if pitch > 80 {
            pitch = 80
        }
        yaw.normalize()
        cameraTransform.rotation = Quaternion(-yaw, axis: .up) * Quaternion(-pitch, axis: .right)

        let movement = deltaTime * 7
        if input.keyboard.button("w").isPressed || input.keyboard.button(.up).isPressed {
            cameraTransform.position += Size3(cameraTransform.rotation.forward) * movement
        }
        if input.keyboard.button("s").isPressed || input.keyboard.button(.down).isPressed {
            cameraTransform.position += Size3(cameraTransform.rotation.backward) * movement
        }
        if input.keyboard.button("a").isPressed || input.keyboard.button(.left).isPressed {
            cameraTransform.position += Size3(cameraTransform.rotation.left) * movement
        }
        if input.keyboard.button("d").isPressed || input.keyboard.button(.right).isPressed {
            cameraTransform.position += Size3(cameraTransform.rotation.right) * movement
        }
        if input.keyboard.button(.space).isPressed {
            cameraTransform.position += Size3(0, movement, 0)
        }
        if input.keyboard.button(.shift(.anyVariation)).isPressed {
            cameraTransform.position += Size3(0, -movement, 0)
        }

        let leftPressed = input.mouse.button(.button1).isPressed
        let rightPressed = input.mouse.button(.button2).isPressed
        let savePressed = input.keyboard.button(.function(7)).isPressed
        let loadPressed = input.keyboard.button(.function(6)).isPressed
        let leftJustPressed = leftPressed && !previousLeftButtonState
        let rightJustPressed = rightPressed && !previousRightButtonState

        if !isPointerLocked && (leftJustPressed || rightJustPressed) {
            setPointerLocked(true, input: input)
        } else if leftJustPressed {
            interact(game: game, input: input, placing: true)
        } else if rightJustPressed {
            interact(game: game, input: input, placing: false)
        }
        if savePressed && !previousSaveKeyState {
            do {
                print("Saved \(world.blocks.count) blocks to \(try world.saveMap().path)")
            } catch {
                print("Could not save \(mapURL.path): \(error.localizedDescription)")
            }
        }
        if loadPressed && !previousLoadKeyState {
            reloadWorld(game: game)
        }

        previousLeftButtonState = leftPressed
        previousRightButtonState = rightPressed
        previousSaveKeyState = savePressed
        previousLoadKeyState = loadPressed
    }

    override class var phase: System.Phase { .simulation }

    private func setPointerLocked(_ locked: Bool, input: HID) {
        guard input.mouse.window != nil else { return }
        input.mouse.mode = locked ? .locked : .standard
        isPointerLocked = locked
    }

    private func mouseLookDelta(input: HID) -> Position2 {
        return input.mouse.deltaPosition
    }

    private func interact(game: Game, input: HID, placing: Bool) {
        guard let window = game.windowManager.mainWindow,
              let camera = Camera(game.cameraEntity),
              let mousePosition = input.mouse.position else {
            return
        }
        let ray = Canvas(window: window, camera: camera).convertTo3DSpace(mousePosition)
        guard let hit = game.collision3DSystem.closestHit(from: ray),
              let hitEntity = hit.entity else {
            return
        }
        if placing {
            guard var currentWorld = world,
                  let block = currentWorld.placeBlock(
                    beside: BlockPosition(
                        x: Double(hit.position.x),
                        y: Double(hit.position.y),
                        z: Double(hit.position.z)
                    ),
                    surfaceNormal: BlockPosition(
                        x: Double(hit.surfaceDirection.x),
                        y: Double(hit.surfaceDirection.y),
                        z: Double(hit.surfaceDirection.z)
                    )
                  ) else {
                return
            }
            world = currentWorld
            insertBlock(block, into: game)
        } else if let position = blockEntities.first(where: { $0.value === hitEntity })?.key {
            game.removeEntity(hitEntity)
            blockEntities.removeValue(forKey: position)
            if var currentWorld = world {
                _ = currentWorld.removeBlock(at: position)
                world = currentWorld
            }
        }
    }

    private func insertBlock(_ block: Block, into game: Game) {
        let size = world?.blockSize ?? 1
        let entity: Entity
        if block.texture == "box" {
            entity = makeCube(
                position: block.position,
                size: BlockPosition(x: size, y: size, z: size),
                color: .white,
                texture: GameAssets.boxTexture
            )
        } else {
            entity = makeCube(
                position: block.position,
                size: BlockPosition(x: size, y: size, z: size),
                color: .white,
                texture: GameAssets.grayCubeTexture,
                textureScale: .one
            )
        }
        let halfSize = Float(size / 2)
        entity.insert(Collision3DComponent.self) { component in
            component.collider = AxisAlignedBoundingBox3D(radius: Size3(halfSize))
        }
        blockEntities[block.position] = entity
        game.insertEntity(entity)
    }

    private func reloadWorld(game: Game) {
        guard var loadedWorld = world else { return }
        do {
            try loadedWorld.loadMap()
            for entity in blockEntities.values {
                game.removeEntity(entity)
            }
            blockEntities.removeAll()
            world = loadedWorld
            for block in loadedWorld.blocks.values {
                insertBlock(block, into: game)
            }
            print("Loaded \(loadedWorld.blocks.count) blocks from \(mapURL.path)")
        } catch {
            print("Could not load \(mapURL.path): \(error.localizedDescription)")
        }
    }

    private func makeCube(
        position: BlockPosition,
        size: BlockPosition,
        color: Color,
        texture: Texture? = GameAssets.whiteCubeTexture,
        textureScale: Size2 = .one
    ) -> Entity {
        let entity = Entity()
        entity.insert(Transform3Component.self) { component in
            component.position = Position3(Float(position.x), Float(position.y), Float(position.z))
            component.scale = Size3(Float(size.x), Float(size.y), Float(size.z))
        }
        entity.insert(RenderingGeometryComponent.self) { component in
            component.insert(Geometry(as: .unitCube))
        }
        entity.insert(MaterialComponent.self) { component in
            component.fragmentShader = .textureSample
            component.channel(0) { channel in
                channel.color = color
                channel.texture = texture
                channel.scale = textureScale
                // These 64x64 block textures are pixel art; avoid linear
                // filtering blurring the tile edges when scaled in the world.
                channel.sampleFilter = .nearest
            }
        }
        return entity
    }
}
