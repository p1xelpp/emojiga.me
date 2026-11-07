import json
import math
import platform
from pathlib import Path

from panda3d.core import AntialiasAttrib
from ursina import (
    Entity,
    Sky,
    Text,
    Ursina,
    application,
    camera,
    color,
    destroy,
    held_keys,
    raycast,
    scene,
    time,
    window,
)
from ursina.prefabs.first_person_controller import FirstPersonController

from Controller import enable_zqsd_controls


class Block(Entity):
    def __init__(self, position=(0, 0, 0), scale=1, texture="white_cube", color=color.gray):
        super().__init__(
            model="cube",
            texture=texture,
            color=color,
            position=position,
            scale=scale,
            collider="box",
        )
        self.block_texture = texture


class BaseWorldEngine:
    BlockClass = Block
    allow_flight = True

    def __init__(
        self,
        world_width=50,
        world_depth=50,
        block_size=1,
        load_on_start=False,
        save_on_exit=False,
        save_path=None,
        network=None,
    ):
        self.app = Ursina()
        window.title = "Block World"
        window.fullscreen = False

        if platform.system() == "Darwin":
            application.base.render.setShaderOff()
            application.base.render.setAntialias(AntialiasAttrib.MNone)

        if block_size <= 0:
            raise ValueError("block_size must be greater than zero")

        self.world_width = world_width
        self.world_depth = world_depth
        self.block_size = block_size
        self.save_path = (
            Path(save_path)
            if save_path
            else Path(__file__).resolve().with_name("world.json")
        )
        self.load_on_start = load_on_start
        self.save_on_exit = save_on_exit
        self.network = network

        self.blocks = {}
        self.player = None
        self.status_text = None
        self.ground = None
        self.input_handler = Entity(parent=scene)
        self.input_handler.input = self.input

    def test_plane(self):
        if self.ground is not None:
            return

        self.ground = Entity(
            model="plane",
            scale=(self.world_width, 1, self.world_depth),
            texture="white_cube",
            color=color.green,
            texture_scale=(self.world_width, self.world_depth),
            collider="box",
        )
        self.player = FirstPersonController(position=(0, 2, 0), speed=7)
        enable_zqsd_controls()
        Sky(color=color.cyan)
        if self.allow_flight:
            self.fly_speed = 7
            self.fly_helper = Entity()
            self.fly_helper.update = self._update_flight
            self.player.gravity = 0
            self.player.jump = lambda: None
            controls = "Space: fly up  |  Left Shift: fly down"
        else:
            controls = "Space: jump"
        self.status_text = Text(
            text=(
                f"WASD: move  |  {controls}  |  Click: place  |  "
                "Right-click: remove  |  F7: save"
            ),
            origin=(-0.5, 0.5),
            position=(-0.85, 0.46),
            scale=0.8,
            background=True,
        )

        if self.load_on_start:
            self.load_map()

    def _update_flight(self):
        vertical_input = held_keys["space"] - held_keys["left shift"]
        if vertical_input:
            self.player.y += vertical_input * self.fly_speed * time.dt

    def _grid_position(self, point):
        size = self.block_size
        return tuple(
            math.floor(component / size) * size + size / 2
            for component in (point.x, point.y, point.z)
        )

    def _target_block_position(self, hit):
        point = hit.world_point + hit.world_normal * (self.block_size / 2 + 0.01)
        return self._grid_position(point)

    def place_block(self):
        if self.player is None:
            return

        hit = raycast(
            camera.world_position,
            camera.forward,
            distance=6,
            ignore=[self.player],
        )
        if not hit.hit:
            return

        position = self._target_block_position(hit)
        if position in self.blocks:
            return

        block = self.BlockClass(position=position, scale=self.block_size)
        self.blocks[position] = block

    def remove_block(self):
        if self.player is None:
            return

        hit = raycast(
            camera.world_position,
            camera.forward,
            distance=6,
            ignore=[self.player],
        )
        if hit.hit and isinstance(hit.entity, self.BlockClass):
            position = tuple(hit.entity.position)
            self.blocks.pop(position, None)
            destroy(hit.entity)

    def save_map(self):
        data = {
            "version": 1,
            "block_size": self.block_size,
            "blocks": [
                {"position": list(position), "texture": block.block_texture}
                for position, block in self.blocks.items()
            ],
        }
        self.save_path.parent.mkdir(parents=True, exist_ok=True)
        self.save_path.write_text(json.dumps(data, indent=2), encoding="utf-8")
        if self.status_text:
            self.status_text.text = f"Map saved: {self.save_path}"
        print(f"Map saved to {self.save_path}")
        return self.save_path

    def load_map(self):
        if not self.save_path.is_file():
            message = f"Map file not found: {self.save_path}"
            if self.status_text:
                self.status_text.text = message
            print(message)
            return False

        data = json.loads(self.save_path.read_text(encoding="utf-8"))
        return self.load_map_data(data)

    def load_map_data(self, data):
        if (
            not isinstance(data, dict)
            or data.get("version") != 1
            or not isinstance(data.get("blocks"), list)
            or not isinstance(data.get("block_size"), (int, float))
            or data["block_size"] <= 0
        ):
            raise ValueError(f"Unsupported or invalid map file: {self.save_path}")

        entries = data["blocks"]
        for entry in entries:
            position = entry.get("position") if isinstance(entry, dict) else None
            texture = entry.get("texture", "white_cube") if isinstance(entry, dict) else None
            if (
                not isinstance(position, list)
                or len(position) != 3
                or not all(isinstance(value, (int, float)) for value in position)
                or not isinstance(texture, str)
            ):
                raise ValueError(f"Invalid block entry in map file: {entry!r}")

        for block in self.blocks.values():
            destroy(block)
        self.blocks.clear()
        self.block_size = data["block_size"]
        for entry in entries:
            position = entry["position"]
            texture = entry.get("texture", "white_cube")
            key = tuple(position)
            if key not in self.blocks:
                self.blocks[key] = self.BlockClass(
                    position=key,
                    scale=self.block_size,
                    texture=texture,
                )
        if self.status_text:
            self.status_text.text = f"Map loaded: {self.save_path}"
        print(f"Map loaded from {self.save_path}")
        return True

    def input(self, key):
        if key == "left mouse down":
            self.place_block()
        elif key == "right mouse down":
            self.remove_block()
        elif key == "f7":
            self.save_map()
        elif key == "f6":
            self.load_map()

    def start(self):
        self.app.run()


C00lWorld = BaseWorldEngine


if __name__ == "__main__":
    world = BaseWorldEngine()
    world.test_plane()
    world.start()
