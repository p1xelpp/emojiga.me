import Foundation
import Testing
@testable import WorldData

@Test func placeBlocksOnGridAndRejectOccupiedCells() throws {
    var engine = try WorldEngine(blockSize: 2)

    let first = engine.placeBlock(at: BlockPosition(x: -0.1, y: 1.9, z: 2.1))
    let duplicate = engine.placeBlock(at: BlockPosition(x: -0.2, y: 1.1, z: 2.9))

    #expect(first?.position == BlockPosition(x: -1, y: 1, z: 3))
    #expect(duplicate == nil)
    #expect(engine.blocks.count == 1)
}

@Test func adjacentPlacementUsesHitNormal() throws {
    let engine = try WorldEngine()

    let position = engine.adjacentBlockPosition(
        hitPoint: BlockPosition(x: 0.5, y: 0.5, z: 0.5),
        surfaceNormal: BlockPosition(x: 1, y: 0, z: 0)
    )

    #expect(position == BlockPosition(x: 1.5, y: 0.5, z: 0.5))
}

@Test func readsAndWritesPythonWorldJSON() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("world.json")
    let pythonWorld = """
    {
      "version": 1,
      "block_size": 2,
      "blocks": [
        { "position": [1.0, 3.0, -1.0] }
      ]
    }
    """
    try Data(pythonWorld.utf8).write(to: url)

    var engine = try WorldEngine(savePath: url)
    try engine.loadMap()
    #expect(engine.blockSize == 1)
    #expect(engine.block(at: BlockPosition(x: 1, y: 3, z: -1))?.texture == "white_cube")

    try engine.saveMap()
    let saved = try JSONDecoder().decode(WorldMap.self, from: Data(contentsOf: url))
    #expect(saved.version == 1)
    #expect(saved.blockSize == 2)
    #expect(saved.blocks.count == 1)
    #expect(saved.blocks[0].position == BlockPosition(x: 1, y: 3, z: -1))
}

@Test func invalidMapDoesNotReplaceCurrentWorld() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("invalid.json")
    try Data(#"{"version":1,"block_size":0,"blocks":[]}"#.utf8).write(to: url)

    var engine = try WorldEngine()
    _ = engine.placeBlock(at: BlockPosition(x: 0, y: 0, z: 0))
    let previousBlocks = engine.blocks

    #expect(throws: WorldEngineError.self) {
        try engine.loadMap(from: url)
    }
    #expect(engine.blocks == previousBlocks)
    #expect(engine.blockSize == 2)
}

@Test func rejectsInvalidBlockSizes() {
    #expect(throws: WorldEngineError.self) {
        _ = try WorldEngine(blockSize: 0)
    }
    #expect(throws: WorldEngineError.self) {
        _ = try WorldEngine(blockSize: .infinity)
    }
}
