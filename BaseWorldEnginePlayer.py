import random
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
BOX_DIR = Path(__file__).resolve().parent / "assets" / "box"
try:
    CHEST_MODEL = load_model("box.obj", folder=BOX_DIR, use_deepcopy=True)
    CHEST_TEXTURE = load_texture("box.png", folder=BOX_DIR)
except Exception:
    CHEST_MODEL = "cube"
    CHEST_TEXTURE = None
EMOJI_DIR = Path(__file__).resolve().parent / "assets" / "emojis"
ATTACKS = ("ice", "fire", "moai", "sob", "knockback", "bomb", "comet")
ATTACK_LABEL = {
    "ice": "ice",
    "fire": "fire",
    "moai": "moai",
    "sob": "tears",
    "knockback": "knockback",
    "bomb": "bomb",
    "comet": "comet",
}
LOOT_TABLE = [
    ("ice", 40, (3, 6)),
    ("fire", 25, (2, 4)),
    ("moai", 15, (2, 3)),
    ("sob", 10, (1, 2)),
    ("knockback", 6, (1, 2)),
    ("bomb", 3, (1, 1)),
    ("comet", 1, (1, 1)),
]
CHEST_POSITIONS = [
    (0.0, 0.0, 8.0),
    (0.0, 0.0, -8.0),
    (8.0, 0.0, 0.0),
    (-8.0, 0.0, 0.0),
    (14.0, 0.0, 14.0),
    (-14.0, 0.0, 14.0),
    (14.0, 0.0, -14.0),
    (-14.0, 0.0, -14.0),
    (18.0, 0.0, 0.0),
    (-18.0, 0.0, 0.0),
    (0.0, 0.0, 18.0),
    (0.0, 0.0, -18.0),
]
CHEST_RESPAWN_TIME = 20.0
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
    "moai": 8,
    "knockback": 13,
    "fire": 15,
    "bomb": 12,
    "ice": 15,
    "comet": 18,
}
ATTACK_GRAVITY = {
    "sob": 18,
    "moai": 32,
    "knockback": 18,
    "fire": 18,
    "bomb": 24,
    "ice": 18,
    "comet": 24,
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
        self.match_ended = False
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
        self.ammo = {attack: 0 for attack in ATTACKS}
        self.chests = []
        self.hotbar_slots = []
        self.interact_prompt = None
        self.loot_banner = None
        self.loot_banner_icons = []
        self._loot_banner_timer = 0
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
            if texture == "box":
                continue
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
                f"Connected as {self.network.player_id[:8]}  |  "
                "WASD: move  |  Space: jump  |  "
                "1-7 / Scroll: hotbar  |  L-click: throw  |  E: open chest"
            )
        self.interact_prompt = Text(
            parent=camera.ui,
            text="",
            origin=(0, 0),
            position=(0, -0.22),
            scale=1.2,
            color=color.yellow,
            background=True,
            visible=False,
        )
        self.loot_banner = Text(
            parent=camera.ui,
            text="",
            origin=(0, 0),
            position=(0, -0.12),
            scale=1.3,
            color=color.gold,
            background=True,
            visible=False,
        )
        self._build_hotbar()
        self._build_chests()
        self._show_loot_banner("Open a loot chest to collect emojis! ([E])")

    def _build_hotbar(self):
        slot_size = 0.08
        slot_gap = 0.088
        start_x = -(3 * slot_gap)
        y = -0.42
        for i, attack in enumerate(ATTACKS):
            x = start_x + i * slot_gap
            border = Entity(
                parent=camera.ui,
                model="quad",
                scale=(slot_size + 0.008, slot_size + 0.008),
                position=(x, y, 0.02),
                color=color.gold if i == self._attack_index else color.rgba(60, 60, 60, 180),
            )
            bg = Entity(
                parent=camera.ui,
                model="quad",
                scale=(slot_size, slot_size),
                position=(x, y, 0.01),
                color=color.rgba(20, 20, 20, 220),
            )
            icon = Entity(
                parent=camera.ui,
                model="quad",
                texture=ATTACK_TEXTURES[attack],
                scale=(slot_size * 0.72, slot_size * 0.72),
                position=(x, y, 0.0),
                color=color.white if self.ammo.get(attack, 0) > 0 else color.rgba(180, 180, 180, 100),
            )
            num_text = Text(
                parent=camera.ui,
                text=str(i + 1),
                position=(x - slot_size * 0.42, y + slot_size * 0.42, -0.01),
                scale=0.75,
                color=color.light_gray,
            )
            count_text = Text(
                parent=camera.ui,
                text=str(self.ammo.get(attack, 0)),
                position=(x + slot_size * 0.12, y - slot_size * 0.22, -0.01),
                scale=0.85,
                color=color.white if self.ammo.get(attack, 0) > 0 else color.red,
            )
            self.hotbar_slots.append({
                "border": border,
                "bg": bg,
                "icon": icon,
                "num_text": num_text,
                "count_text": count_text,
                "attack": attack,
            })
        self._update_hotbar_ui()

    def _build_chests(self):
        opened_set = set(getattr(self.network, "opened_chests", []))
        for i, pos in enumerate(CHEST_POSITIONS):
            chest_ent = Entity(
                model=(
                    load_model("box.obj", folder=BOX_DIR, use_deepcopy=True)
                    if CHEST_MODEL != "cube"
                    else "cube"
                ),
                texture=CHEST_TEXTURE,
                position=(pos[0], pos[1], pos[2]),
                scale=3.5 if CHEST_MODEL != "cube" else 1.0,
                color=color.white if CHEST_TEXTURE else color.rgb(218, 145, 32),
                collider="box",
            )
            is_opened = i in opened_set
            if is_opened:
                chest_ent.visible = False
                chest_ent.collider = None
            self.chests.append({
                "id": i,
                "entity": chest_ent,
                "position": Vec3(pos[0], pos[1], pos[2]),
                "is_opened": is_opened,
                "respawn_timer": CHEST_RESPAWN_TIME if is_opened else 0.0,
            })

    def _select_slot(self, index):
        if 0 <= index < len(ATTACKS):
            self._attack_index = index
            self._update_hotbar_ui()

    def _update_hotbar_ui(self):
        for i, slot in enumerate(self.hotbar_slots):
            attack = slot["attack"]
            count = self.ammo.get(attack, 0)
            if i == self._attack_index:
                slot["border"].color = color.gold
                slot["border"].scale = (0.092, 0.092)
            else:
                slot["border"].color = color.rgba(60, 60, 60, 180)
                slot["border"].scale = (0.088, 0.088)
            slot["count_text"].text = str(count)
            if count > 0:
                slot["count_text"].color = color.white
                slot["icon"].color = color.white
            else:
                slot["count_text"].color = color.red
                slot["icon"].color = color.rgba(180, 180, 180, 100)

    def _show_loot_banner(self, text, icons=()):
        if self.loot_banner:
            self.loot_banner.text = text
            self.loot_banner.visible = True
            self._loot_banner_timer = 3.0
        for icon in self.loot_banner_icons:
            destroy(icon)
        self.loot_banner_icons = []
        spacing = 0.05
        start_x = -(len(icons) - 1) * spacing / 2
        for index, attack in enumerate(icons):
            icon = Entity(
                parent=camera.ui,
                model="quad",
                texture=ATTACK_TEXTURES[attack],
                scale=0.035,
                position=(start_x + index * spacing, -0.2, 0),
            )
            self.loot_banner_icons.append(icon)

    def _roll_loot(self):
        num_drops = random.randint(2, 3)
        items = [entry[0] for entry in LOOT_TABLE]
        weights = [entry[1] for entry in LOOT_TABLE]
        picked = random.choices(items, weights=weights, k=num_drops)
        loot = {}
        for item in picked:
            entry = next(e for e in LOOT_TABLE if e[0] == item)
            qty = random.randint(entry[2][0], entry[2][1])
            loot[item] = loot.get(item, 0) + qty
        return loot

    def _open_chest(self, chest):
        if chest["is_opened"]:
            return
        chest["is_opened"] = True
        chest["respawn_timer"] = CHEST_RESPAWN_TIME
        chest["entity"].visible = False
        chest["entity"].collider = None

        loot = self._roll_loot()
        parts = []
        for attack, qty in loot.items():
            self.ammo[attack] = self.ammo.get(attack, 0) + qty
            parts.append(f"+{qty} {ATTACK_LABEL[attack]}")
        self._update_hotbar_ui()

        loot_str = "  ".join(parts)
        self._show_loot_banner(f"Loot: {loot_str}", icons=loot)

        for attack in loot:
            pop = Entity(
                parent=scene,
                model="quad",
                texture=ATTACK_TEXTURES[attack],
                position=chest["position"] + Vec3(0, 1.2, 0),
                scale=0.8,
                billboard=True,
            )
            pop.animate_position(
                pop.position + Vec3((random.random() - 0.5) * 2, 2.0, (random.random() - 0.5) * 2),
                duration=0.8,
            )
            destroy(pop, delay=0.8)

        if self.network.connected:
            self.network.send_chest_opened(chest["id"])

    def _remote_open_chest(self, chest_id):
        for chest in self.chests:
            if chest["id"] == chest_id and not chest["is_opened"]:
                chest["is_opened"] = True
                chest["respawn_timer"] = CHEST_RESPAWN_TIME
                chest["entity"].visible = False
                chest["entity"].collider = None
                break

    def _try_interact_chest(self):
        player_pos = self.player.world_position
        for chest in self.chests:
            if not chest["is_opened"] and (chest["position"] - player_pos).length() < 3.5:
                self._open_chest(chest)
                return True
        return False

    def input(self, key):
        if self.match_ended:
            return
        if key in ("1", "2", "3", "4", "5", "6", "7"):
            self._select_slot(int(key) - 1)
        elif key == "scroll up":
            self._select_slot((self._attack_index - 1) % len(ATTACKS))
        elif key == "scroll down":
            self._select_slot((self._attack_index + 1) % len(ATTACKS))
        elif key == "right mouse down":
            self._select_slot((self._attack_index + 1) % len(ATTACKS))
        elif key in ("e", "E"):
            self._try_interact_chest()
        elif key == "left mouse down":
            hit_info = raycast(camera.world_position, camera.forward, distance=4.5, ignore=[self.player])
            if hit_info.hit:
                for chest in self.chests:
                    if not chest["is_opened"] and hit_info.entity == chest["entity"]:
                        self._open_chest(chest)
                        return
            self._throw_attack()

    def _throw_attack(self):
        if self._attack_cooldown > 0:
            return

        attack = ATTACKS[self._attack_index]
        if self.ammo.get(attack, 0) <= 0:
            self._show_loot_banner(
                f"No {ATTACK_LABEL[attack]} left! Find a loot chest.",
                icons=(attack,),
            )
            return
        if attack == "comet" and not self.comet_available:
            self._show_loot_banner("De komeet is al gebruikt dit spel!")
            return

        self.ammo[attack] -= 1
        self._update_hotbar_ui()

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
            elif message_type == "match_end":
                self.match_ended = True
                reason = message.get("reason", "unknown")
                self._show_loot_banner(f"Match ended (reason: {reason})")
                if self.status_text:
                    self.status_text.text = "Match ended"
            elif message_type == "chest_opened":
                self._remote_open_chest(message.get("chest_id"))
            elif message_type == "disconnected" and self.status_text:
                self.status_text.text = f"Disconnected from host: {message['message']}"

        if self.match_ended:
            return

        self._update_projectiles()
        self._update_knockback()
        self._update_flood()
        self._update_water_damage()
        self._update_burning()
        self._update_freeze()
        self._update_remote_damage_flashes()
        self._check_void_death()
        self._check_death()

        if self._loot_banner_timer > 0:
            self._loot_banner_timer -= time.dt
            if self._loot_banner_timer <= 0 and self.loot_banner:
                self.loot_banner.visible = False
                for icon in self.loot_banner_icons:
                    destroy(icon)
                self.loot_banner_icons = []

        nearest_chest = None
        nearest_dist = float("inf")
        player_pos = self.player.world_position if self.player else Vec3(0, 0, 0)
        for chest in self.chests:
            if chest["is_opened"]:
                chest["respawn_timer"] -= time.dt
                if chest["respawn_timer"] <= 0:
                    chest["is_opened"] = False
                    chest["entity"].visible = True
                    chest["entity"].collider = "box"
            else:
                dist = (chest["position"] - player_pos).length()
                if dist < nearest_dist:
                    nearest_dist = dist
                    nearest_chest = chest

        if nearest_chest and nearest_dist < 1.6:
            self._open_chest(nearest_chest)
        elif nearest_chest and nearest_dist < 3.2:
            if self.interact_prompt:
                self.interact_prompt.text = "Press [E] to open the loot chest"
                self.interact_prompt.visible = True
        else:
            if self.interact_prompt:
                self.interact_prompt.visible = False

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

        launch_direction = Vec3(*direction)
        if launch_direction.length_squared() == 0:
            return
        launch_velocity = launch_direction.normalized() * ATTACK_SPEED[attack]
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
                "velocity": launch_velocity,
                "age": 0,
            }
        )

    def _update_projectiles(self):
        for projectile in self.projectiles[:]:
            visual = projectile["visual"]
            old_position = Vec3(visual.world_position)
            velocity = projectile["velocity"]
            velocity.y -= ATTACK_GRAVITY[projectile["attack"]] * time.dt
            projectile["velocity"] = velocity
            displacement = velocity * time.dt
            step_length = displacement.length()
            direction = displacement.normalized() if step_length else Vec3(0, 0, 0)
            new_position = old_position + displacement
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
            world_hit = None
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

            if target_id is not None or hits_world or projectile["age"] >= 4:
                impact_position = (
                    world_hit.world_point
                    if hits_world and world_hit is not None
                    else new_position
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
            impact_direction = projectile["velocity"].normalized()
            self.network.send_hit(
                target_id,
                attack,
                impact_direction,
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