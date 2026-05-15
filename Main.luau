-- Connected Discord-GitHub

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

-- Config
local CONFIG = {
	SegmentSize    = Vector3.new(3, 3, 3),
	Step           = 3, -- studs the head advances per tick
	Spacing        = 3.5, -- center-to-center distance between adjacent body segments (size + gap)
	TickInterval   = 0.5, -- seconds between snake steps
	AppleMinDelay  = 3, -- min seconds before the next apple spawn attempt
	AppleMaxDelay  = 5, -- max seconds before the next apple spawn attempt
	SnakeColor     = Color3.fromRGB(46, 196, 84),
	SnakeMaterial  = Enum.Material.SmoothPlastic,
}

-- Movement
local DIRECTIONS = {
	W = Vector3.new( 0, 0, -1),
	S = Vector3.new( 0, 0,  1),
	A = Vector3.new(-1, 0,  0),
	D = Vector3.new( 1, 0,  0),
}

-- Reject 180° flips
local OPPOSITES = { W = "S", S = "W", A = "D", D = "A" }

local startSpawn    = workspace:WaitForChild("StartSpawn")
local appleSpawners = workspace:WaitForChild("AppleSpawners") 
local appleTemplate = ReplicatedStorage:WaitForChild("Apple")

-- Remotes
local remotesFolder = Instance.new("Folder")
remotesFolder.Name   = "SnakeRemotes"
remotesFolder.Parent = ReplicatedStorage

local function buildRemote(name)
	local r = Instance.new("RemoteEvent")
	r.Name   = name
	r.Parent = remotesFolder
	return r
end

local rStart = buildRemote("StartGame")
local rDirection = buildRemote("ChangeDirection")
local rGameOver = buildRemote("GameOver")
local rScore = buildRemote("ScoreUpdate")

local Snake = {}
Snake.__index = Snake

-- Build one body segment Part at a given position
function Snake:_segment(position)
	local p = Instance.new("Part")
	p.Size          = CONFIG.SegmentSize
	p.Color         = CONFIG.SnakeColor
	p.Material      = CONFIG.SnakeMaterial
	p.Anchored      = true                              
	p.CanCollide    = false                           
	p.CanQuery      = false                             
	p.TopSurface    = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Position      = position
	p.Parent        = self.container
	return p
end

function Snake.new(player)
	local self = setmetatable({}, Snake)
	self.player        = player
	self.segments      = {} -- [1] = head, [#] = tail
	self.trail         = {} -- recent head positions, [1] = newest; body segments are sampled along this path
	self.directionKey  = "D"
	self.direction     = DIRECTIONS.D
	self.queued        = nil -- buffered turn, applied at next tick boundary
	self.alive         = true
	self.score         = 0
	self.moveClock     = 0                              
	self.appleClock    = math.random(CONFIG.AppleMinDelay, CONFIG.AppleMaxDelay)
	self.apples        = {}

	self.container      = Instance.new("Folder")
	self.container.Name = player.Name .. "_Snake"
	self.container.Parent = workspace

	local y = startSpawn.Position.Y + startSpawn.Size.Y/2 + CONFIG.SegmentSize.Y/2
	local headPos = Vector3.new(startSpawn.Position.X, y, startSpawn.Position.Z)
	table.insert(self.trail, headPos)
	table.insert(self.segments, self:_segment(headPos))
	return self
end

-- in a single tick can never cancel each other into an opposite direction
function Snake:SetDirection(key)
	if not DIRECTIONS[key] then return end
	if OPPOSITES[self.directionKey] == key then return end
	self.queued = key
end

-- Droping a cloned apple onto one of the predefined AppleSpawners
function Snake:SpawnApple()
	if #self.apples > 0 then return end

	-- Collect spawners that aren't currently occupied by the snake
	local candidates = {}
	for _, sp in ipairs(appleSpawners:GetChildren()) do
		if sp:IsA("BasePart") then
			local free = true
			for _, seg in ipairs(self.segments) do
				if (seg.Position - sp.Position).Magnitude < CONFIG.SegmentSize.X then
					free = false
					break
				end
			end
			if free then
				table.insert(candidates, sp)
			end
		end
	end

	if #candidates == 0 then return end

	local chosen = candidates[math.random(1, #candidates)]
	local apple  = appleTemplate:Clone()
	apple.Anchored   = true
	apple.CanCollide = false
	apple.Position   = chosen.Position
	apple.Parent     = self.container
	table.insert(self.apples, apple)
end

-- Returns the trail's last point if the requested distance exceeds the trail
function Snake:_trailSample(distance)
	local trail = self.trail
	if #trail <= 1 then return trail[1] end

	local accumulated = 0
	for i = 1, #trail - 1 do
		local from = trail[i]
		local to   = trail[i + 1]
		local d    = (to - from).Magnitude
		if accumulated + d >= distance then
			local t = (distance - accumulated) / d
			return from:Lerp(to, t)
		end
		accumulated += d
	end
	return trail[#trail]
end

-- Drop trail nodes once the tail has passed them; bounds memory growth at O
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

-- One movement tick. The head advances Step studs and pushes its new position onto the trail
function Snake:Step()
	if not self.alive then return end

	if self.queued then
		self.direction    = DIRECTIONS[self.queued]
		self.directionKey = self.queued
		self.queued       = nil
	end

	local headPart   = self.segments[1]
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

-- Walls hitting
function Snake:_hitWall(head)
	local hr = CONFIG.SegmentSize.X / 2 - 0.05
	for _, wall in ipairs(CollectionService:GetTagged("Wall")) do
		local localPos = wall.CFrame:PointToObjectSpace(head.Position)
		local hs       = wall.Size * 0.5
		if math.abs(localPos.X) < hs.X + hr
			and math.abs(localPos.Y) < hs.Y + hr
			and math.abs(localPos.Z) < hs.Z + hr then
			return true
		end
	end
	return false
end

-- Self hittingg
function Snake:_hitSelf()
	local head      = self.segments[1]
	local threshold = CONFIG.SegmentSize.X / 2
	for i = 3, #self.segments do
		if (self.segments[i].Position - head.Position).Magnitude < threshold then
			return true
		end
	end
	return false
end

-- Apples logic
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

function Snake:Die()
	self.alive = false
	rGameOver:FireClient(self.player, self.score)
end

function Snake:Destroy()
	self.alive = false
	if self.container then
		self.container:Destroy()
	end
	self.container = nil
	self.segments  = {}
	self.apples    = {}
	self.trail     = {}
end


local active = {}                                   

local function setupLeaderstats(player)
	local stats = Instance.new("Folder")
	stats.Name  = "leaderstats"
	local score = Instance.new("IntValue")
	score.Name   = "Score"
	score.Parent = stats
	stats.Parent = player
end

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

local function changeDir(player, key)
	local s = active[player]
	if s and s.alive then s:SetDirection(key) end
end

Players.PlayerAdded:Connect(setupLeaderstats)
for _, p in ipairs(Players:GetPlayers()) do setupLeaderstats(p) end

rStart.OnServerEvent:Connect(startGame)
rDirection.OnServerEvent:Connect(changeDir)

Players.PlayerRemoving:Connect(function(player)
	if active[player] then
		active[player]:Destroy()
		active[player] = nil
	end
end)

-- A single Heartbeat connection drives every active snake
RunService.Heartbeat:Connect(function(dt)
	for _, snake in pairs(active) do
		if snake.alive then
			snake.moveClock  += dt
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

