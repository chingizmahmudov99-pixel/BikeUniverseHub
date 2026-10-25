--!nonstrict
--[[
	Bike Universe Hub
	-----------------
	1. Teleport farm - the bike is thrown up and the air time is cashed in
	2. Auto wheelie - holds a wheelie and keeps you on the bike
	3. Rider lock - seats you back on the bike whenever the game throws you off
	4. Pumpkin farm (experimental)
	5. Police car ESP
	6. Player ESP
	7. Bike movement tuning
	8. Teleports

	How the bike is driven here: the game reads throttle from
	TouchControls.drive(seat) every frame, and that function returns
	seat.ThrottleFloat + TouchControls.throttle. The on-screen controls rewrite
	TouchControls.throttle every frame, so writing that field from outside does
	nothing; drive() itself is hooked instead, and the hook passes the player's own
	input straight through whenever the hub is not driving.

	Seating goes through the game's own mount call: BikeMountClient stands you next
	to the bike, waits for W, then fires BikeMountSkip(bike) and the server seats
	you. A direct Seat:Sit is kept as the fallback.

	RightControl shows or hides the window.
]]

----------------------------------------------------------------------
-- UI library
----------------------------------------------------------------------

local UI_SOURCES = {
	"https://raw.githubusercontent.com/bobloscript/Robly_Airflow/main/Source.luau",
	"https://raw.githubusercontent.com/PookiePepelsss/Airflow-UI/refs/heads/main/Source.luau",
}

local Airflow
for _, url in ipairs(UI_SOURCES) do
	local ok, lib = pcall(function()
		return loadstring(game:HttpGet(url))()
	end)
	if ok and type(lib) == "table" and type(lib.CreateWindow) == "function" then
		Airflow = lib
		break
	end
end
if not Airflow then
	error("[Bike Universe Hub] The UI library could not be loaded. Check your connection and retry.")
end

----------------------------------------------------------------------
-- Services
----------------------------------------------------------------------

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local VirtualInputManager = game:GetService("VirtualInputManager")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

--- The crash system. The game throws the rider off by calling Ragdoll.fling().
local Ragdoll
pcall(function()
	Ragdoll = require(ReplicatedStorage:WaitForChild("Ragdoll", 5))
end)

local function short(value)
	if type(value) ~= "number" then
		return "-"
	end
	local text = tostring(math.floor(value))
	return (text:reverse():gsub("(%d%d%d)", "%1 "):reverse():gsub("^%s+", ""))
end

----------------------------------------------------------------------
-- Bike
----------------------------------------------------------------------

local function myBike()
	for _, child in ipairs(workspace:GetChildren()) do
		if child:IsA("Model") and child:GetAttribute("Owner") == LocalPlayer.UserId then
			return child
		end
	end
	return nil
end

local function chassis()
	local bike = myBike()
	return bike and (bike:FindFirstChild("Chassis") or bike.PrimaryPart) or nil
end

local function driverSeat()
	local bike = myBike()
	return bike and bike:FindFirstChild("DriverSeat") or nil
end

local function humanoid()
	local char = LocalPlayer.Character
	return char and char:FindFirstChildOfClass("Humanoid") or nil
end

local function bikePosition()
	local bike = myBike()
	return bike and bike:GetPivot().Position or nil
end

--- The occupant of the seat is the only trustworthy sign of a rider:
--- Humanoid.SeatPart stays pointed at the seat long after the player is off it.
local function isRiding()
	local seat, hum = driverSeat(), humanoid()
	return seat ~= nil and hum ~= nil and seat.Occupant == hum
end

local function cash()
	local stats = LocalPlayer:FindFirstChild("leaderstats")
	local value = stats and stats:FindFirstChild("Cash")
	return value and value.Value or 0
end

----------------------------------------------------------------------
-- Drive control
----------------------------------------------------------------------

local TouchControls
pcall(function()
	TouchControls = require(ReplicatedStorage:WaitForChild("TouchControls"))
end)

local driveState = getgenv().__BikeHubDrive
if not driveState then
	driveState = { on = false, throttle = 0, steer = 0 }
	getgenv().__BikeHubDrive = driveState
end

if TouchControls and type(TouchControls.drive) == "function" then
	local marker = getgenv().__BikeHubDriveMarker
	if TouchControls.drive ~= marker then
		local originalDrive = TouchControls.drive
		local hooked
		hooked = function(seat)
			local state = getgenv().__BikeHubDrive
			-- Only take over while this very copy of the script is driving, so a
			-- stale state left behind by an older copy can never pin the bike and
			-- the player keeps full control while nothing is running.
			if state and state.on and state.gen == getgenv().__BikeHubGen
				and (os.clock() - (state.last or 0) < 0.4) then
				return state.throttle, state.steer
			end
			return originalDrive(seat)
		end
		TouchControls.drive = hooked
		getgenv().__BikeHubDriveMarker = hooked
	end
end

local function drive(throttle, steer)
	driveState.throttle = throttle or 0
	driveState.steer = steer or 0
	driveState.on = true
	driveState.last = os.clock()
	driveState.gen = getgenv().__BikeHubGen
end

local function driveStop()
	driveState.on = false
	driveState.last = 0
	driveState.throttle = 0
	driveState.steer = 0
end

----------------------------------------------------------------------
-- Key mirroring (the game reads the wheelie and the mount from the keyboard)
----------------------------------------------------------------------

local heldKeys = {}

local function key(code, down)
	if heldKeys[code] == down then
		return
	end
	heldKeys[code] = down
	pcall(function()
		VirtualInputManager:SendKeyEvent(down, code, false, game)
	end)
end

local function releaseKeys()
	for code, down in pairs(heldKeys) do
		if down then
			pcall(function()
				VirtualInputManager:SendKeyEvent(false, code, false, game)
			end)
		end
	end
	heldKeys = {}
end

----------------------------------------------------------------------
-- Seating
----------------------------------------------------------------------

local log
local riderLockSet
local spawnBike
local pumpkinList
local teleportBike

--- Spawns the player's bike through the game's own remotes when it is missing.
spawnBike = function()
	if myBike() then
		return true
	end
	for _, name in ipairs({ "SpawnBikeEvent", "SelectBike", "BikeMount" }) do
		local remote = ReplicatedStorage:FindFirstChild(name)
		if remote and remote:IsA("RemoteEvent") then
			pcall(function()
				remote:FireServer()
			end)
			for _ = 1, 10 do
				task.wait(0.2)
				if myBike() then
					return true
				end
			end
		end
	end
	return myBike() ~= nil
end

--- A bike lying on its side cannot be mounted at all: Seat:Sit silently fails
--- while the seat is below the ground line. The bike is stood back up first, and
--- the game's own spawn call is the fallback because it definitely survives the
--- server's position check.
local function standBikeUp(bike)
	local pivot = bike:GetPivot()
	if pivot.UpVector.Y > 0.6 then
		return true
	end
	local look = Vector3.new(pivot.LookVector.X, 0, pivot.LookVector.Z)
	if look.Magnitude < 0.05 then
		look = Vector3.new(0, 0, -1)
	end
	local position = pivot.Position + Vector3.new(0, 3, 0)
	pcall(function()
		bike:PivotTo(CFrame.lookAt(position, position + look.Unit))
	end)
	task.wait(0.2)
	if bike:GetPivot().UpVector.Y > 0.6 then
		return true
	end

	local spawn = ReplicatedStorage:FindFirstChild("SpawnBikeEvent")
	if spawn and spawn:IsA("RemoteEvent") then
		pcall(function()
			spawn:FireServer()
		end)
		for _ = 1, 12 do
			task.wait(0.25)
			local again = myBike()
			if again and again:GetPivot().UpVector.Y > 0.6 then
				return true
			end
		end
	end
	return false
end

--- Puts the player back on the bike. The game mounts through its own call:
--- BikeMountClient stands you next to the bike, waits for W, then fires
--- BikeMountSkip(bike) and the server seats you. That is far more reliable than
--- Seat:Sit, which the mount animation undoes a moment later.
local function seatUp()
	local seat, hum, bike = driverSeat(), humanoid(), myBike()
	if not (seat and hum and bike) then
		spawnBike()
		seat, hum, bike = driverSeat(), humanoid(), myBike()
	end
	if not (seat and hum and bike) then
		return false
	end
	if seat.Occupant == hum then
		return true
	end

	local char = LocalPlayer.Character
	if not char then
		return false
	end
	if Ragdoll and Ragdoll.isActive and Ragdoll.isActive(char) then
		pcall(function()
			Ragdoll.stop(char)
		end)
	end
	if hum.PlatformStand then
		hum.PlatformStand = false
	end
	pcall(function()
		hum:ChangeState(Enum.HumanoidStateType.GettingUp)
	end)
	pcall(function()
		hum.Sit = false
	end)
	task.wait(0.1)

	-- A tipped bike cannot take a rider, so it is stood up before anything else.
	standBikeUp(bike)
	seat, hum, bike = driverSeat(), humanoid(), myBike()
	if not (seat and hum and bike) then
		return false
	end

	-- Sit straight onto the seat: with an upright bike this takes on the first try.
	for attempt = 1, 3 do
		pcall(function()
			char:PivotTo(seat.CFrame * CFrame.new(0, attempt == 1 and 1.5 or 0.4, 0))
		end)
		task.wait(0.1)
		pcall(function()
			seat:Sit(hum)
		end)
		for _ = 1, 8 do
			if seat.Occupant == hum then
				return true
			end
			task.wait(0.05)
		end
	end

	-- Fallback: the game's own mount flow (stand next to the bike, hold W, then the
	-- mount remote it watches).
	local pivot = bike:GetPivot()
	pcall(function()
		char:PivotTo(pivot * CFrame.new(2.5, 2, 0))
	end)
	task.wait(0.15)
	local mountSkip = ReplicatedStorage:FindFirstChild("BikeMountSkip")
	if mountSkip and mountSkip:IsA("RemoteEvent") then
		pcall(function()
			mountSkip:FireServer(bike)
		end)
	end
	key(Enum.KeyCode.W, true)
	for _ = 1, 30 do
		if seat.Occupant == hum then
			break
		end
		task.wait(0.05)
	end
	key(Enum.KeyCode.W, false)
	return seat.Occupant == hum
end

----------------------------------------------------------------------
-- Never crash
----------------------------------------------------------------------

--- Ragdoll.fling() is the call that throws the rider off, so a crash cannot start
--- while the farm is running or the rider lock is on.
if Ragdoll and type(Ragdoll.fling) == "function" and not getgenv().__BikeHubFlingHooked then
	getgenv().__BikeHubFlingHooked = true
	local originalFling = Ragdoll.fling
	Ragdoll.fling = function(...)
		if getgenv().__BikeFarmOn or getgenv().__BikeHubRiderLock then
			return
		end
		return originalFling(...)
	end
end

--- Clean-up for the crashes that still slip through.
local function riderLockTick()
	local seat, hum = driverSeat(), humanoid()
	if not (seat and hum) then
		return
	end
	if getgenv().__BikeHubRiderLock and seat.Occupant ~= hum then
		local char = LocalPlayer.Character
		if char then
			pcall(function()
				char:PivotTo(seat.CFrame * CFrame.new(0, 1.5, 0))
			end)
		end
		pcall(function()
			seat:Sit(hum)
		end)
	end
	if hum.PlatformStand then
		hum.PlatformStand = false
	end
	local state = hum:GetState()
	if state == Enum.HumanoidStateType.Ragdoll or state == Enum.HumanoidStateType.FallingDown then
		pcall(function()
			hum:ChangeState(Enum.HumanoidStateType.GettingUp)
		end)
	end
end

----------------------------------------------------------------------
-- Settings
----------------------------------------------------------------------

local Settings = {
	farmOn = false,
	height = 140,
	cooldown = 3.0,

	wheelieOn = false,
	riderLock = false,

	pumpkinFarm = false,
	playerEsp = false,
	policeEsp = false,
}

local Stats = {
	jumps = 0,
	lastCash = 0,
	lastSample = 0,
	perMinute = 0,
	launchPosition = nil,
	launchRotation = nil,
}

local Window
local UiRefs = {}

getgenv().__BikeHubGen = (getgenv().__BikeHubGen or 0) + 1
local SCRIPT_GENERATION = getgenv().__BikeHubGen

local function scriptAlive()
	return getgenv().__BikeHubGen == SCRIPT_GENERATION
end

----------------------------------------------------------------------
-- 1. TELEPORT FARM
----------------------------------------------------------------------

local anchor

local function captureAnchor()
	local part = chassis()
	anchor = part and part.Position or nil
end

--- Auto wheelie pins the bike where it stands. A correction runs every frame while
--- the throttle is open, so the game keeps believing the ride is happening.
local function holdAnchor()
	local bike, part = myBike(), chassis()
	if not (bike and part) then
		return
	end
	if not anchor then
		anchor = part.Position
	end
	local rotation = part.CFrame - part.CFrame.Position
	pcall(function()
		bike:PivotTo(CFrame.new(anchor) * rotation)
	end)
	part.AssemblyLinearVelocity = Vector3.zero
	part.AssemblyAngularVelocity = Vector3.zero
end

--- One farm cycle: throw the bike up, hold the throttle through the fall, wait for
--- the wheels to touch, then let the line cash out.
local function jumpOnce()
	local bike, part = myBike(), chassis()
	if not (bike and part) then
		spawnBike()
		task.wait(0.2)
		return false
	end
	if not isRiding() and not seatUp() then
		return false
	end

	-- Every jump is launched from the last spot the wheels touched, not from
	-- wherever the bike happens to be, so a jump that never lands cannot walk the
	-- bike off the map one hop at a time.
	if not bike:GetAttribute("Airborne") then
		Stats.launchPosition = part.Position
		Stats.launchRotation = part.CFrame - part.CFrame.Position
	end
	local base = Stats.launchPosition or part.Position
	local rotation = Stats.launchRotation or (part.CFrame - part.CFrame.Position)

	drive(1)
	bike:PivotTo(CFrame.new(base + Vector3.new(math.random(-25, 25), Settings.height, math.random(-25, 25))) * rotation)

	local started = os.clock()
	local lostRider = false
	while bike:GetAttribute("Airborne") and os.clock() - started < 30 do
		if not (Settings.farmOn and scriptAlive()) then
			return false
		end
		-- Without a rider the bike keeps the airborne flag forever, so waiting for
		-- the landing here would freeze the farm. Stop and put the rider back.
		if not isRiding() then
			lostRider = true
			break
		end
		task.wait(0.1)
	end
	if lostRider or bike:GetAttribute("Airborne") then
		-- Either the rider was thrown off or the bike is still falling after half a
		-- minute: bring it back to the last grounded spot, rider included, and take
		-- the next jump from there.
		bike:PivotTo(CFrame.new(base + Vector3.new(0, 6, 0)) * rotation)
		task.wait(0.5)
		seatUp()
	end

	task.wait(Settings.cooldown)
	drive(1)
	Stats.jumps += 1
	return true
end

local function farmSet(on)
	Settings.farmOn = on
	getgenv().__BikeFarmOn = on

	if not on then
		driveStop()
		releaseKeys()
		Stats.launchPosition = nil
		Stats.launchRotation = nil
		log("Farm off")
		if UiRefs.farm then
			UiRefs.farm:Set(false, true)
		end
		return
	end

	task.spawn(function()
		if not seatUp() then
			log("<Warning>No bike found - spawn one first</Warning>")
			Settings.farmOn = false
			getgenv().__BikeFarmOn = false
			if UiRefs.farm then
				UiRefs.farm:Set(false, true)
			end
			return
		end

		Stats.jumps = 0
		Stats.lastCash = cash()
		Stats.lastSample = os.clock()
		log(string.format("Farm on - jumps of %d studs", Settings.height))

		while Settings.farmOn and scriptAlive() do
			local ok, err = pcall(jumpOnce)
			if not ok then
				log("<Error>Jump: " .. tostring(err) .. "</Error>")
				task.wait(1)
			elseif not Settings.farmOn then
				break
			end
			task.wait(0.05)
		end
	end)

	if UiRefs.farm then
		UiRefs.farm:Set(true, true)
	end
end

----------------------------------------------------------------------
-- 2. AUTO WHEELIE
----------------------------------------------------------------------

--- Throttle burst plus a fresh wheelie press.
local function wheelieCycle(throttle)
	key(Enum.KeyCode.LeftControl, false)
	task.wait(0.05)
	key(Enum.KeyCode.LeftControl, true)
	drive(throttle or 1, 0)
	task.wait(0.45)
	drive(0.2, 0)
	task.wait(0.45)
end

local function wheelieSet(on)
	Settings.wheelieOn = on
	getgenv().__BikeHubWheelie = on

	if on then
		captureAnchor()
		log("Auto wheelie on")
		task.spawn(function()
			while Settings.wheelieOn and scriptAlive() do
				if isRiding() then
					wheelieCycle(1)
					holdAnchor()
				else
					seatUp()
					task.wait(0.2)
				end
			end
			driveStop()
			releaseKeys()
		end)
	else
		driveStop()
		releaseKeys()
		log("Auto wheelie off")
	end

	if UiRefs.wheelie then
		UiRefs.wheelie:Set(on, true)
	end
end

----------------------------------------------------------------------
-- 3. RIDER LOCK
----------------------------------------------------------------------

riderLockSet = function(on)
	Settings.riderLock = on
	getgenv().__BikeHubRiderLock = on
	log(on and "Rider lock on" or "Rider lock off")
	if UiRefs.riderLock then
		UiRefs.riderLock:Set(on, true)
	end
end

----------------------------------------------------------------------
-- 4. PUMPKIN FARM
----------------------------------------------------------------------

--- Real pumpkins only. The map is full of decorative pumpkin models with no body
--- to collect, so the live folder the game keeps for the player is used first and
--- the name scan is only a fallback.
pumpkinList = function()
	local list = {}
	local folder = workspace:FindFirstChild("MyPumpkins")
	if folder then
		for _, child in ipairs(folder:GetChildren()) do
			if child:IsA("Model") and child:FindFirstChild("Body") then
				table.insert(list, child)
			end
		end
	end
	if #list > 0 then
		return list
	end
	local function scan(inst, depth)
		if depth > 4 then
			return
		end
		for _, child in ipairs(inst:GetChildren()) do
			if child:IsA("Model") and child.Name:lower():find("pumpkin") and child:FindFirstChild("Body") then
				table.insert(list, child)
			end
			if not child:IsA("Model") then
				scan(child, depth + 1)
			end
		end
	end
	scan(workspace, 0)
	return list
end

local function pumpkinSet(on)
	Settings.pumpkinFarm = on
	if on then
		task.spawn(function()
			while Settings.pumpkinFarm and scriptAlive() do
				local bike = myBike()
				local list = pumpkinList()
				if bike and #list > 0 then
					local nearest, best
					for _, pumpkin in ipairs(list) do
						local distance = (pumpkin:GetPivot().Position - bike:GetPivot().Position).Magnitude
						if not best or distance < best then
							nearest, best = pumpkin, distance
						end
					end
					if nearest then
						-- Throttle stays open through the hop so the game keeps the
						-- ride alive while the bike is in the air.
						drive(1, 0)
						teleportBike(nearest:GetPivot() * CFrame.new(0, 6, 0))
						task.wait(0.4)
						drive(1, 0)
						task.wait(0.4)
					else
						task.wait(0.5)
					end
				else
					task.wait(1)
				end
			end
		end)
		log("<Warning>Pumpkin farm on (experimental)</Warning>")
	else
		log("Pumpkin farm off")
	end
	if UiRefs.pumpkin then
		UiRefs.pumpkin:Set(on, true)
	end
end

----------------------------------------------------------------------
-- 5 + 6. ESP
----------------------------------------------------------------------

local esp = { player = {}, police = {} }

local function makeEsp(adornee, text, color)
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "BikeHubEsp"
	billboard.Size = UDim2.fromOffset(220, 40)
	billboard.StudsOffsetWorldSpace = Vector3.new(0, 3.5, 0)
	billboard.AlwaysOnTop = true
	billboard.Adornee = adornee
	billboard.Parent = PlayerGui

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextSize = 14
	label.TextColor3 = color
	label.TextStrokeTransparency = 0.4
	label.Text = text
	label.Parent = billboard

	local highlight = Instance.new("Highlight")
	highlight.Name = "BikeHubHighlight"
	highlight.FillColor = color
	highlight.FillTransparency = 0.75
	highlight.OutlineColor = color
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	highlight.Adornee = adornee
	highlight.Parent = PlayerGui

	return { billboard = billboard, highlight = highlight, label = label }
end

local function clearEsp(kind)
	for _, entry in pairs(esp[kind]) do
		if entry.billboard then
			entry.billboard:Destroy()
		end
		if entry.highlight then
			entry.highlight:Destroy()
		end
	end
	esp[kind] = {}
end

local function clearOldEsp()
	for _, child in ipairs(PlayerGui:GetChildren()) do
		if child.Name == "BikeHubEsp" or child.Name == "BikeHubHighlight" then
			child:Destroy()
		end
	end
end
task.spawn(clearOldEsp)

local function refreshPlayerEsp()
	local alive = {}
	local me = bikePosition()
	for _, player in ipairs(Players:GetPlayers()) do
		if player ~= LocalPlayer and player.Character then
			local torso = player.Character:FindFirstChild("HumanoidRootPart") or player.Character:FindFirstChild("Torso")
			if torso then
				alive[torso] = true
				if not esp.player[torso] then
					esp.player[torso] = makeEsp(torso, player.Name, Color3.fromRGB(255, 59, 127))
				end
				local distance = me and math.floor((torso.Position - me).Magnitude) or 0
				esp.player[torso].label.Text = string.format("%s  [%d]", player.Name, distance)
			end
		end
	end
	for torso, entry in pairs(esp.player) do
		if not alive[torso] or not torso.Parent then
			entry.billboard:Destroy()
			entry.highlight:Destroy()
			esp.player[torso] = nil
		end
	end
end

local function refreshPoliceEsp()
	local alive = {}
	local folder = workspace:FindFirstChild("Police")
	if not folder then
		return
	end
	for _, model in ipairs(folder:GetChildren()) do
		if model:IsA("Model") then
			local root = model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
			if root then
				alive[root] = true
				if not esp.police[root] then
					esp.police[root] = makeEsp(root, "POLICE", Color3.fromRGB(70, 140, 255))
				end
			end
		end
	end
	for root, entry in pairs(esp.police) do
		if not alive[root] or not root.Parent then
			entry.billboard:Destroy()
			entry.highlight:Destroy()
			esp.police[root] = nil
		end
	end
end

task.spawn(function()
	while scriptAlive() do
		pcall(function()
			if Settings.playerEsp then
				refreshPlayerEsp()
			elseif next(esp.player) then
				clearEsp("player")
			end
			if Settings.policeEsp then
				refreshPoliceEsp()
			elseif next(esp.police) then
				clearEsp("police")
			end
		end)
		task.wait(0.5)
	end
end)

----------------------------------------------------------------------
-- 7. BIKE TUNING
----------------------------------------------------------------------

local TUNING_DEFAULTS = {
	MaxSpeedKmh = 70,
	LaunchAccel = 4.2,
	PowerPerKg = 45,
	TireGrip = 0.95,
	AirGravity = 50,
	WheelieStrength = 1.1,
	BrakeDecel = 7,
}

-- Keep the chosen values in the executor's shared environment so they survive
-- bike respawns and re-running this hub in the same game session.
local TUNING_VALUES = getgenv().__BikeHubTuningValues
if type(TUNING_VALUES) ~= "table" then
	TUNING_VALUES = {}
	getgenv().__BikeHubTuningValues = TUNING_VALUES
end
for name, defaultValue in pairs(TUNING_DEFAULTS) do
	if type(TUNING_VALUES[name]) ~= "number" then
		TUNING_VALUES[name] = defaultValue
	end
end

local function applyTuningToBike(bike, name, value)
	if bike and bike.Parent and bike:IsA("Model") then
		pcall(function()
			bike:SetAttribute(name, value)
		end)
	end
end

local function applyAllTuning(bike)
	bike = bike or myBike()
	if not bike then
		return false
	end
	for name, value in pairs(TUNING_VALUES) do
		if TUNING_DEFAULTS[name] ~= nil then
			applyTuningToBike(bike, name, value)
		end
	end
	return true
end

-- Save the value even when there is no bike spawned yet. If a bike exists,
-- update it immediately; the saved value is reapplied to the next bike too.
local function applyTuning(name, value)
	if TUNING_DEFAULTS[name] == nil or type(value) ~= "number" then
		return
	end
	TUNING_VALUES[name] = value
	getgenv().__BikeHubTuningValues = TUNING_VALUES
	applyTuningToBike(myBike(), name, value)
end

local function resetTuning()
	for name, value in pairs(TUNING_DEFAULTS) do
		TUNING_VALUES[name] = value
	end
	getgenv().__BikeHubTuningValues = TUNING_VALUES
	applyAllTuning()
	log("Bike tuning reset to defaults; values will stay applied to future bikes")
end

-- A newly spawned bike may receive its Owner attribute slightly after it is
-- parented to Workspace. Check for it briefly, then apply the saved settings.
workspace.ChildAdded:Connect(function(child)
	task.spawn(function()
		for attempt = 1, 12 do
			if not scriptAlive() then
				return
			end
			if child:IsA("Model") and child:GetAttribute("Owner") == LocalPlayer.UserId then
				for _, delayTime in ipairs({ 0, 0.15, 0.5, 1 }) do
					if delayTime > 0 then task.wait(delayTime) end
					if child.Parent and child:GetAttribute("Owner") == LocalPlayer.UserId then
						applyAllTuning(child)
					end
				end
				log("Saved bike tuning applied to spawned bike")
				return
			end
			task.wait(0.1)
		end
	end)
end)

-- Also apply saved values to the bike that already exists when the script starts.
task.spawn(function()
	for _ = 1, 20 do
		if not scriptAlive() then return end
		local bike = myBike()
		if bike then
			applyAllTuning(bike)
			return
		end
		task.wait(0.25)
	end
end)

----------------------------------------------------------------------
-- 8. TELEPORTS
----------------------------------------------------------------------

local LANDMARKS = {
	"HighwayEntery",
	"LongHighway",
	"HighwayRace",
	"HighwayTunnels",
	"MegaRamp",
	"Garage",
	"PumpkinSHop",
	"PumpkinBikeStand",
	"TownRace",
	"BikeDealer",
	"LuxuryStand",
	"VargShowcase",
}

local savedSpots = {}

--- Moves the bike and the rider together. A seated rider rides along with the seat,
--- but an unseated one does not, and the game pulls the bike back to its owner, so
--- the seat is taken first and the move is held for a few ticks.
teleportBike = function(cframe)
	local bike = myBike()
	local char = LocalPlayer.Character
	if not bike then
		if char then
			pcall(function()
				char:PivotTo(cframe)
			end)
		end
		spawnBike()
		return false
	end

	local seat, hum = driverSeat(), humanoid()
	if seat and hum and seat.Occupant ~= hum then
		pcall(function()
			seat:Sit(hum)
		end)
		task.wait(0.1)
	end

	local seated = seat and hum and seat.Occupant == hum
	bike:PivotTo(cframe)
	if char and not seated then
		pcall(function()
			char:PivotTo(cframe * CFrame.new(0, 2.2, 0))
		end)
	end
	for _ = 1, 6 do
		task.wait(0.06)
		if (bike:GetPivot().Position - cframe.Position).Magnitude > 30 then
			bike:PivotTo(cframe)
			if char and not seated then
				pcall(function()
					char:PivotTo(cframe * CFrame.new(0, 2.2, 0))
				end)
			end
		end
	end
	if not isRiding() then
		seatUp()
	end
	return true
end

local function landmarkCFrame(name)
	local model = workspace:FindFirstChild(name)
	if model and model:IsA("Model") then
		return model:GetPivot() * CFrame.new(0, 4, 0)
	end
	return nil
end

----------------------------------------------------------------------
-- WINDOW
----------------------------------------------------------------------

local THEME = {
	Background = Color3.fromHex("#0A0A0C"),
	Surface = Color3.fromHex("#141418"),
	Surface2 = Color3.fromHex("#1A1A20"),
	Surface3 = Color3.fromHex("#2A2A33"),
	Stroke = Color3.fromHex("#26262E"),
	StrokeHover = Color3.fromHex("#3C3C49"),
	Accent = Color3.fromHex("#FF3B7F"),
	AccentDark = Color3.fromHex("#1A0710"),
	Text = Color3.fromHex("#F5F5F7"),
	Muted = Color3.fromHex("#8D8D99"),
}

Airflow.ThemePresets.Robscript = THEME
Airflow:SetDefaultTheme(THEME)

Window = Airflow:CreateWindow({
	Name = "Bike Universe Hub",
	LoadingSubtitle = "farm, tricks, ESP",
	ToggleUIKeybind = "RightControl",
	Size = UDim2.fromOffset(780, 540),
	Backdrop = { Weather = "Fireflies", Tint = 0.35 },
	Theme = THEME,
	ConfigurationSaving = { Enabled = true, FolderName = "BikeUniverseHub" },
	Home = {
		Title = "Bike Universe Hub",
		Welcome = "Welcome back,",
		Tier = "v2.0",
		Stats = { "Players", "Session", "FPS", "Ping", "Game", "Executor" },
	},
})

local LogTab = Window:CreateTab({ Name = "Logs", Icon = "scroll-text" })
local LogBox = LogTab:CreateGroupbox({ Name = "What the script is doing", Side = "Left" })
local LogElement = LogBox:CreateLog({
	Name = "Activity",
	MaxEntries = 300,
	MaxRows = 14,
	Timestamps = true,
	EmptyText = "Nothing yet",
})

log = function(message)
	if LogElement then
		LogElement:Push(tostring(message))
	end
end

----------------------------------------------------------------------
-- FARM TAB (teleport farm only)
----------------------------------------------------------------------

local FarmTab = Window:CreateTab({ Name = "Farm", Icon = "coins" })
local FarmMain = FarmTab:CreateGroupbox({ Name = "Air time farm", Side = "Left" })
local FarmInfo = FarmTab:CreateGroupbox({ Name = "Numbers", Side = "Right" })

UiRefs.farm = FarmMain:CreateToggle({
	Name = "AFK cash farm",
	Desc = "Throws the bike up, keeps the throttle open and lets the fall pay",
	Flag = "FarmOn",
	CurrentValue = false,
	Callback = function(on)
		farmSet(on)
	end,
})

FarmMain:CreateSlider({
	Name = "Jump height",
	Desc = "Higher jump, longer fall, more cash per landing",
	Range = { 80, 500 },
	Increment = 20,
	Suffix = " studs",
	CurrentValue = 300,
	Flag = "JumpHeight",
	Callback = function(value)
		Settings.height = value
	end,
})

FarmMain:CreateSlider({
	Name = "Jump cooldown",
	Desc = "How long the bike stands on the ground before the next jump",
	Range = { 0.2, 3 },
	Increment = 0.1,
	Suffix = " s",
	CurrentValue = 0.6,
	Flag = "JumpCooldown",
	Callback = function(value)
		Settings.cooldown = value
	end,
})

FarmInfo:CreateStatus({
	Name = "Cash",
	Style = "Row",
	Pin = true,
	Update = function()
		return "<Success>" .. short(cash()) .. "</Success>"
	end,
})

FarmInfo:CreateStatus({
	Name = "Per minute",
	Style = "Row",
	Update = function()
		local now = os.clock()
		local delta = cash() - (Stats.lastCash or cash())
		local window = now - (Stats.lastSample or now)
		if window > 5 then
			Stats.perMinute = delta * (60 / window)
			Stats.lastSample = now
			Stats.lastCash = cash()
		end
		return short(Stats.perMinute)
	end,
})

FarmInfo:CreateStatus({
	Name = "Jumps",
	Style = "Row",
	Update = function()
		return tostring(Stats.jumps)
	end,
})

FarmInfo:CreateStatus({
	Name = "Seated",
	Style = "Row",
	Update = function()
		return isRiding() and "<Success>yes</Success>" or "<Muted>no</Muted>"
	end,
})

FarmInfo:CreateParagraph({
	Title = "How it pays",
	Content = "Cash comes from trick lines, and air time is what a line is worth. The farm throws the bike straight up, "
		.. "keeps full throttle on the way down, and the landing closes the line and pays out. A 300 stud jump is about "
		.. "nine seconds of air. Crashes are blocked while the farm runs and the rider is put back on the bike.",
})

----------------------------------------------------------------------
-- BIKE TAB
----------------------------------------------------------------------

local BikeTab = Window:CreateTab({ Name = "Bike", Icon = "bike" })
local BikeMain = BikeTab:CreateGroupbox({ Name = "Assist", Side = "Left" })
local BikeTune = BikeTab:CreateGroupbox({ Name = "Movement", Side = "Right" })
local BikeInfo = BikeTab:CreateGroupbox({ Name = "Status", Side = "Right" })

UiRefs.wheelie = BikeMain:CreateToggle({
	Name = "Auto wheelie",
	Desc = "Holds a wheelie and keeps you on the bike",
	Flag = "Wheelie",
	CurrentValue = false,
	Callback = function(on)
		wheelieSet(on)
	end,
})

UiRefs.riderLock = BikeMain:CreateToggle({
	Name = "No crash / no ragdoll",
	Desc = "The crash call is blocked, so the game cannot throw you off",
	Flag = "RiderLock",
	CurrentValue = false,
	Callback = function(on)
		riderLockSet(on)
	end,
})

BikeMain:CreateButton({
	Name = "Sit on the bike",
	Icon = "bike",
	Callback = function()
		task.spawn(function()
			if seatUp() then
				log("On the bike")
			else
				log("<Warning>No bike nearby - spawn one first</Warning>")
			end
		end)
	end,
})

UiRefs.pumpkin = BikeMain:CreateToggle({
	Name = "Pumpkin farm",
	Desc = "Experimental: hops you onto the nearest pumpkin",
	Flag = "PumpkinFarm",
	CurrentValue = false,
	Callback = function(on)
		pumpkinSet(on)
	end,
})

BikeTune:CreateSlider({
	Name = "Max speed",
	Range = { 40, 260 },
	Increment = 5,
	Suffix = " km/h",
	CurrentValue = TUNING_VALUES.MaxSpeedKmh,
	Flag = "TuneSpeed",
	Callback = function(value)
		applyTuning("MaxSpeedKmh", value)
	end,
})

BikeTune:CreateSlider({
	Name = "Launch accel",
	Range = { 1, 20 },
	Increment = 0.5,
	CurrentValue = TUNING_VALUES.LaunchAccel,
	Flag = "TuneAccel",
	Callback = function(value)
		applyTuning("LaunchAccel", value)
	end,
})

BikeTune:CreateSlider({
	Name = "Power per kg",
	Range = { 10, 200 },
	Increment = 5,
	CurrentValue = TUNING_VALUES.PowerPerKg,
	Flag = "TunePower",
	Callback = function(value)
		applyTuning("PowerPerKg", value)
	end,
})

BikeTune:CreateSlider({
	Name = "Tire grip",
	Range = { 0.2, 2 },
	Increment = 0.05,
	CurrentValue = TUNING_VALUES.TireGrip,
	Flag = "TuneGrip",
	Callback = function(value)
		applyTuning("TireGrip", value)
	end,
})

BikeTune:CreateSlider({
	Name = "Air gravity",
	Range = { 0, 120 },
	Increment = 5,
	CurrentValue = TUNING_VALUES.AirGravity,
	Flag = "TuneAirGravity",
	Callback = function(value)
		applyTuning("AirGravity", value)
	end,
})

BikeTune:CreateSlider({
	Name = "Wheelie strength",
	Range = { 0.2, 4 },
	Increment = 0.1,
	CurrentValue = TUNING_VALUES.WheelieStrength,
	Flag = "TuneWheelie",
	Callback = function(value)
		applyTuning("WheelieStrength", value)
	end,
})

BikeTune:CreateButton({
	Name = "Reset tuning",
	Icon = "rotate-ccw",
	Callback = function()
		resetTuning()
	end,
})

BikeInfo:CreateStatus({
	Name = "Bike",
	Style = "Row",
	Pin = true,
	Update = function()
		local bike = myBike()
		return bike and (bike:GetAttribute("DisplayName") or bike.Name) or "<Muted>none</Muted>"
	end,
})

BikeInfo:CreateStatus({
	Name = "Seated",
	Style = "Row",
	Update = function()
		return isRiding() and "<Success>yes</Success>" or "<Muted>no</Muted>"
	end,
})

BikeInfo:CreateStatus({
	Name = "Wheelie",
	Style = "Row",
	Update = function()
		local bike = myBike()
		if not bike then
			return "<Muted>-</Muted>"
		end
		return bike:GetAttribute("InWheelie") and "<Success>yes</Success>" or "<Muted>no</Muted>"
	end,
})

BikeInfo:CreateStatus({
	Name = "Throttle",
	Style = "Row",
	Update = function()
		return string.format("%.0f%%", (driveState.on and driveState.throttle or 0) * 100)
	end,
})

----------------------------------------------------------------------
-- ESP TAB
----------------------------------------------------------------------

local EspTab = Window:CreateTab({ Name = "ESP", Icon = "eye" })
local EspMain = EspTab:CreateGroupbox({ Name = "Highlight", Side = "Left" })
local EspInfo = EspTab:CreateGroupbox({ Name = "Info", Side = "Right" })

EspMain:CreateToggle({
	Name = "Player ESP",
	Flag = "PlayerEsp",
	CurrentValue = false,
	Callback = function(on)
		Settings.playerEsp = on
		if not on then
			clearEsp("player")
		end
	end,
})

EspMain:CreateToggle({
	Name = "Police ESP",
	Flag = "PoliceEsp",
	CurrentValue = false,
	Callback = function(on)
		Settings.policeEsp = on
		if not on then
			clearEsp("police")
		end
	end,
})

EspInfo:CreateStatus({
	Name = "Players",
	Style = "Row",
	Pin = true,
	Update = function()
		return tostring(#Players:GetPlayers() - 1)
	end,
})

EspInfo:CreateStatus({
	Name = "Police units",
	Style = "Row",
	Update = function()
		local folder = workspace:FindFirstChild("Police")
		return folder and tostring(#folder:GetChildren()) or "0"
	end,
})

----------------------------------------------------------------------
-- TELEPORT TAB
----------------------------------------------------------------------

local TpTab = Window:CreateTab({ Name = "Teleport", Icon = "map-pin" })
local TpMain = TpTab:CreateGroupbox({ Name = "Landmarks", Side = "Left" })
local TpSaved = TpTab:CreateGroupbox({ Name = "Saved spots", Side = "Right" })

local landmarkNames = {}
for _, name in ipairs(LANDMARKS) do
	if workspace:FindFirstChild(name) then
		table.insert(landmarkNames, name)
	end
end

TpMain:CreateDropdown({
	Name = "Where to",
	Options = landmarkNames,
	Flag = "LandmarkPick",
	Callback = function(value)
		local name = type(value) == "table" and value[1] or value
		local cframe = landmarkCFrame(name)
		if cframe then
			teleportBike(cframe)
			log("Teleported to " .. tostring(name))
		else
			log("<Warning>" .. tostring(name) .. " not found</Warning>")
		end
	end,
})

TpMain:CreateButtonRow({
	{
		Name = "Up 50",
		Callback = function()
			local bike = myBike()
			if bike then
				teleportBike(bike:GetPivot() + Vector3.new(0, 50, 0))
			end
		end,
	},
	{
		Name = "Down 50",
		Callback = function()
			local bike = myBike()
			if bike then
				teleportBike(bike:GetPivot() - Vector3.new(0, 50, 0))
			end
		end,
	},
})

local spotName = TpSaved:CreateInput({ Name = "Spot name", PlaceholderText = "ramp", CurrentValue = "spot" })

TpSaved:CreateButton({
	Name = "Save spot",
	Icon = "plus",
	Callback = function()
		local bike = myBike()
		if not bike then
			return
		end
		local name = tostring(spotName:Get())
		savedSpots[name ~= "" and name or "spot"] = bike:GetPivot()
		local names = {}
		for key in pairs(savedSpots) do
			table.insert(names, key)
		end
		table.sort(names)
		UiRefs.spots:SetOptions(names, { KeepSelection = true })
		log("Spot saved")
	end,
})

UiRefs.spots = TpSaved:CreateDropdown({
	Name = "My spots",
	Options = {},
	Flag = "SpotPick",
	Callback = function(value)
		local name = type(value) == "table" and value[1] or value
		if savedSpots[name] then
			teleportBike(savedSpots[name])
			log("Teleported to " .. tostring(name))
		end
	end,
})

TpSaved:CreateButton({
	Name = "Delete spot",
	Icon = "trash-2",
	Callback = function()
		local name = tostring(spotName:Get())
		savedSpots[name] = nil
		local names = {}
		for key in pairs(savedSpots) do
			table.insert(names, key)
		end
		table.sort(names)
		UiRefs.spots:SetOptions(names, { KeepSelection = true })
	end,
})

----------------------------------------------------------------------
-- SETTINGS TAB
----------------------------------------------------------------------

local SettingsTab = Window:CreateTab({ Name = "Settings", Icon = "settings" })
SettingsTab:CreateConfigManager({ Name = "Configs", Side = "Left" })
SettingsTab:CreateThemeManager({ Name = "Theme", Side = "Right" })

local HelpBox = SettingsTab:CreateGroupbox({ Name = "Quick guide", Side = "Right" })
HelpBox:CreateParagraph({
	Title = "Bike Universe Hub",
	Content = "Farm: one mode, the teleport farm - throws the bike up and cashes in the air time.\n"
		.. "Auto wheelie: separate helper, wheelie in place and keeps you on the bike.\n"
		.. "No crash / no ragdoll: the crash call is blocked, so you stay on the bike.\n"
		.. "RightControl hides the window.",
})

----------------------------------------------------------------------
-- Frame loop
----------------------------------------------------------------------

RunService.Heartbeat:Connect(function()
	if not scriptAlive() then
		return
	end
	pcall(riderLockTick)
	-- The farm loop waits between steps, and a throttle that is only re-stamped now
	-- and then drops to zero between those waits, which makes the bike stutter.
	if (Settings.farmOn or Settings.wheelieOn) and driveState.on then
		driveState.last = os.clock()
	end
	if Settings.wheelieOn then
		pcall(holdAnchor)
	end
end)

----------------------------------------------------------------------
-- Start
----------------------------------------------------------------------

task.spawn(function()
	task.wait(1)
	-- A reload must not inherit the drive state of the copy that was running.
	driveStop()
	releaseKeys()
	getgenv().__BikeFarmOn = false
	getgenv().__BikeHubRiderLock = false
	local bike = myBike()
	if bike then
		log("<Success>Loaded</Success> - " .. tostring(bike:GetAttribute("DisplayName") or bike.Name))
	else
		log("<Warning>No bike found - one is spawned when the farm starts</Warning>")
	end
	-- Everything starts off, so a saved config can never leave the farm running
	-- with nobody watching.
	pcall(function()
		for _, tab in ipairs(Window.Tabs or {}) do
			for _, box in ipairs(tab._groupboxes or {}) do
				for _, item in ipairs(box._items or {}) do
					if item._type == "Toggle" and item.Value then
						item:Set(false, true)
					end
				end
			end
		end
	end)
end)

LocalPlayer.CharacterAdded:Connect(function()
	task.wait(1.5)
	if Settings.riderLock or Settings.farmOn or Settings.wheelieOn then
		seatUp()
	end
end)
