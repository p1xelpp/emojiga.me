from pathlib import Path

from ursina import (
    Entity,
    Text,
    Vec3,
    application,
    camera,
    color,
    destroy,
    load_model,
    load_texture,
    raycast,
    scene,
    time,
)

from BaseWorldEngineBuilder import BaseWorldEngine as BuildWorldEngineBuilder
from HostServer import DEFAULT_PORT, WorldClient


ASSET_DIR = Path(__file__).resolve().parent / "assets" / "marsey"
PLAYER_MODEL = load_model("model.obj", folder=ASSET_DIR, use_deepcopy=True)
PLAYER_TEXTURE = load_texture("Material_baseColor.png", folder=ASSET_DIR)
PLAYER_MODEL_SCALE = 0.75
PLAYER_MODEL_FLOOR_OFFSET = 1.3111 * PLAYER_MODEL_SCALE
EMOJI_DIR = Path(__file__).resolve().parent / "assets" / "emojis"
ATTACKS = ("sob", "moai", "knockback", "fire", "bomb", "ice", "comet")
ATTACK_EMOJI = {
    "sob": "\U0001F62D",
    "moai": "\U0001F5FF",
    "knockback": "\U0001FAEA",
    "fire": "\U0001F525",
    "bomb": "\U0001F4A3",
    "ice": "\U00002744",
    "comet": "\U00002604",
}
ATTACK_LABEL = {
    "sob": "tears",
    "moai": "moai",
    "knockback": "knockback",
    "fire": "fire",
    "bomb": "bomb",
    "ice": "ice",
    "comet": "comet",
}
ATTACK_TEXTURES = {
    attack: load_texture(f"{attack}.png", folder=EMOJI_DIR)
    for attack in ATTACKS
}
ATTACK_DAMAGE = {
    "sob": 0,
    "moai": 25,
    "knockback": 0,
    "fire": 0,
    "bomb": 0,
    "ice": 0,
    "comet": 0,
}
FIRE_DAMAGE_PERCENT = 5
ATTACK_SPEED = {
    "sob": 16,
    "moai": 13,
    "knockback": 13,
    "fire": 15,
    "bomb": 12,
    "ice": 15,
    "comet": 18,
}
ATTACK_KNOCKBACK = 30
ATTACK_ICON_SCALE = 1.5
FIRE_DURATION = 2
ICE_DURATION = 1
BOMB_RADIUS = 7
WATER_DAMAGE_PERCENT = 2
WATER_DAMAGE_INTERVAL = 1
DAMAGE_FLASH_DURATION = 0.25
VOID_DEATH_Y = -10


class BaseWorldEnginePlayer(BuildWorldEngineBuilder):
    """Play a world created by the builder without editing or saving it."""

    allow_flight = False

    def __init__(self, world_width=50, world_depth=50, host="127.0.0.1", network=None):
        self.network = network or WorldClient(host=host, port=DEFAULT_PORT)
        self.remote_players = {}
        self.projectiles = []
        self._position_update_timer = 0
        self._attack_cooldown = 0
        self._attack_index = 0
        self.flood = None
        self._flood_remaining = 0
        self.health = 0 if self.network.comet_struck else 100
        self._water_damage_timer = 0
        self._death_reported = False
        self._remote_damage_flashes = {}
        self.knockback_velocity = Vec3(0, 0, 0)
        self._burn_remaining = 0
        self._burn_damage_timer = 0
        self._freeze_remaining = 0
        self._normal_player_speed = None
        self._normal_player_jump_height = None
        self.comet_available = self.network.comet_available
        self._block_mesh_groups = []
        super().__init__(
            world_width=world_width,
            world_depth=world_depth,
            load_on_start=False,
            save_on_exit=False,
            save_path=Path(__file__).resolve().with_name("world.json"),
            network=self.network,
        )

    def load_map_data(self, data):
        loaded = super().load_map_data(data)
        if not loaded:
            return loaded

        groups = {}
        for block in self.blocks.values():
            texture = block.block_texture
            group = groups.get(texture)
            if group is None:
                group = Entity(parent=scene, texture=texture)
                groups[texture] = group
            block.parent = group

        for group in groups.values():
            group.combine()
            group.collider = "mesh"
        self.blocks.clear()
        self._block_mesh_groups = list(groups.values())
        return loaded

    def test_plane(self):
        super().test_plane()
        self.load_map_data(self.network.world)
        self.multiplayer_helper = Entity()
        self.multiplayer_helper.update = self._update_multiplayer
        if self.network.flood_remaining > 0:
            self._start_flood(self.network.flood_remaining)
        self.health_text = Text(
            parent=camera.ui,
            text=f"Health: {self.health}%",
            position=(0.68, 0.46),
            scale=1.2,
            background=True,
        )
        if self.status_text:
            self.status_text.text = (
                f"Connected to host as {self.network.player_id[:8]}  |  "
                "WASD/ZQSD: walk  |  Space: jump  |  "
                f"L-click: throw {ATTACK_LABEL[ATTACKS[self._attack_index]]}  |  "
                "R-click: switch attack"
            )

    def input(self, key):
        if key == "left mouse down":
            self._throw_attack()
        elif key == "right mouse down":
            self._switch_attack()

    def _switch_attack(self):
        self._attack_index = (self._attack_index + 1) % len(ATTACKS)
        attack = ATTACKS[self._attack_index]
        if self.status_text:
            self.status_text.text = (
                f"Selected {ATTACK_LABEL[attack]}  |  L-click: throw  |  "
                "R-click: switch attack"
            )

    def _throw_attack(self):
        if self._attack_cooldown > 0:
            return

        attack = ATTACKS[self._attack_index]
        if attack == "comet" and not self.comet_available:
            if self.status_text:
                self.status_text.text = "The comet has already been used this match"
            return
        direction = Vec3(camera.forward).normalized()
        origin = Vec3(camera.world_position) + direction * 0.8
        message = {
            "id": self.network.player_id,
            "attack": attack,
            "origin": list(origin),
            "direction": list(direction),
        }
        self._spawn_projectile(message)
        self.network.send_attack(attack, origin, direction)
        self._attack_cooldown = 0.45

    def _update_multiplayer(self):
        for message in self.network.poll():
            message_type = message.get("type")
            if message_type == "initial_players":
                for player in message.get("players", []):
                    self._add_remote_player(player)
            elif message_type in ("player_join", "player_update"):
                self._update_remote_player(message)
            elif message_type == "player_leave":
                self._remove_remote_player(message.get("id"))
            elif message_type == "attack":
                self._spawn_projectile(message)
            elif message_type == "flood_start":
                self._start_flood(message.get("remaining", 3))
            elif message_type == "player_hit":
                self._receive_player_hit(message)
            elif message_type == "comet_strike":
                self.comet_available = False
                self.health = 0
            elif message_type == "comet_unavailable":
                self.comet_available = False
                if self.status_text:
                    self.status_text.text = "The comet has already been used this match"
            elif message_type == "disconnected" and self.status_text:
                self.status_text.text = f"Disconnected from host: {message['message']}"

        self._update_projectiles()
        self._update_knockback()
        self._update_flood()
        self._update_water_damage()
        self._update_burning()
        self._update_freeze()
        self._update_remote_damage_flashes()
        self._check_void_death()
        self._check_death()
        self._attack_cooldown = max(0, self._attack_cooldown - time.dt)
        self._position_update_timer += time.dt
        if self._position_update_timer >= 0.1 and self.network.connected:
            self._position_update_timer = 0
            self.network.send_position(self.player.position, self.player.rotation_y)

    def _spawn_projectile(self, message):
        attack = message.get("attack")
        origin = message.get("origin")
        direction = message.get("direction")
        if (
            attack not in ATTACKS
            or not isinstance(origin, list)
            or len(origin) != 3
            or not all(isinstance(value, (int, float)) for value in origin)
            or not isinstance(direction, list)
            or len(direction) != 3
            or not all(isinstance(value, (int, float)) for value in direction)
        ):
            return

        velocity = Vec3(*direction)
        if velocity.length_squared() == 0:
            return
        visual = Entity(
            parent=scene,
            model="quad",
            texture=ATTACK_TEXTURES[attack],
            position=origin,
            scale=ATTACK_ICON_SCALE,
            billboard=True,
            color=color.white,
        )
        self.projectiles.append(
            {
                "visual": visual,
                "attack": attack,
                "owner": message.get("id"),
                "direction": velocity.normalized(),
                "age": 0,
            }
        )

    def _update_projectiles(self):
        for projectile in self.projectiles[:]:
            visual = projectile["visual"]
            direction = projectile["direction"]
            old_position = Vec3(visual.world_position)
            step_length = ATTACK_SPEED[projectile["attack"]] * time.dt
            new_position = old_position + direction * step_length
            visual.world_position = new_position
            projectile["age"] += time.dt

            target_id = None
            for player_id, avatar in self.remote_players.items():
                if player_id != projectile["owner"] and (
                    avatar.world_position + Vec3(0, 0.9, 0) - new_position
                ).length() < 0.9:
                    target_id = player_id
                    break

            hits_world = False
            if target_id is None and step_length > 0:
                world_hit = raycast(
                    old_position,
                    direction,
                    distance=step_length,
                    ignore=[self.player],
                )
                hits_world = world_hit.hit

            if target_id is None and not hits_world:
                target_id = self._local_player_hit(projectile, new_position)

            if target_id is not None or hits_world or projectile["age"] >= 2.5:
                impact_position = (
                    world_hit.world_point if hits_world else new_position
                )
                self._projectile_impact(projectile, target_id, impact_position)
                self.projectiles.remove(projectile)

    def _local_player_hit(self, projectile, position):
        if projectile["owner"] == self.network.player_id:
            return None
        target_position = self.player.world_position + Vec3(0, 0.9, 0)
        if (target_position - position).length() < 0.9:
            return self.network.player_id
        return None

    def _projectile_impact(self, projectile, target_id, position):
        destroy(projectile["visual"])
        if projectile["owner"] != self.network.player_id:
            return

        attack = projectile["attack"]
        if attack == "comet":
            self.network.send_comet_strike()
            return
        if attack == "bomb":
            for player_id, avatar in self.remote_players.items():
                offset = avatar.world_position + Vec3(0, 0.9, 0) - position
                if offset.length() <= BOMB_RADIUS:
                    direction = (
                        offset.normalized()
                        if offset.length_squared()
                        else Vec3(0, 1, 0)
                    )
                    self.network.send_hit(player_id, attack, direction)
            return
        if target_id in self.remote_players and attack in (
            "moai",
            "knockback",
            "fire",
            "ice",
        ):
            self.network.send_hit(
                target_id,
                attack,
                projectile["direction"],
            )

    def _receive_player_hit(self, message):
        target_id = message.get("target_id")
        attack = message.get("attack")
        direction_data = message.get("direction")
        if (
            target_id not in self.remote_players
            and target_id != self.network.player_id
        ):
            return
        if (
            attack not in ATTACK_DAMAGE
            or not isinstance(direction_data, list)
            or len(direction_data) != 3
            or not all(isinstance(value, (int, float)) for value in direction_data)
        ):
            return
        direction = Vec3(*direction_data)
        if target_id == self.network.player_id:
            damage = ATTACK_DAMAGE[attack]
            if damage:
                self._take_damage(damage)
            if attack == "fire":
                self._burn_remaining = FIRE_DURATION
                self._burn_damage_timer = 0
            elif attack == "ice":
                self._freeze_remaining = ICE_DURATION
                if self._normal_player_speed is None:
                    self._normal_player_speed = self.player.speed
                    self._normal_player_jump_height = self.player.jump_height
                self.player.speed = 0
                self.player.jump_height = 0
            elif attack in ("knockback", "bomb"):
                self.knockback_velocity += (
                    Vec3(direction.x, 0, direction.z) * ATTACK_KNOCKBACK
                )
                self.knockback_velocity.y = max(self.knockback_velocity.y, 10)
        elif target_id in self.remote_players and (
            ATTACK_DAMAGE[attack] > 0 or attack in ("fire", "ice")
        ):
            self._flash_remote_player(target_id)

    def _take_damage(self, percent):
        if percent <= 0 or self.health <= 0:
            return
        self.health = max(0, self.health - percent)
        self.health_text.text = f"Health: {self.health}%"
        if self.health == 0 and self.status_text:
            self.status_text.text = "Health: 0%  |  You are knocked out"

    def _update_water_damage(self):
        touching_water = (
            self.flood is not None
            and self.player.y <= self.flood.y
            and self.health > 0
        )
        if not touching_water:
            self._water_damage_timer = 0
            return

        self._water_damage_timer += time.dt
        while self._water_damage_timer >= WATER_DAMAGE_INTERVAL and self.health > 0:
            self._water_damage_timer -= WATER_DAMAGE_INTERVAL
            self._take_damage(WATER_DAMAGE_PERCENT)

    def _update_burning(self):
        if self._burn_remaining <= 0 or self.health <= 0:
            self._burn_remaining = 0
            self._burn_damage_timer = 0
            return
        delta = min(time.dt, self._burn_remaining)
        self._burn_remaining -= delta
        self._burn_damage_timer += delta
        while self._burn_damage_timer >= 1 and self.health > 0:
            self._burn_damage_timer -= 1
            self._take_damage(FIRE_DAMAGE_PERCENT)

    def _update_freeze(self):
        if self._freeze_remaining <= 0:
            return
        self._freeze_remaining = max(0, self._freeze_remaining - time.dt)
        if self._freeze_remaining == 0 and self._normal_player_speed is not None:
            self.player.speed = self._normal_player_speed
            self.player.jump_height = self._normal_player_jump_height
            self._normal_player_speed = None

    def _flash_remote_player(self, player_id):
        avatar = self.remote_players.get(player_id)
        if avatar is None:
            return
        avatar.model_visual.color = color.red
        self._remote_damage_flashes[player_id] = DAMAGE_FLASH_DURATION

    def _update_remote_damage_flashes(self):
        for player_id in list(self._remote_damage_flashes):
            remaining = self._remote_damage_flashes[player_id] - time.dt
            avatar = self.remote_players.get(player_id)
            if remaining <= 0 or avatar is None:
                self._remote_damage_flashes.pop(player_id, None)
                if avatar is not None:
                    avatar.model_visual.color = color.white
            else:
                self._remote_damage_flashes[player_id] = remaining

    def _start_flood(self, remaining):
        if not isinstance(remaining, (int, float)) or remaining <= 0:
            return
        if self.flood is None:
            self.flood = Entity(
                model="plane",
                position=(0, 1, 0),
                scale=(self.world_width + 10, 1, self.world_depth + 10),
                color=color.rgba(0, 120, 255, 220),
                double_sided=True,
            )
        self._flood_remaining = max(self._flood_remaining, remaining)

    def _update_flood(self):
        if self.flood is None:
            return
        self._flood_remaining = max(0, self._flood_remaining - time.dt)
        if self._flood_remaining == 0:
            destroy(self.flood)
            self.flood = None
            self._water_damage_timer = 0

    def _check_death(self):
        if self.health > 0 or self._death_reported:
            return
        self._death_reported = True
        print(f"Player {self.network.player_id} died")
        self.network.send_death()
        application.quit()

    def _check_void_death(self):
        if self.player.y < VOID_DEATH_Y:
            self.health = 0
            self.health_text.text = "Health: 0%  |  Fell into the void"

    def _update_knockback(self):
        if self._freeze_remaining > 0:
            self.knockback_velocity = Vec3(0, 0, 0)
            return
        if self.knockback_velocity.length_squared() < 0.05:
            self.knockback_velocity = Vec3(0, 0, 0)
            return
        self.player.position += self.knockback_velocity * time.dt
        self.knockback_velocity *= max(0, 1 - 2.5 * time.dt)
        self.knockback_velocity.y -= 9.8 * time.dt

    def _add_remote_player(self, data):
        player_id = data.get("id")
        if not isinstance(player_id, str) or player_id == self.network.player_id:
            return
        avatar = self.remote_players.get(player_id)
        if avatar is None:
            avatar = Entity(position=data.get("position", (0, 0, 0)), collider=None)
            avatar.model_visual = Entity(
                parent=avatar,
                model=PLAYER_MODEL,
                texture=PLAYER_TEXTURE,
                scale=PLAYER_MODEL_SCALE,
                y=PLAYER_MODEL_FLOOR_OFFSET,
                collider=None,
            )
            avatar.label = Text(
                parent=avatar,
                text=player_id[:6],
                y=2.1,
                scale=4,
                billboard=True,
            )
            self.remote_players[player_id] = avatar
        self._update_remote_player(data)

    def _update_remote_player(self, data):
        player_id = data.get("id")
        position = data.get("position")
        if (
            not isinstance(player_id, str)
            or not isinstance(position, list)
            or len(position) != 3
            or not all(isinstance(value, (int, float)) for value in position)
        ):
            return
        if player_id not in self.remote_players:
            self._add_remote_player(data)
            return
        avatar = self.remote_players[player_id]
        avatar.position = position
        rotation_y = data.get("rotation_y")
        if isinstance(rotation_y, (int, float)):
            avatar.rotation_y = rotation_y

    def _remove_remote_player(self, player_id):
        avatar = self.remote_players.pop(player_id, None)
        if avatar:
            destroy(avatar)

    def start(self):
        try:
            self.app.run()
        finally:
            self.network.close()


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="Join a hosted BlockGame world")
    parser.add_argument("--host", default="127.0.0.1")
    args = parser.parse_args()
    network = WorldClient(host=args.host, port=DEFAULT_PORT)
    world = BaseWorldEnginePlayer(host=args.host, network=network)
    world.test_plane()
    world.start()