-- Main lua entry point, stress test example

local M = {}
local cos, sin = math.cos, math.sin

local function spawn_grid(self, S)
    -- clear old (TODO: add go.delete when available)
    self.ids = {}
    self.pos_x, self.pos_y = {}, {}
    self.vel_x, self.vel_y = {}, {}
    self._grid_S = S
    local cols = math.floor(640 / S)
    local rows = math.floor(360 / S)
    self._grid_cols = cols
    self._grid_rows = rows
    for r = 0, rows - 1 do
        for c = 0, cols - 1 do
            local idg = go.create()
            local gx = (c + 0.5) * S
            local gy = (r + 0.5) * S
            go.add_transform(idg, gx, gy, 0, 1, 1)
            go.add_sprite(idg, "_0001_Layer-2.png", 0xFFFFFFFF)
            table.insert(self.ids, idg)
            table.insert(self.pos_x, gx)
            table.insert(self.pos_y, gy)
            -- simple deterministic velocities based on grid parity
            local vx = ((c % 2 == 0) and 1 or -1) * 50.0
            local vy = ((r % 2 == 0) and -1 or 1) * 35.0
            table.insert(self.vel_x, vx)
            table.insert(self.vel_y, vy)
        end
    end
    print(string.format("[lua] grid spawned: S=%d, %dx%d = %d sprites", S, cols, rows, cols*rows))
end

local function add_n(self, n)
    -- ensure arrays exist
    self.ids = self.ids or {}
    self.pos_x = self.pos_x or {}
    self.pos_y = self.pos_y or {}
    self.vel_x = self.vel_x or {}
    self.vel_y = self.vel_y or {}
    for i = 1, n do
        local idg = go.create()
        -- random-ish placement and velocity
        local x = math.random() * 640.0
        local y = math.random() * 360.0
        local vx = (math.random() * 2.0 - 1.0) * 60.0
        local vy = (math.random() * 2.0 - 1.0) * 60.0
        go.add_transform(idg, x, y, 0, 1, 1)
        go.add_sprite(idg, "_0001_Layer-2.png", 0xFFFFFFFF)
        table.insert(self.ids, idg)
        table.insert(self.pos_x, x)
        table.insert(self.pos_y, y)
        table.insert(self.vel_x, vx)
        table.insert(self.vel_y, vy)
    end
    print(string.format("[lua] added %d sprites, total=%d", n, #self.ids))
end

function M.init(self)
    -- initial resolution and aspect
    display.set_virtual_resolution(640, 360)
    display.set_aspect_mode("letterbox")
    --create one sprite entity
    local id = go.create()
    go.add_transform(id, 120, 90, 0, 1, 1)
    go.add_sprite(id, "_0001_Layer-2.png", 0xFFFFFFFF)
    self.id = id
    -- ensure this sprite draws above the grid
    go.set_z(self.id, 10.0)
    self.t = 0

    --create a second sprite entity (different color and position)
    local id2 = go.create()
    go.add_transform(id2, 200, 90, 0, 1, 1)
    go.add_sprite(id2, "_0001_Layer-2.png", 0x88FFFFFF)
    self.id2 = id2
    -- draw above the grid as well
    go.set_z(self.id2, 10.0)
    self.t2 = 0

    --create a third sprite from the second atlas to verify multi-atlas
    --uses frame name 'nf-jump.png' from assets/textures/texture2.json
    local id3 = go.create()
    go.add_transform(id3, 260, 120, 0, 1, 1)
    go.add_sprite(id3, "nf-jump.png", 0xFFFFFFFF)
    self.id3 = id3

    --stress test: spawn a grid of sprites and animate them
    spawn_grid(self, 12)
    self._density_steps = {16, 12, 10, 8, 6, 5, 4}
    self._density_idx = 2 -- points to 12
    -- fps meter
    self._acc = 0
    self._frames = 0
end

function M.update(self, dt)
    self.t = self.t + dt
    self._acc = self._acc + dt
    self._frames = self._frames + 1
    -- simple circular motion
    local r = 20
    local x = 120 + math.cos(self.t) * r
    local y = 90 + math.sin(self.t) * r
    go.set_xy(self.id, x, y)

    -- second sprite: counter-rotating circle with larger radius and slow spin
    self.t2 = self.t2 + dt * 0.8
    local r2 = 32
    local x2 = 200 + math.cos(-self.t2) * r2
    local y2 = 90 + math.sin(-self.t2) * r2
    go.set(self.id2, "transform", "x", x2)
    go.set(self.id2, "transform", "y", y2)
    go.set(self.id2, "transform", "rot", self.t2)

    -- animate stress sprites: simple bouncing within screen bounds (per-entity apply)
    if self.ids then
        local ids = self.ids
        local pos_x, pos_y = self.pos_x, self.pos_y
        local vel_x, vel_y = self.vel_x, self.vel_y
        local n = #ids
        local dt_ = dt
        local w, h = 640.0, 360.0
        for i = 1, n do
            local vx = vel_x[i]
            local vy = vel_y[i]
            local x = pos_x[i] + vx * dt_
            local y = pos_y[i] + vy * dt_
            if x < 0.0 then x = 0.0; vx = -vx end
            if x > w   then x = w;   vx = -vx end
            if y < 0.0 then y = 0.0; vy = -vy end
            if y > h   then y = h;   vy = -vy end
            vel_x[i] = vx; vel_y[i] = vy
            pos_x[i] = x; pos_y[i] = y
            go.set_xy(ids[i], x, y)
        end
    end
end

function M.on_input(self, action)
    -- future: react to clicks/keys
end

function M.on_message(self, message_id, message)
    if message_id == "ping" then
        -- add 1000 sprites per key press
        add_n(self, 100)
    else
        print("[lua] on_message:", message_id, message)
    end
end

function M.final(self)
    print("[lua] final called")
end

return M
