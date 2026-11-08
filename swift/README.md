# GateEngine world builder and player

The Swift app uses [GateEngine](https://github.com/STREGAsGate/GateEngine) to build the existing version-1 `world.json` map format or play a hosted world using the Python host's multiplayer protocol.

Run it from this directory:

```sh
swift run swift
```

Build the Swift game executable:

```sh
swift build -c release --product swift
```

The executable is `.build/release/swift`. This is a release build, not a fully static executable: GateEngine still depends on system graphics/audio libraries and the game loads files from `Assets/`.

On Debian/Ubuntu, install GateEngine's OpenAL development headers first:

```sh
sudo apt update
sudo apt install libopenal-dev
```

GateEngine 0.2.1 needs a small compatibility patch with Swift 6.4. Apply it after resolving dependencies (and again if SwiftPM recreates its checkout):

```sh
./scripts/prepare-gateengine.sh
```

You can also run the modes directly:

```sh
swift run swift --builder
swift run swift --player 127.0.0.1
```

The Python launcher in the project root provides **Matchmaking**, **Build a world**, **Join world**, and **Host my world**. Enable **Use Swift version** to use the Swift builder/player for those game actions; matchmaking and hosting use the same Python host server. Build a single distributable Python launcher (with the Swift game bundled) from the project root using `python3 build_bin.py`. This requires Swift, Nuitka, and—on Linux—`patchelf`. In either builder, use WASD to move, the mouse to look, left-click to place blocks, and right-click to remove them. The Swift builder also uses Space/Shift to fly, F6 to reload the map, and F7 to save it. Click either mouse button once to capture and lock the pointer; that initial click only captures it. Press Escape to release the pointer, click again to recapture, and press F11 to toggle fullscreen. The GateEngine preparation script patches its Linux/X11 backend for pointer-locked mouse deltas and F11 fullscreen toggling. Run `./scripts/prepare-gateengine.sh` after resolving or recreating the dependency checkout, then rebuild. The player mode joins the host on port 27016, loads the host's map, synchronizes player positions and attacks, and supports WASD movement, Space to jump, left-click to attack, and right-click to switch attacks. Its player gravity and jump height are tuned to match the Python Ursina controller; unlike the builder, the player mode is not free-flying. F11 toggles fullscreen there as well.

The app loads assets from the `Assets/` folder beside `Package.swift`: `white_cube.png` textures the green-tinted test floor and blocks (repeated four times per block face), `sky_defaulr.png` is mapped onto a sky dome, the Marsey OBJ and base-color texture are used for remote players, and the emoji PNGs are used for multiplayer attack projectiles.
