import Foundation

public struct BlockPosition: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    public static func + (lhs: Self, rhs: Self) -> Self {
        Self(x: lhs.x + rhs.x, y: lhs.y + rhs.y, z: lhs.z + rhs.z)
    }

    public static func - (lhs: Self, rhs: Self) -> Self {
        Self(x: lhs.x - rhs.x, y: lhs.y - rhs.y, z: lhs.z - rhs.z)
    }

    public static func * (lhs: Self, rhs: Double) -> Self {
        Self(x: lhs.x * rhs, y: lhs.y * rhs, z: lhs.z * rhs)
    }

    fileprivate var components: [Double] { [x, y, z] }

    fileprivate var isFinite: Bool {
        components.allSatisfy(\.isFinite)
    }
}

public struct Block: Codable, Equatable, Sendable {
    public let position: BlockPosition
    public let texture: String

    public init(position: BlockPosition, texture: String = "white_cube") {
        self.position = position
        self.texture = texture
    }

    private enum CodingKeys: String, CodingKey {
        case position
        case texture
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let components = try container.decode([Double].self, forKey: .position)
        guard components.count == 3 else {
            throw DecodingError.dataCorruptedError(
                forKey: .position,
                in: container,
                debugDescription: "A block position must contain exactly three numbers."
            )
        }
        position = BlockPosition(x: components[0], y: components[1], z: components[2])
        texture = try container.decodeIfPresent(String.self, forKey: .texture) ?? "white_cube"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(position.components, forKey: .position)
        try container.encode(texture, forKey: .texture)
    }
}

public struct WorldMap: Codable, Equatable, Sendable {
    public let version: Int
    public let blockSize: Double
    public let blocks: [Block]

    public init(version: Int = 1, blockSize: Double, blocks: [Block]) {
        self.version = version
        self.blockSize = blockSize
        self.blocks = blocks
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case blockSize = "block_size"
        case blocks
    }

    fileprivate func validate() throws {
        guard version == 1, blockSize.isFinite, blockSize > 0 else {
            throw WorldEngineError.invalidMap("Unsupported version or invalid block_size.")
        }
        guard blocks.allSatisfy({ $0.position.isFinite }) else {
            throw WorldEngineError.invalidMap("Block positions must contain finite numbers.")
        }
    }
}

public enum WorldEngineError: LocalizedError, Equatable {
    case invalidBlockSize
    case invalidMap(String)

    public var errorDescription: String? {
        switch self {
        case .invalidBlockSize:
            "blockSize must be greater than zero and finite."
        case .invalidMap(let reason):
            "Unsupported or invalid map file: \(reason)"
        }
    }
}

public struct WorldEngine: Sendable {
    public let worldWidth: Double
    public let worldDepth: Double
    public private(set) var blockSize: Double
    public let savePath: URL
    public private(set) var blocks: [BlockPosition: Block] = [:]

    public init(
        worldWidth: Double = 50,
        worldDepth: Double = 50,
        blockSize: Double = 1,
        savePath: URL = URL(fileURLWithPath: "world.json", relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
    ) throws {
        guard blockSize.isFinite, blockSize > 0 else {
            throw WorldEngineError.invalidBlockSize
        }
        self.worldWidth = worldWidth
        self.worldDepth = worldDepth
        self.blockSize = blockSize
        self.savePath = savePath
    }

    public func gridPosition(for point: BlockPosition) -> BlockPosition {
        func center(_ value: Double) -> Double {
            floor(value / blockSize) * blockSize + blockSize / 2
        }
        return BlockPosition(x: center(point.x), y: center(point.y), z: center(point.z))
    }

    public func adjacentBlockPosition(hitPoint: BlockPosition, surfaceNormal: BlockPosition) -> BlockPosition {
        let offset = surfaceNormal * (blockSize / 2 + 0.01)
        return gridPosition(for: hitPoint + offset)
    }

    @discardableResult
    public mutating func placeBlock(at point: BlockPosition, texture: String = "white_cube") -> Block? {
        let position = gridPosition(for: point)
        guard blocks[position] == nil else { return nil }
        let block = Block(position: position, texture: texture)
        blocks[position] = block
        return block
    }

    @discardableResult
    public mutating func placeBlock(
        beside hitPoint: BlockPosition,
        surfaceNormal: BlockPosition,
        texture: String = "white_cube"
    ) -> Block? {
        let position = adjacentBlockPosition(hitPoint: hitPoint, surfaceNormal: surfaceNormal)
        guard blocks[position] == nil else { return nil }
        let block = Block(position: position, texture: texture)
        blocks[position] = block
        return block
    }

    @discardableResult
    public mutating func removeBlock(at position: BlockPosition) -> Block? {
        blocks.removeValue(forKey: position)
    }

    public func block(at position: BlockPosition) -> Block? {
        blocks[position]
    }

    public func map() -> WorldMap {
        let sortedBlocks = blocks.values.sorted {
            if $0.position.x != $1.position.x { return $0.position.x < $1.position.x }
            if $0.position.y != $1.position.y { return $0.position.y < $1.position.y }
            return $0.position.z < $1.position.z
        }
        return WorldMap(blockSize: blockSize, blocks: sortedBlocks)
    }

    @discardableResult
    public func saveMap(to url: URL? = nil) throws -> URL {
        let destination = url ?? savePath
        let map = self.map()
        try map.validate()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(map)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: destination, options: .atomic)
        return destination
    }

    public mutating func loadMap(from url: URL? = nil) throws {
        let source = url ?? savePath
        let data = try Data(contentsOf: source)
        try loadMap(from: data)
    }

    public mutating func loadMap(from data: Data) throws {
        let decoded = try JSONDecoder().decode(WorldMap.self, from: data)
        try decoded.validate()

        var loadedBlocks: [BlockPosition: Block] = [:]
        for block in decoded.blocks where loadedBlocks[block.position] == nil {
            loadedBlocks[block.position] = block
        }
        blockSize = decoded.blockSize
        blocks = loadedBlocks
    }
}
