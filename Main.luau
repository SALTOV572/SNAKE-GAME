-- Connected Discord-GitHub

-- Server script for the snake game
-- This script creates snake objects for players, moves them on Heartbeat, spawns apples, checks wall/self collisions, updates score and sends UI events to the client

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

-- Main game settings
-- I keep all important numbers here so the snake speed, size, spacing and apple delay can be changed from one place
local CONFIG = {
	SegmentSize    = Vector3.new(3, 3, 3),
	Step           = 3,
	Spacing        = 3.5,
	TickInterval   = 0.5,
	AppleMinDelay  = 3,
	AppleMaxDelay  = 5,
	SnakeColor     = Color3.fromRGB(46, 196, 84),
	SnakeMaterial  = Enum.Material.SmoothPlastic,
}

-- Direction keys are converted into Vector3 movement
-- The snake only moves on the X and Z axis, so Y stays 0
local DIRECTIONS = {
	W = Vector3.new( 0, 0, -1),
	S = Vector3.new( 0, 0,  1),
	A = Vector3.new(-1, 0,  0),
	D = Vector3.new( 1, 0,  0),
}

-- This table is used to block instant 180 degree turns
-- Without this the player could turn into their own body too easily
local OPPOSITES = {
	W = "S",
	S = "W",
	A = "D",
	D = "A",
}

-- Objects needed from the map and ReplicatedStorage
-- StartSpawn decides where the snake appears
-- AppleSpawners contains all possible apple spawn points
-- Apple is the template that gets cloned during the game
local startSpawn = workspace:FindFirstChild("StartSpawn")
local appleSpawners = workspace:FindFirstChild("AppleSpawners")
local appleTemplate = ReplicatedStorage:FindFirstChild("Apple")

-- RemoteEvents are created here so the client and server can talk
-- Client asks to start and change direction
-- Server sends game over and score updates back to the client
local remotesFolder = ReplicatedStorage:FindFirstChild("SnakeRemotes")

if not remotesFolder then
	remotesFolder = Instance.new("Folder")
	remotesFolder.Name = "SnakeRemotes"
	remotesFolder.Parent = ReplicatedStorage
end

local function getOrCreateRemote(name)
	local remote = remotesFolder:FindFirstChild(name)

	if not remote then
		remote = Instance.new("RemoteEvent")
		remote.Name = name
		remote.Parent = remotesFolder
	end

	return remote
end

local rStart = getOrCreateRemote("StartGame")
local rDirection = getOrCreateRemote("ChangeDirection")
local rGameOver = getOrCreateRemote("GameOver")
local rScore = getOrCreateRemote("ScoreUpdate")

-- Snake class
-- Each player gets their own Snake object
-- It stores the snake parts, movement direction, apples, score and state
local Snake = {}
Snake.__index = Snake

-- Creates one body segment part
-- Every segment is anchored because movement is fully controlled by script, not physics
function Snake:_segment(position)
	local part = Instance.new("Part")
	part.Size = CONFIG.SegmentSize
	part.Color = CONFIG.SnakeColor
	part.Material = CONFIG.SnakeMaterial
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Position = position
	part.Parent = self.container

	return part
end

function Snake.new(player)
	local self = setmetatable({}, Snake)

	-- Basic snake state
	-- segments[1] is always the head
	-- trail stores old head positions so body parts can follow the same path smoothly
	self.player = player
	self.segments = {}
	self.trail = {}
	self.directionKey = "D"
	self.direction = DIRECTIONS.D
	self.queued = nil
	self.alive = true
	self.score = 0

	-- Timers used by Heartbeat
	-- moveClock controls snake movement ticks
	-- appleClock controls when the next apple can spawn
	self.moveClock = 0
	self.appleClock = math.random(CONFIG.AppleMinDelay, CONFIG.AppleMaxDelay)

	-- Apples are stored here so this snake only checks its own apples
	self.apples = {}

	-- Folder keeps all parts of this player's snake together
	-- This makes cleanup easy when the player restarts or leaves
	self.container = Instance.new("Folder")
	self.container.Name = player.Name .. "_Snake"
	self.container.Parent = workspace

	-- Spawn position is based on StartSpawn
	-- Y is adjusted so the snake stands on top of the spawn part
	local y = startSpawn.Position.Y + startSpawn.Size.Y / 2 + CONFIG.SegmentSize.Y / 2
	local headPos = Vector3.new(startSpawn.Position.X, y, startSpawn.Position.Z)

	table.insert(self.trail, headPos)
	table.insert(self.segments, self:_segment(headPos))

	return self
end

-- Saves the next direction input from the player
-- The actual turn happens on the next movement tick, not instantly
-- This keeps movement clean and stops several inputs from breaking the snake logic
function Snake:SetDirection(key)
	if not DIRECTIONS[key] then
		return
	end

	if OPPOSITES[self.directionKey] == key then
		return
	end

	self.queued = key
end

-- Spawns an apple on one of the prepared AppleSpawners
-- It only spawns one apple at a time for this snake
-- It also avoids spawn points that are already inside the snake body
function Snake:SpawnApple()
	if #self.apples > 0 then
		return
	end

	local candidates = {}

	for _, spawner in ipairs(appleSpawners:GetChildren()) do
		if spawner:IsA("BasePart") then
			local free = true

			for _, segment in ipairs(self.segments) do
				if (segment.Position - spawner.Position).Magnitude < CONFIG.SegmentSize.X then
					free = false
					break
				end
			end

			if free then
				table.insert(candidates, spawner)
			end
		end
	end

	if #candidates == 0 then
		return
	end

	local chosen = candidates[math.random(1, #candidates)]
	local apple = appleTemplate:Clone()

	apple.Anchored = true
	apple.CanCollide = false
	apple.Position = chosen.Position
	apple.Parent = self.container

	table.insert(self.apples, apple)
end

-- Finds a point on the saved trail by distance from the head
-- Body segments use this so they follow the exact same route as the head
-- Example: second segment samples the trail after Spacing studs, third after Spacing * 2
function Snake:_trailSample(distance)
	local trail = self.trail

	if #trail <= 1 then
		return trail[1]
	end

	local accumulated = 0

	for i = 1, #trail - 1 do
		local from = trail[i]
		local to = trail[i + 1]
		local d = (to - from).Magnitude

		if accumulated + d >= distance then
			local t = (distance - accumulated) / d
			return from:Lerp(to, t)
		end

		accumulated += d
	end

	return trail[#trail]
end

-- Removes old trail points that the tail does not need anymore
-- This stops the trail table from growing forever while the game runs
function Snake:_trimTrail()
	local needed = (#self.segments - 1) * CONFIG.Spacing + CONFIG.Step * 2
	local accumulated = 0

	for i = 1, #self.trail - 1 do
		accumulated += (self.trail[i + 1] - self.trail[i]).Magnitude

		if accumulated >= needed then
			for j = #self.trail, i + 2, -1 do
				self.trail[j] = nil
			end

			return
		end
	end
end

-- One movement step of the snake
-- First it applies the queued direction
-- Then it moves the head, updates the body using the trail, checks death and apple eating
function Snake:Step()
	if not self.alive then
		return
	end

	if self.queued then
		self.direction = DIRECTIONS[self.queued]
		self.directionKey = self.queued
		self.queued = nil
	end

	local headPart = self.segments[1]
	local newHeadPos = headPart.Position + self.direction * CONFIG.Step

	table.insert(self.trail, 1, newHeadPos)
	headPart.Position = newHeadPos

	for i = 2, #self.segments do
		self.segments[i].Position = self:_trailSample((i - 1) * CONFIG.Spacing)
	end

	self:_trimTrail()

	if self:_hitWall(headPart) or self:_hitSelf() then
		self:Die()
		return
	end

	self:_eatApples(headPart)
end

-- Checks if the head is touching any part tagged as Wall
-- I use CollectionService tags so walls can be added in the map without changing the script
function Snake:_hitWall(head)
	local headRadius = CONFIG.SegmentSize.X / 2 - 0.05

	for _, wall in ipairs(CollectionService:GetTagged("Wall")) do
		local localPos = wall.CFrame:PointToObjectSpace(head.Position)
		local halfSize = wall.Size * 0.5

		if math.abs(localPos.X) < halfSize.X + headRadius
			and math.abs(localPos.Y) < halfSize.Y + headRadius
			and math.abs(localPos.Z) < halfSize.Z + headRadius then
			return true
		end
	end

	return false
end

-- Checks if the head touches its own body
-- It starts from segment 3 because the first segment is the head and the second is too close by design
function Snake:_hitSelf()
	local head = self.segments[1]
	local threshold = CONFIG.SegmentSize.X / 2

	for i = 3, #self.segments do
		if (self.segments[i].Position - head.Position).Magnitude < threshold then
			return true
		end
	end

	return false
end

-- Checks if the head is close enough to eat an apple
-- When an apple is eaten, the snake grows by adding a new segment near the tail
-- Then the score is updated both in leaderstats and on the client UI
function Snake:_eatApples(head)
	local eatRange = CONFIG.SegmentSize.X / 2 + CONFIG.Step / 2

	for i = #self.apples, 1, -1 do
		local apple = self.apples[i]

		if (apple.Position - head.Position).Magnitude < eatRange then
			apple:Destroy()
			table.remove(self.apples, i)

			local tailAnchor = self.trail[#self.trail] or self.segments[#self.segments].Position
			table.insert(self.segments, self:_segment(tailAnchor))

			self.score += 1
			rScore:FireClient(self.player, self.score)

			local stats = self.player:FindFirstChild("leaderstats")
			if stats and stats:FindFirstChild("Score") then
				stats.Score.Value = self.score
			end
		end
	end
end

-- Ends the game for this snake
-- The parts are not destroyed here because the player may need to see the final state for a moment
function Snake:Die()
	self.alive = false
	rGameOver:FireClient(self.player, self.score)
end

-- Fully removes this snake from the workspace and clears tables
-- This is used when the player restarts or leaves the server
function Snake:Destroy()
	self.alive = false

	if self.container then
		self.container:Destroy()
	end

	self.container = nil
	self.segments = {}
	self.apples = {}
	self.trail = {}
end

-- Stores all currently active snakes
-- Player object is used as the key so each player has only one snake
local active = {}

-- Creates leaderstats for the player
-- Score is updated when the snake eats apples
local function setupLeaderstats(player)
	local stats = Instance.new("Folder")
	stats.Name = "leaderstats"

	local score = Instance.new("IntValue")
	score.Name = "Score"
	score.Parent = stats

	stats.Parent = player
end

-- Starts a new snake game for the player
-- If the player already had a snake, it gets removed first
local function startGame(player)
	if active[player] then
		active[player]:Destroy()
	end

	local stats = player:FindFirstChild("leaderstats")
	if stats and stats:FindFirstChild("Score") then
		stats.Score.Value = 0
	end

	active[player] = Snake.new(player)
end

-- Handles direction input from the client
-- The server still checks if the snake exists and is alive before changing direction
local function changeDir(player, key)
	local snake = active[player]

	if snake and snake.alive then
		snake:SetDirection(key)
	end
end

-- Setup leaderstats for new players
Players.PlayerAdded:Connect(setupLeaderstats)

-- Also setup players that are already in the server if the script starts after them
for _, player in ipairs(Players:GetPlayers()) do
	setupLeaderstats(player)
end

-- Client requests are connected here
-- StartGame creates/restarts the snake
-- ChangeDirection only changes the queued direction
rStart.OnServerEvent:Connect(startGame)
rDirection.OnServerEvent:Connect(changeDir)

-- Cleanup when player leaves
-- This is important so old snake parts do not stay in workspace
Players.PlayerRemoving:Connect(function(player)
	if active[player] then
		active[player]:Destroy()
		active[player] = nil
	end
end)

-- One Heartbeat loop controls all active snakes
-- This is better than creating a separate loop for every player
-- moveClock makes movement happen in fixed ticks
-- appleClock handles delayed apple spawning
RunService.Heartbeat:Connect(function(dt)
	for _, snake in pairs(active) do
		if snake.alive then
			snake.moveClock += dt
			snake.appleClock -= dt

			if snake.moveClock >= CONFIG.TickInterval then
				snake.moveClock -= CONFIG.TickInterval
				snake:Step()
			end

			if snake.appleClock <= 0 then
				snake:SpawnApple()
				snake.appleClock = math.random(CONFIG.AppleMinDelay, CONFIG.AppleMaxDelay)
			end
		end
	end
end)

