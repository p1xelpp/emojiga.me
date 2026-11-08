import Foundation
import GateEngine
import WorldData

private let playerAttackNames = ["ice", "fire", "moai", "sob", "knockback", "bomb", "comet"]
private let playerGravity: Float = 25
private let playerJumpSpeed: Float = 10
private let remotePlayerScale: Float = 0.75
private let remotePlayerFloorOffset: Float = 1.3111 * remotePlayerScale

private struct LootEntry {
    let attack: String
    let weight: Int
    let minQty: Int
    let maxQty: Int
}

private let lootTable: [LootEntry] = [
    LootEntry(attack: "ice", weight: 40, minQty: 3, maxQty: 6),
    LootEntry(attack: "fire", weight: 25, minQty: 2, maxQty: 4),
    LootEntry(attack: "moai", weight: 15, minQty: 2, maxQty: 3),
    LootEntry(attack: "sob", weight: 10, minQty: 1, maxQty: 2),
    LootEntry(attack: "knockback", weight: 6, minQty: 1, maxQty: 2),
    LootEntry(attack: "bomb", weight: 3, minQty: 1, maxQty: 1),
    LootEntry(attack: "comet", weight: 1, minQty: 1, maxQty: 1),
]

private let chestPositions: [BlockPosition] = [
    BlockPosition(x: 0.0, y: 0.0, z: 8.0),
    BlockPosition(x: 0.0, y: 0.0, z: -8.0),
    BlockPosition(x: 8.0, y: 0.0, z: 0.0),
    BlockPosition(x: -8.0, y: 0.0, z: 0.0),
    BlockPosition(x: 14.0, y: 0.0, z: 14.0),
    BlockPosition(x: -14.0, y: 0.0, z: 14.0),
    BlockPosition(x: 14.0, y: 0.0, z: -14.0),
    BlockPosition(x: -14.0, y: 0.0, z: -14.0),
    BlockPosition(x: 18.0, y: 0.0, z: 0.0),
    BlockPosition(x: -18.0, y: 0.0, z: 0.0),
    BlockPosition(x: 0.0, y: 0.0, z: 18.0),
    BlockPosition(x: 0.0, y: 0.0, z: -18.0),
]
private let chestRespawnDuration: Float = 20.0

@MainActor
enum PlayerHUDState {
    static var text = "Connecting..."
    static var selectedSlot: Int = 0
    static var ammo: [String: Int] = [
        "ice": 0, "fire": 0, "moai": 0, "sob": 0, "knockback": 0, "bomb": 0, "comet": 0
    ]
    static var interactPrompt: String = ""
    static var lootMessage: String = ""
    static var lootIcons: [String] = []
    static var lootMessageTimer: Float = 0
}

@MainActor
final class PlayerHUDRenderingSystem: RenderingSystem {
    private var hud = Text(string: "", pointSize: 18, color: .white)
    private var promptText = Text(string: "", pointSize: 18, color: Color(1.0, 0.9, 0.2, 1.0))
    private var lootText = Text(string: "", pointSize: 20, color: Color(1.0, 0.84, 0.0, 1.0))
    private var numTexts: [Text] = (1...7).map { Text(string: "\($0)", pointSize: 11, color: Color(0.75, 0.75, 0.75, 1.0)) }
    private var countTexts: [Text] = (0..<7).map { _ in Text(string: "0", pointSize: 13, color: .white) }
    private var textures: [String: Texture] = [:]

    override func render(game: Game, window: Window, withTimePassed deltaTime: Float) {
        if hud.string != PlayerHUDState.text {
            hud.string = PlayerHUDState.text
        }
        var canvas = Canvas(window: window)
        let topPosition = Position2(
            max(12, window.safeAreaInsets.leading),
            max(12, window.safeAreaInsets.top)
        )
        canvas.insert(
            Rect(size: hud.size).inset(by: Insets(-8)),
            color: Color(0, 0, 0, 0.65),
            at: topPosition
        )
        canvas.insert(hud, at: topPosition)

        if !PlayerHUDState.interactPrompt.isEmpty {
            if promptText.string != PlayerHUDState.interactPrompt {
                promptText.string = PlayerHUDState.interactPrompt
            }
            let promptPos = Position2(
                (window.size.width - promptText.size.width) / 2,
                window.size.height * 0.66
            )
            canvas.insert(
                Rect(size: promptText.size).inset(by: Insets(-6)),
                color: Color(0, 0, 0, 0.7),
                at: promptPos
            )
            canvas.insert(promptText, at: promptPos)
        }

        if PlayerHUDState.lootMessageTimer > 0 && !PlayerHUDState.lootMessage.isEmpty {
            if lootText.string != PlayerHUDState.lootMessage {
                lootText.string = PlayerHUDState.lootMessage
            }
            let iconSize: Float = 24
            let iconGap: Float = 4
            let iconCount = PlayerHUDState.lootIcons.count
            let iconRowWidth = iconCount > 0
                ? Float(iconCount) * iconSize + Float(iconCount - 1) * iconGap
                : 0
            let contentWidth = max(lootText.size.width, iconRowWidth)
            let contentHeight = lootText.size.height + (iconCount > 0 ? iconSize + 4 : 0)
            let lootPos = Position2(
                (window.size.width - contentWidth) / 2,
                window.size.height * 0.58
            )
            canvas.insert(
                Rect(size: Size2(contentWidth, contentHeight)).inset(by: Insets(-8)),
                color: Color(0.1, 0.1, 0.1, 0.85),
                at: lootPos
            )
            canvas.insert(
                lootText,
                at: Position2(lootPos.x + (contentWidth - lootText.size.width) / 2, lootPos.y)
            )
            for (index, attack) in PlayerHUDState.lootIcons.enumerated() {
                if textures[attack] == nil {
                    textures[attack] = GameAssets.attackTexture(named: attack)
                }
                guard let texture = textures[attack] else { continue }
                let rowStartX = lootPos.x + (contentWidth - iconRowWidth) / 2
                canvas.insert(
                    texture,
                    at: Position2(
                        rowStartX + Float(index) * (iconSize + iconGap),
                        lootPos.y + lootText.size.height + 4
                    ),
                    scale: Size2(iconSize, iconSize)
                )
            }
        }

        let slotSize: Float = 50
        let slotGap: Float = 58
        let totalWidth = Float(playerAttackNames.count) * slotGap - (slotGap - slotSize)
        let startX = (window.size.width - totalWidth) / 2
        let hotbarY = window.size.height - max(70, window.safeAreaInsets.bottom + 62)

        for (i, attack) in playerAttackNames.enumerated() {
            let x = startX + Float(i) * slotGap
            let isSelected = (i == PlayerHUDState.selectedSlot)
            let count = PlayerHUDState.ammo[attack] ?? 0

            if isSelected {
                canvas.insert(
                    Rect(size: Size2(slotSize + 4, slotSize + 4)),
                    color: Color(1.0, 0.84, 0.0, 0.95),
                    at: Position2(x - 2, hotbarY - 2)
                )
            } else {
                canvas.insert(
                    Rect(size: Size2(slotSize, slotSize)),
                    color: Color(0.3, 0.3, 0.3, 0.6),
                    at: Position2(x, hotbarY)
                )
            }

            canvas.insert(
                Rect(size: Size2(slotSize - 4, slotSize - 4)),
                color: Color(0.1, 0.1, 0.1, 0.88),
                at: Position2(x + 2, hotbarY + 2)
            )

            if textures[attack] == nil {
                textures[attack] = GameAssets.attackTexture(named: attack)
            }
            if let tex = textures[attack] {
                canvas.insert(
                    tex,
                    at: Position2(x + 7, hotbarY + 7),
                    scale: Size2(36, 36),
                    opacity: count > 0 ? 1.0 : 0.4
                )
            }

            if i < numTexts.count {
                canvas.insert(numTexts[i], at: Position2(x + 4, hotbarY + 3))
            }

            if i < countTexts.count {
                let countStr = "\(count)"
                if countTexts[i].string != countStr {
                    countTexts[i].string = countStr
                }
                countTexts[i].color = count > 0 ? .white : Color(1.0, 0.3, 0.3, 1.0)
                canvas.insert(countTexts[i], at: Position2(x + 28, hotbarY + 32))
            }
        }

        window.insert(canvas)
    }

    required init() {}

    override class func sortOrder() -> RenderingSystemSortOrder? {
        .performance
    }
}

@MainActor
final class BaseWorldEnginePlayer: System {
    private struct RemotePlayer {
        let entity: Entity
        var position: [Double]
        var rotationY: Double
    }

    private struct Projectile {
        let entity: Entity
        let attack: String
        let ownerID: String
        var velocity: [Double]
        var age: Float
    }

    private let host: String
    private let worldWidth = 50.0
    private let worldDepth = 50.0
    private var client: WorldClient?
    private var world: WorldEngine?
    private var blockEntities: [BlockPosition: Entity] = [:]
    private var remotePlayers: [String: RemotePlayer] = [:]
    private var projectiles: [Projectile] = []
    private var floodEntity: Entity?
    private var floodRemaining = 0.0
    private var health = 100
    private var cometAvailable = true
    private var yaw: Degrees = .zero
    private var pitch: Degrees = .zero
    private var verticalVelocity: Float = 0
    private var knockbackVelocity = Position3.zero
    private var attackIndex = 0
    private var attackCooldown: Float = 0
    private var positionUpdateTimer: Float = 0
    private var waterDamageTimer: Float = 0
    private var burnRemaining: Float = 0
    private var burnDamageTimer: Float = 0
    private var freezeRemaining: Float = 0
    private var damageFlashRemaining: [String: Float] = [:]
    private var previousLeftButtonState = false
    private var previousRightButtonState = false
    private var previousJumpButtonState = false
    private var previousEscapeKeyState = false
    private var previousFullScreenKeyState = false
    private var isPointerLocked = false
    private var deathReported = false
    private var status = "Connecting..."

    private struct ChestState {
        let id: Int
        let entity: Entity
        let position: BlockPosition
        var isOpened: Bool
        var respawnTimer: Float
    }

    private var chests: [ChestState] = []
    private var ammo: [String: Int] = [
        "ice": 0, "fire": 0, "moai": 0, "sob": 0, "knockback": 0, "bomb": 0, "comet": 0
    ]
    private var previousNumberKeys: [Bool] = Array(repeating: false, count: 7)
    private var scrollReceipt = InputReceipts()
    private var previousEKeyState = false
    private var lootMessageTimer: Float = 0

    init(host: String) {
        self.host = host
        super.init()
    }

    required init() {
        host = "127.0.0.1"
        super.init()
    }

    override func setup(game: Game, input: HID) async {
        do {
            let client = try WorldClient(host: host)
            var loadedWorld = try WorldEngine(savePath: URL(fileURLWithPath: "world.json"))
            try loadedWorld.loadMap(from: client.worldData)
            self.client = client
            self.world = loadedWorld
            self.health = client.cometStruck ? 0 : 100
            self.cometAvailable = client.cometAvailable
            self.floodRemaining = client.floodRemaining
            print("Joined \(host) as \(client.playerID.prefix(8)); loaded \(loadedWorld.blocks.count) blocks.")

            let camera: Entity
            if let existingCamera = game.cameraEntity {
                camera = existingCamera
            } else {
                camera = Entity(components: [Transform3Component.self, CameraComponent.self])
                game.insertEntity(camera)
            }
            camera[Transform3Component.self].position = Position3(0, 1.8, 0)
            let floor = makeCube(
                position: BlockPosition(x: 0, y: -0.5, z: 0),
                size: BlockPosition(x: worldWidth, y: 1, z: worldDepth),
                color: .white,
                texture: GameAssets.greenCubeTexture,
                textureScale: Size2(
                    Float(worldWidth / loadedWorld.blockSize),
                    Float(worldDepth / loadedWorld.blockSize)
                )
            )
            floor.insert(Collision3DComponent.self) { component in
                component.collider = AxisAlignedBoundingBox3D(
                    radius: Size3(Float(self.worldWidth / 2), 0.5, Float(self.worldDepth / 2))
                )
            }
            game.insertEntity(floor)

            for block in loadedWorld.blocks.values {
                insertBlock(block, into: game)
            }
            for player in client.initialPlayers {
                addRemotePlayer(player, game: game)
            }
            if floodRemaining > 0 {
                startFlood(remaining: floodRemaining, game: game)
            }
            let openedChestsSet = Set(client.openedChests)
            for (index, position) in chestPositions.enumerated() {
                let chestEntity = makeChest(position: position)
                let isOpened = openedChestsSet.contains(index)
                if !isOpened {
                    game.insertEntity(chestEntity)
                }
                chests.append(
                    ChestState(
                        id: index,
                        entity: chestEntity,
                        position: position,
                        isOpened: isOpened,
                        respawnTimer: isOpened ? chestRespawnDuration : 0
                    )
                )
            }
            status = "Joined \(host) as \(client.playerID.prefix(8))"
            showLootMessage("Open a loot chest to collect emojis! ([E])")
            updateHUD()
        } catch {
            status = "Could not join \(host): \(error.localizedDescription)"
            PlayerHUDState.text = status
            print(status)
        }
    }

    override func update(game: Game, input: HID, withTimePassed deltaTime: Float) async {
        guard let client, let camera = game.cameraEntity,
              let cameraTransform = camera.component(ofType: Transform3Component.self) else {
            return
        }
        let escapePressed = input.keyboard.button(.escape).isPressed
        if escapePressed && !previousEscapeKeyState {
            setPointerLocked(false, input: input)
        }
        previousEscapeKeyState = escapePressed
        let fullScreenPressed = input.keyboard.button(.function(11)).isPressed
        if fullScreenPressed && !previousFullScreenKeyState {
            game.windowManager.mainWindow?.toggleFullScreen()
        }
        previousFullScreenKeyState = fullScreenPressed

        processMessages(client.poll(), game: game)
        let mouseDelta = mouseLookDelta(input: input)
        yaw += Degrees(mouseDelta.x * 0.15)
        pitch += Degrees(mouseDelta.y * 0.15)
        if pitch < -80 { pitch = -80 }
        if pitch > 80 { pitch = 80 }
        yaw.normalize()
        cameraTransform.rotation = Quaternion(-yaw, axis: .up) * Quaternion(-pitch, axis: .right)

        let movementSpeed: Float = freezeRemaining > 0 || health <= 0 ? 0 : 7
        let movement = deltaTime * movementSpeed
        let horizontalRotation = Quaternion(-yaw, axis: .up)
        let forward = horizontalRotation.forward
        let right = horizontalRotation.right
        var horizontal = Size3.zero
        if input.keyboard.button("w").isPressed || input.keyboard.button(.up).isPressed {
            horizontal += Size3(forward.x, 0, forward.z)
        }
        if input.keyboard.button("s").isPressed || input.keyboard.button(.down).isPressed {
            horizontal -= Size3(forward.x, 0, forward.z)
        }
        if input.keyboard.button("a").isPressed || input.keyboard.button(.left).isPressed {
            horizontal -= Size3(right.x, 0, right.z)
        }
        if input.keyboard.button("d").isPressed || input.keyboard.button(.right).isPressed {
            horizontal += Size3(right.x, 0, right.z)
        }
        if horizontal.magnitude > 0 {
            let displacement = horizontal.normalized * movement
            let candidateX = cameraTransform.position.x + displacement.x
            if !collidesWithBlock(
                x: candidateX,
                y: cameraTransform.position.y,
                z: cameraTransform.position.z
            ) {
                cameraTransform.position.x = candidateX
            }
            let candidateZ = cameraTransform.position.z + displacement.z
            if !collidesWithBlock(
                x: cameraTransform.position.x,
                y: cameraTransform.position.y,
                z: candidateZ
            ) {
                cameraTransform.position.z = candidateZ
            }
        }

        let feetHeight = cameraTransform.position.y - 1.8
        let groundHeight = groundHeightBelowPlayer(
            x: cameraTransform.position.x,
            z: cameraTransform.position.z,
            feetHeight: feetHeight
        )
        let grounded = groundHeight.map { feetHeight <= $0 + 0.001 } ?? false
        let jumpPressed = input.keyboard.button(.space).isPressed
        if grounded, let groundHeight {
            cameraTransform.position.y = groundHeight + 1.8
            verticalVelocity = 0
            if jumpPressed && !previousJumpButtonState && freezeRemaining <= 0 && health > 0 {
                verticalVelocity = playerJumpSpeed
            }
        }
        previousJumpButtonState = jumpPressed
        if !grounded || verticalVelocity > 0 {
            verticalVelocity -= playerGravity * deltaTime
            cameraTransform.position.y += verticalVelocity * deltaTime
            let nextFeetHeight = cameraTransform.position.y - 1.8
            if verticalVelocity <= 0, let groundHeight,
               nextFeetHeight <= groundHeight {
                cameraTransform.position.y = groundHeight + 1.8
                verticalVelocity = 0
            }
        }

        if freezeRemaining > 0 {
            knockbackVelocity = .zero
        } else if knockbackVelocity != .zero {
            cameraTransform.position += Size3(
                knockbackVelocity.x * deltaTime,
                knockbackVelocity.y * deltaTime,
                knockbackVelocity.z * deltaTime
            )
            knockbackVelocity.x *= max(0, 1 - 2.5 * deltaTime)
            knockbackVelocity.z *= max(0, 1 - 2.5 * deltaTime)
            knockbackVelocity.y -= 9.8 * deltaTime
            if knockbackVelocity.magnitude < 0.2 {
                knockbackVelocity = .zero
            }
        }

        let numChars: [Character] = ["1", "2", "3", "4", "5", "6", "7"]
        for (i, char) in numChars.enumerated() {
            let isPressed = input.keyboard.button(.character(char, .anyVariation)).isPressed
            if isPressed && !previousNumberKeys[i] {
                attackIndex = i
            }
            previousNumberKeys[i] = isPressed
        }

        if input.mouse.scroller(.y).didScroll(ifDifferent: &scrollReceipt) {
            let delta = input.mouse.scroller(.y).delta
            if delta > 0 {
                attackIndex = (attackIndex - 1 + playerAttackNames.count) % playerAttackNames.count
            } else if delta < 0 {
                attackIndex = (attackIndex + 1) % playerAttackNames.count
            }
        }

        let ePressed = input.keyboard.button("e").isPressed || input.keyboard.button("E").isPressed
        let eJustPressed = ePressed && !previousEKeyState
        previousEKeyState = ePressed

        let playerFootPosition = BlockPosition(
            x: Double(cameraTransform.position.x),
            y: Double(cameraTransform.position.y - 1.8),
            z: Double(cameraTransform.position.z)
        )
        var nearestChestIndex: Int? = nil
        var nearestDistSq: Double = .infinity
        for (index, chest) in chests.enumerated() {
            if chest.isOpened { continue }
            let distSq = distanceSquared(playerFootPosition, chest.position)
            if distSq < nearestDistSq {
                nearestDistSq = distSq
                nearestChestIndex = index
            }
        }

        var interactPrompt = ""
        if let nearestIndex = nearestChestIndex {
            if nearestDistSq < 2.56 {
                openChest(at: nearestIndex, game: game)
            } else if nearestDistSq < 10.24 {
                interactPrompt = "Press [E] to open the loot chest"
                if eJustPressed {
                    openChest(at: nearestIndex, game: game)
                }
            }
        }
        PlayerHUDState.interactPrompt = interactPrompt

        let leftPressed = input.mouse.button(.button1).isPressed
        let rightPressed = input.mouse.button(.button2).isPressed
        let leftJustPressed = leftPressed && !previousLeftButtonState
        let rightJustPressed = rightPressed && !previousRightButtonState
        if !isPointerLocked && (leftJustPressed || rightJustPressed) {
            setPointerLocked(true, input: input)
        } else if health > 0 && leftJustPressed {
            if let nearestIndex = nearestChestIndex, nearestDistSq < 12.25 {
                openChest(at: nearestIndex, game: game)
            } else {
                throwAttack(client: client, cameraTransform: cameraTransform, game: game)
            }
        } else if rightJustPressed {
            attackIndex = (attackIndex + 1) % playerAttackNames.count
        }
        previousLeftButtonState = leftPressed
        previousRightButtonState = rightPressed

        attackCooldown = max(0, attackCooldown - deltaTime)
        positionUpdateTimer += deltaTime
        if positionUpdateTimer >= 0.1 && client.connected {
            positionUpdateTimer = 0
            client.sendPosition(
                [
                    Double(cameraTransform.position.x),
                    Double(cameraTransform.position.y - 1.8),
                    Double(cameraTransform.position.z),
                ],
                rotationY: Double(yaw.rawValue)
            )
        }

        updateProjectiles(deltaTime: deltaTime, game: game, cameraTransform: cameraTransform)
        updateEffects(deltaTime: deltaTime, game: game, cameraTransform: cameraTransform)
        updateHUD()
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

    override func teardown(game: Game) {
        client?.close()
    }

    private func processMessages(_ messages: [[String: Any]], game: Game) {
        for message in messages {
            switch message["type"] as? String {
            case "player_join", "player_update":
                updateRemotePlayer(message, game: game)
            case "initial_players":
                for player in message["players"] as? [[String: Any]] ?? [] {
                    addRemotePlayer(player, game: game)
                }
            case "player_leave":
                removeRemotePlayer(message["id"] as? String, game: game)
            case "attack":
                spawnProjectile(message)
            case "flood_start":
                startFlood(remaining: number(message["remaining"]) ?? 3, game: game)
            case "player_hit":
                receiveHit(message)
            case "chest_opened":
                if let chestID = (message["chest_id"] as? NSNumber)?.intValue ?? (message["chest_id"] as? Int) {
                    remoteOpenChest(id: chestID, game: game)
                }
            case "comet_strike":
                cometAvailable = false
                health = 0
                status = "The comet struck. You are knocked out."
            case "comet_unavailable":
                cometAvailable = false
                status = "The comet has already been used this match."
            case "disconnected":
                status = "Disconnected from host: \(message["message"] as? String ?? "connection lost")"
            default:
                break
            }
        }
    }

    private func throwAttack(client: WorldClient, cameraTransform: Transform3Component, game: Game) {
        guard attackCooldown <= 0 else { return }
        let attack = playerAttackNames[attackIndex]
        let count = ammo[attack] ?? 0
        guard count > 0 else {
            showLootMessage("No \(attack) left! Find a loot chest.", icons: [attack])
            return
        }
        guard attack != "comet" || cometAvailable else {
            showLootMessage("De komeet is al gebruikt dit spel!")
            return
        }
        ammo[attack] = count - 1
        updateHUD()

        let forward = cameraTransform.rotation.forward
        let direction = normalize([Double(forward.x), Double(forward.y), Double(forward.z)])
        let origin = [
            Double(cameraTransform.position.x) + direction[0] * 0.8,
            Double(cameraTransform.position.y) + direction[1] * 0.8,
            Double(cameraTransform.position.z) + direction[2] * 0.8,
        ]
        spawnProjectile([
            "id": client.playerID,
            "attack": attack,
            "origin": origin,
            "direction": direction,
        ])
        client.sendAttack(attack, origin: origin, direction: direction)
        attackCooldown = 0.45
    }

    private func spawnProjectile(_ message: [String: Any]) {
        guard let attack = message["attack"] as? String,
              playerAttackNames.contains(attack),
              let origin = vector(message["origin"]),
              let rawDirection = vector(message["direction"]) else {
            return
        }
        let direction = normalize(rawDirection)
        guard direction.contains(where: { $0 != 0 }) else { return }
        let launchSpeed = projectileSpeed(for: attack)
        let velocity = direction.map { $0 * launchSpeed }
        let visual = makeAttackSprite(
            attack,
            position: BlockPosition(x: origin[0], y: origin[1], z: origin[2])
        )
        game.insertEntity(visual)
        projectiles.append(
            Projectile(
                entity: visual,
                attack: attack,
                ownerID: message["id"] as? String ?? "",
                velocity: velocity,
                age: 0
            )
        )
    }

    private func updateProjectiles(
        deltaTime: Float,
        game: Game,
        cameraTransform: Transform3Component
    ) {
        for index in projectiles.indices.reversed() {
            var projectile = projectiles[index]
            guard let transform = projectile.entity.component(ofType: Transform3Component.self) else {
                projectiles.remove(at: index)
                continue
            }
            projectile.velocity[1] -= projectileGravity(for: projectile.attack) * Double(deltaTime)
            let previousPosition = BlockPosition(
                x: Double(transform.position.x),
                y: Double(transform.position.y),
                z: Double(transform.position.z)
            )
            let position = previousPosition + BlockPosition(
                x: projectile.velocity[0] * Double(deltaTime),
                y: projectile.velocity[1] * Double(deltaTime),
                z: projectile.velocity[2] * Double(deltaTime)
            )
            transform.position = Position3(Float(position.x), Float(position.y), Float(position.z))
            if let camera = game.cameraEntity?.component(ofType: Transform3Component.self) {
                transform.rotation = camera.rotation
            }
            projectile.age += deltaTime

            var targetID: String?
            for (playerID, remote) in remotePlayers where playerID != projectile.ownerID {
                let target = BlockPosition(
                    x: remote.position[0],
                    y: remote.position[1] + 0.9,
                    z: remote.position[2]
                )
                if distanceSquared(target, position) < 0.81 {
                    targetID = playerID
                    break
                }
            }

            let localTarget = BlockPosition(
                x: Double(cameraTransform.position.x),
                y: Double(cameraTransform.position.y - 0.9),
                z: Double(cameraTransform.position.z)
            )
            if targetID == nil && projectile.ownerID != (client?.playerID ?? ""),
               distanceSquared(localTarget, position) < 0.81 {
                targetID = client?.playerID
            }

            let hitWorld = position.y <= 0.1 || worldBlocksContain(position)
            if targetID != nil || hitWorld || projectile.age >= 4 {
                impactProjectile(projectile, targetID: targetID, at: position)
                game.removeEntity(projectile.entity)
                projectiles.remove(at: index)
            } else {
                projectiles[index] = projectile
            }
        }
    }

    private func projectileSpeed(for attack: String) -> Double {
        switch attack {
        case "sob": 16
        case "moai": 8
        case "knockback": 13
        case "fire", "ice": 15
        case "bomb": 12
        default: 18
        }
    }

    private func projectileGravity(for attack: String) -> Double {
        switch attack {
        case "moai": 32
        case "bomb", "comet": 24
        default: 18
        }
    }

    private func impactProjectile(_ projectile: Projectile, targetID: String?, at position: BlockPosition) {
        guard projectile.ownerID == client?.playerID, let client else { return }
        if projectile.attack == "comet" {
            client.sendCometStrike()
            return
        }
        if projectile.attack == "bomb" {
            for (playerID, remote) in remotePlayers {
                let target = BlockPosition(x: remote.position[0], y: remote.position[1] + 0.9, z: remote.position[2])
                if distanceSquared(target, position) <= 49 {
                    let direction = normalize([
                        target.x - position.x,
                        target.y - position.y,
                        target.z - position.z,
                    ])
                    client.sendHit(targetID: playerID, attack: projectile.attack, direction: direction)
                }
            }
        } else if let targetID, remotePlayers[targetID] != nil,
                  ["moai", "knockback", "fire", "ice"].contains(projectile.attack) {
            client.sendHit(
                targetID: targetID,
                attack: projectile.attack,
                direction: normalize(projectile.velocity)
            )
        }
    }

    private func receiveHit(_ message: [String: Any]) {
        guard let targetID = message["target_id"] as? String,
              let attack = message["attack"] as? String,
              let direction = vector(message["direction"]),
              playerAttackNames.contains(attack) else {
            return
        }
        if targetID == client?.playerID {
            if attack == "moai" { takeDamage(25) }
            if attack == "fire" {
                burnRemaining = 2
                burnDamageTimer = 0
            } else if attack == "ice" {
                freezeRemaining = 1
            } else if attack == "knockback" || attack == "bomb" {
                knockbackVelocity.x += Float(direction[0] * 30)
                knockbackVelocity.z += Float(direction[2] * 30)
                knockbackVelocity.y = max(knockbackVelocity.y, 10)
            }
        } else if remotePlayers[targetID] != nil, attack == "moai" || attack == "fire" || attack == "ice" {
            damageFlashRemaining[targetID] = 0.25
            remotePlayers[targetID]?.entity[MaterialComponent.self].channel(0) { $0.color = .red }
        }
    }

    private func updateEffects(deltaTime: Float, game: Game, cameraTransform: Transform3Component) {
        if floodEntity != nil {
            floodRemaining = max(0, floodRemaining - Double(deltaTime))
            if floodRemaining == 0, let floodEntity {
                game.removeEntity(floodEntity)
                self.floodEntity = nil
                waterDamageTimer = 0
            }
        }
        let feetHeight = cameraTransform.position.y - 1.8
        if floodEntity != nil && feetHeight <= 1 && health > 0 {
            waterDamageTimer += deltaTime
            while waterDamageTimer >= 1 && health > 0 {
                waterDamageTimer -= 1
                takeDamage(2)
            }
        } else {
            waterDamageTimer = 0
        }

        if burnRemaining > 0 && health > 0 {
            let elapsed = min(deltaTime, burnRemaining)
            burnRemaining -= elapsed
            burnDamageTimer += elapsed
            while burnDamageTimer >= 1 && health > 0 {
                burnDamageTimer -= 1
                takeDamage(5)
            }
        } else {
            burnRemaining = 0
            burnDamageTimer = 0
        }
        freezeRemaining = max(0, freezeRemaining - deltaTime)
        for playerID in Array(damageFlashRemaining.keys) {
            let remaining = (damageFlashRemaining[playerID] ?? 0) - deltaTime
            if remaining <= 0 {
                damageFlashRemaining.removeValue(forKey: playerID)
                remotePlayers[playerID]?.entity[MaterialComponent.self].channel(0) { $0.color = .white }
            } else {
                damageFlashRemaining[playerID] = remaining
            }
        }
        if feetHeight < -10 && health > 0 {
            health = 0
            status = "Health: 0% | Fell into the void"
        }
        if health <= 0 && !deathReported {
            deathReported = true
            status = "Health: 0% | You are knocked out"
            client?.sendDeath()
        }

        if lootMessageTimer > 0 {
            lootMessageTimer -= deltaTime
            PlayerHUDState.lootMessageTimer = lootMessageTimer
            if lootMessageTimer <= 0 {
                PlayerHUDState.lootMessage = ""
            }
        }
        for index in chests.indices {
            if chests[index].isOpened {
                chests[index].respawnTimer -= deltaTime
                if chests[index].respawnTimer <= 0 {
                    chests[index].isOpened = false
                    chests[index].respawnTimer = 0
                    game.insertEntity(chests[index].entity)
                }
            }
        }
    }

    private func takeDamage(_ amount: Int) {
        guard amount > 0, health > 0 else { return }
        health = max(0, health - amount)
        status = health == 0 ? "Health: 0% | You are knocked out" : "Health: \(health)%"
    }

    private func startFlood(remaining: Double, game: Game) {
        guard remaining.isFinite, remaining > 0 else { return }
        if floodEntity == nil {
            let flood = makeCube(
                position: BlockPosition(x: 0, y: 0.95, z: 0),
                size: BlockPosition(x: worldWidth + 10, y: 0.1, z: worldDepth + 10),
                color: Color(0.0, 0.35, 1.0, 0.9),
                texture: nil
            )
            floodEntity = flood
            game.insertEntity(flood)
        }
        floodRemaining = max(floodRemaining, remaining)
    }

    private func addRemotePlayer(_ data: [String: Any], game: Game) {
        guard let playerID = data["id"] as? String, playerID != client?.playerID,
              let position = vector(data["position"]) else {
            return
        }
        if remotePlayers[playerID] == nil {
            let entity = Entity()
            entity.insert(Transform3Component.self) { component in
                component.position = Position3(
                    Float(position[0]),
                    Float(position[1]) + remotePlayerFloorOffset,
                    Float(position[2])
                )
                component.scale = Size3(remotePlayerScale)
            }
            entity.insert(RenderingGeometryComponent.self) { component in
                component.insert(GameAssets.marseyGeometry)
            }
            entity.insert(MaterialComponent.self) { component in
                component.fragmentShader = .textureSample
                component.channel(0) { channel in
                    channel.texture = GameAssets.marseyTexture
                }
            }
            game.insertEntity(entity)
            remotePlayers[playerID] = RemotePlayer(
                entity: entity,
                position: position,
                rotationY: number(data["rotation_y"]) ?? 0
            )
        }
        updateRemotePlayer(data, game: game)
    }

    private func updateRemotePlayer(_ data: [String: Any], game: Game) {
        guard let playerID = data["id"] as? String,
              let position = vector(data["position"]) else {
            return
        }
        if remotePlayers[playerID] == nil {
            addRemotePlayer(data, game: game)
            return
        }
        guard var remote = remotePlayers[playerID] else { return }
        remote.position = position
        remote.rotationY = number(data["rotation_y"]) ?? remote.rotationY
        remote.entity[Transform3Component.self].position = Position3(
            Float(position[0]),
            Float(position[1]) + remotePlayerFloorOffset,
            Float(position[2])
        )
        remote.entity[Transform3Component.self].rotation = Quaternion(
            Degrees(Float(remote.rotationY)),
            axis: .up
        )
        remotePlayers[playerID] = remote
    }

    private func removeRemotePlayer(_ playerID: String?, game: Game) {
        guard let playerID, let remote = remotePlayers.removeValue(forKey: playerID) else { return }
        game.removeEntity(remote.entity)
        damageFlashRemaining.removeValue(forKey: playerID)
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

    private func worldBlocksContain(_ point: BlockPosition) -> Bool {
        guard let world else { return false }
        let halfSize = world.blockSize / 2 + 0.25
        return world.blocks.keys.contains { block in
            abs(block.x - point.x) <= halfSize
                && abs(block.y - point.y) <= halfSize
                && abs(block.z - point.z) <= halfSize
        }
    }

    private func collidesWithBlock(x: Float, y: Float, z: Float) -> Bool {
        guard let world else { return false }
        let halfSize = world.blockSize / 2
        let playerHalfWidth = 0.3
        let playerBottom = Double(y) - 1.8
        let playerTop = playerBottom + 1.8
        return world.blocks.keys.contains { block in
            abs(block.x - Double(x)) < halfSize + playerHalfWidth
                && abs(block.z - Double(z)) < halfSize + playerHalfWidth
                && playerBottom < block.y + halfSize
                && playerTop > block.y - halfSize
        }
    }

    private func groundHeightBelowPlayer(x: Float, z: Float, feetHeight: Float) -> Float? {
        guard let world else { return nil }
        let withinTestPlane = abs(x) <= Float(worldWidth / 2)
            && abs(z) <= Float(worldDepth / 2)
        var groundHeight: Float? = withinTestPlane ? 0 : nil
        let halfSize = Float(world.blockSize / 2)
        let playerHalfWidth: Float = 0.3
        for block in world.blocks.keys {
            let top = Float(block.y) + halfSize
            guard top <= feetHeight + 0.001,
                  abs(Float(block.x) - x) < halfSize + playerHalfWidth,
                  abs(Float(block.z) - z) < halfSize + playerHalfWidth else {
                continue
            }
            groundHeight = max(groundHeight ?? -.infinity, top)
        }
        return groundHeight
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
            }
        }
        return entity
    }

    private func makeAttackSprite(_ attack: String, position: BlockPosition) -> Entity {
        let entity = Entity()
        entity.insert(Transform3Component.self) { component in
            component.position = Position3(Float(position.x), Float(position.y), Float(position.z))
            component.scale = Size3(0.8)
        }
        entity.insert(RenderingGeometryComponent.self) { component in
            component.insert(Geometry.rectOriginCentered)
            component.flags = []
        }
        entity.insert(MaterialComponent.self) { component in
            component.fragmentShader = .textureSample
            component.channel(0) { channel in
                channel.texture = GameAssets.attackTexture(named: attack)
            }
        }
        return entity
    }

    private func updateHUD() {
        let connection = client?.connected == true ? "Connected" : "Disconnected"
        PlayerHUDState.text = """
        Health: \(health)% | \(connection)
        WASD: move | Space: jump | 1-7 / Scroll: hotbar | L-Click: throw | E: chest
        \(status)
        """
        PlayerHUDState.selectedSlot = attackIndex
        PlayerHUDState.ammo = ammo
    }

    private func showLootMessage(_ message: String, icons: [String] = []) {
        lootMessageTimer = 3.0
        PlayerHUDState.lootMessage = message
        PlayerHUDState.lootIcons = icons
        PlayerHUDState.lootMessageTimer = 3.0
    }

    private func rollLoot() -> [(String, Int)] {
        let numDrops = Int.random(in: 2...3)
        let totalWeight = lootTable.reduce(0) { $0 + $1.weight }
        var results: [String: Int] = [:]
        for _ in 0..<numDrops {
            var pick = Int.random(in: 0..<totalWeight)
            for entry in lootTable {
                if pick < entry.weight {
                    let qty = Int.random(in: entry.minQty...entry.maxQty)
                    results[entry.attack] = (results[entry.attack] ?? 0) + qty
                    break
                }
                pick -= entry.weight
            }
        }
        return results.map { ($0.key, $0.value) }
    }

    private func openChest(at index: Int, game: Game) {
        guard index >= 0 && index < chests.count else { return }
        var chest = chests[index]
        guard !chest.isOpened else { return }
        chest.isOpened = true
        chest.respawnTimer = chestRespawnDuration
        game.removeEntity(chest.entity)
        chests[index] = chest

        let loot = rollLoot()
        var lootParts: [String] = []
        for (attack, qty) in loot {
            ammo[attack] = (ammo[attack] ?? 0) + qty
            lootParts.append("+\(qty) \(attack)")
        }
        let lootString = lootParts.joined(separator: "  ")
        showLootMessage("Loot: \(lootString)", icons: loot.map { $0.0 })

        client?.sendChestOpened(chestID: chest.id)
        updateHUD()
    }

    private func remoteOpenChest(id: Int, game: Game) {
        guard let index = chests.firstIndex(where: { $0.id == id }) else { return }
        var chest = chests[index]
        if !chest.isOpened {
            chest.isOpened = true
            chest.respawnTimer = chestRespawnDuration
            game.removeEntity(chest.entity)
            chests[index] = chest
        }
    }

    private func makeChest(position: BlockPosition) -> Entity {
        let entity = makeCube(
            position: BlockPosition(x: position.x, y: position.y + 0.5, z: position.z),
            size: BlockPosition(x: 1, y: 1, z: 1),
            color: .white,
            texture: GameAssets.boxTexture
        )
        entity.insert(Collision3DComponent.self) { component in
            component.collider = AxisAlignedBoundingBox3D(radius: Size3(0.5))
        }
        return entity
    }

    private func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    private func vector(_ value: Any?) -> [Double]? {
        guard let values = value as? [Any], values.count == 3 else { return nil }
        let components = values.compactMap(number)
        return components.count == 3 ? components : nil
    }

    private func normalize(_ vector: [Double]) -> [Double] {
        let magnitude = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        guard magnitude.isFinite, magnitude > 0 else { return [0, 0, 0] }
        return vector.map { $0 / magnitude }
    }

    private func distanceSquared(_ lhs: BlockPosition, _ rhs: BlockPosition) -> Double {
        let x = lhs.x - rhs.x
        let y = lhs.y - rhs.y
        let z = lhs.z - rhs.z
        return x * x + y * y + z * z
    }
}
