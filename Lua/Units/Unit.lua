DefineClass.Unit =
{
	__parents = { "Movable", "CommandObject", "UngridedObstacle", "DoesNotObstructConstruction", "SyncObject","Renamable" },
	encyclopedia_id = false,
	enum_flags = { efUnit = true, efWalkable = false, efCollision = false, efApplyToGrids = false, efSelectable = true, },
	class_flags = { cfComponentSound = true },
	ShadowBias = "Units",

	fx = false,
	fx_actor = false,
	fx_target = false,
	pfclass = 0,
	goto_target = false,
	holder = false,
	always_renderable = false,
	current_dome = false, -- the dome the unit is physically inside, not "home dome"
	dome_version = 0,
	entrance_type = false, -- means any
	lead_in_out = false,					-- current lead in/out object
	
	visit_door_opened = false,
	visit_end_time = false,
	visit_spot_end_time = false,
	visit_restart = false,
	visit_thread = false,

	direction_arrow_scale = 100,
	init_with_command = "Start",
	
	use_passages = false,
}

function Unit:GameInit()
	if self.init_with_command then
		if type(self.init_with_command) == "table" then
			self:SetCommand(table.unpack(self.init_with_command))
		else
			self:SetCommand(self.init_with_command)
		end
	end
	self:SetHeat(255)
	PlayFX("Spawn", "start", self)
end

function Unit:Done()
	self:StopFX()
	PlayFX("Spawn", "end", self)
	self:SetHolder(false)
end

function Unit:CanBeControlled()
	return false
end

local invalid_obj_pos = point(-1, -1)
function Unit:Gossip(gossip, ...)
	if not netAllowGossip then return end
	NetGossip(self.class, self.handle, IsValid(self) and self:GetPos() or invalid_obj_pos, gossip, GameTime(), ...)
end

function Unit:GossipName()
	return self.class
end

function Unit:Start()
	Sleep(AsyncRand(1000))
end

local Sleep = Sleep
function Unit:MoveSleep(time)
	Sleep(time)
end

function Unit:StartFX(fx, target, actor)
	actor = actor or self
	PlayFX(fx, "start", actor, target)
	self.fx = fx
	self.fx_actor = actor
	self.fx_target = target
end

function Unit:PlayFXMoment(moment)
	if self.fx then
		PlayFX(self.fx, moment, self.fx_actor, self.fx_target)
	end
end

function Unit:StopFX()
	if self.fx then
		PlayFX(self.fx, "end", self.fx_actor, self.fx_target)
		self.fx = false
		self.fx_actor = false
		self.fx_target = false
	end
end

function Unit:OnCommandStart()
	self:StopFX()
	self.goto_target = false
end

function Unit:StartMoving()
end

function Unit:StopMoving()
end

Unit.Step = pf.Step

local pfFinished = const.pfFinished
local pfFailed = const.pfFailed
local pfDestLocked = const.pfDestLocked
local pfTunnel = const.pfTunnel
local pfTeleportDist = 50*guim
function Unit:Goto(...)
	local pfStep = self.Step
	local status = pfStep(self, ...)
	if status < 0 and status ~= pfTunnel then
		return status == pfFinished
	end
	self.goto_target = ...
	self:StartMoving()
	self:PushDestructor(function(self)
		if IsValid(self) then
			self:StopMoving()
			self.goto_target = false
			self:ClearPath()
		end
	end)
	local pfSleep = self.MoveSleep
	while true do
		if status > 0 then
			pfSleep(self, status)
		elseif status == pfTunnel then
			local end_point = pf.GetPathPoint(self, pf.GetPathPointCount(self))
			local tunnel, param = pf.GetTunnel(self:GetPos(), end_point)
			if not tunnel or not tunnel:TraverseTunnel(self, self:GetPos(), end_point, param) then
				self:ClearPath()
				status = pfFailed
				break
			end
		else
			break
		end
		status = pfStep(self, ...)
	end
	self:PopDestructor()
	self:StopMoving()
	self.goto_target = false
	return status == pfFinished
end

function Unit:SetOutside(outside)
end

function Unit:OnEnterDome(dome)
	assert(not self.current_dome or self.current_dome == dome)
	self.current_dome = dome
	self:SetOutside(false)
end

function Unit:OnExitDome(dome)
	assert(not self.current_dome or self.current_dome == dome)
	self.current_dome = false
	self:SetOutside(true)
end

function Unit:WaitDoorOpening(door)
	local time_to_open = door:TimeToOpen()
	if time_to_open > 0 then
		local wait_anim = self:GetWaitAnim()
		self:SetState(wait_anim >= 0 and wait_anim or "idle")
		Sleep(time_to_open)
	end
end

function Unit:KickFromBuilding(building, entrance_type)
	local entrance, pos, spot_type = building:GetEntrance(nil, entrance_type)
	pos = spot_type and building:GetSpotPos(building:GetRandomSpot(spot_type)) or pos or building:GetPos()
	self:SetHolder(false)
	self:Detach()
	self:SetPos(pos)
	building:OnExitUnit(self)
	self:SetCommand("Idle")
end

function Unit:ShowAttachedSigns(shown)
end

function Unit:EnterBuilding(building, entrance_type, spot_name) -- works only if unit/building are both outside or inside the same dome
	if not IsValid(building) or not building:IsValidPos() then
		return false
	elseif self.holder == building then
		return true
	elseif not self:GotoSameDomeAsObj(building) then
		return false
	elseif not IsValid(building) or not building:IsValidPos() then
		--retest after goto.
		return false
	elseif IsKindOf(building, "Dome") then
		return true
	elseif not IsKindOf(building, "WaypointsObj") then
		return false
	end
	local entrance, pos, entrance_spot = building:GetEntrance(self, entrance_type or self.entrance_type, spot_name)
	if entrance_spot then
		local force_place = not self:IsValidPos() or not self:Goto(building, entrance_spot)
		if not IsValid(building) then return false end
		if force_place then
			if self:IsValidPos() then
				self:SetPos(building:GetSpotPos(building:GetNearestSpot(entrance_spot, self)))
			else
				self:SetPos(building:GetSpotPos(building:GetRandomSpot(entrance_spot)))
			end
		end
		building:OnEnterUnit(self)
		return true
	end
	if pos then
		if not self:IsValidPos() or not IsCloser2D(self, pos, guim/2) and not self:Goto_NoDestlock(pos) then
			self:SetPos(pos)
		end
	end
	assert(entrance, "Building without entrance: " .. tostring(ObjectClass(building)))
	if entrance and IsValid(building) then
		building:LeadIn(self, entrance)
		return true
	end
end

function Unit:ExitBuilding(building, target, entrance_type, spot_name)
	building = building or self.holder
	if not IsValid(building) or not IsKindOf(building, "WaypointsObj") then return end
	assert(building:IsValidPos())
	if not building:IsValidPos() then
		return
	end
	local entrance, pos, entrance_spot = building:GetEntrance(target or self, entrance_type or self.entrance_type, spot_name)
	if entrance_spot then
		if not self:IsValidPos() then
			if IsValid(target) then
				self:SetPos(building:GetSpotPos(building:GetNearestSpot(entrance_spot, target)))
			else
				self:SetPos(building:GetSpotPos(building:GetRandomSpot(entrance_spot)))
			end
		end
		building:OnExitUnit(self)
		return true
	end
	assert(entrance, "Building without entrance: " .. tostring(ObjectClass(building)))
	if not entrance then
		return
	end
	building:LeadOut(self, entrance)
	return true
end

local StockpileEnterExitDomeOffset = point(0, 0, -80)

local function EnterExitDome(self, dome, target, enter)
	if not IsValid(dome) or not dome:IsValidPos() then
		return false
	end
	local dome_entrance = FindNearestObject(dome.dome_entrances, enter and (self:IsValidPos() and self or self.holder) or target)
	assert(dome_entrance, "Dome has no entrance")
	local entrance, pos = dome_entrance:GetEntrance(self, nil, enter and "Doorentrance1" or "Doorentrance2")
	assert(entrance, "Dome without entrance chains")

	if self.holder then
		self:ExitBuilding(self.holder, pos)
		if not IsValid(dome) then
			return false
		end
	end
	if not self:IsValidPos() or not self:Goto_NoDestlock(pos) then
		if not IsValid(dome) or enter then
			-- fail if can't enter the dome
			self:OnEnterDomeFail(dome)
			return false
		end
		self:SetPos(pos) -- teleport if can't exit the dome
		if entrance and #entrance > 1 then
			self:Face(entrance[#entrance-1], 0)
		end
	end
	if not IsValid(dome) then
		return false
	end

	--move carried box so it doesnt collide with dome entrance
	local box = self:GetAttach("ResourceStockpileBox")
	if box then
		box:SetAttachOffset(StockpileEnterExitDomeOffset)
	end

	self:PushDestructor(function(self)
		local box = self:GetAttach("ResourceStockpileBox")
		if box then
			box:SetAttachOffset(point30)
		end
		if self:IsValidPos() and self.safe_pos_on_failure then
			self:SetPos(self.safe_pos_on_failure)
			self.safe_pos_on_failure = false
		end
	end)

	if not IsValid(dome_entrance) then
		-- dome skin changed (entrance autoattach is replaced)
		dome_entrance = FindNearestObject(dome.dome_entrances, pos)
		entrance, pos = dome_entrance:GetEntrance(self, nil, enter and "Doorentrance1" or "Doorentrance2")
	end
	self.safe_pos_on_failure = entrance[#entrance]
	dome:LeadIn(self, entrance)

	if not IsValid(dome) then
		self.safe_pos_on_failure = false
		self:PopAndCallDestructor()
		if self:IsValidPos() then
			self:SetPos(self:GetVisualPos2D())
		end
		return false
	end

	if enter then
		self:OnEnterDome(dome)
	else
		self:OnExitDome(dome)
	end

	if not IsValid(dome_entrance) then
		-- dome skin changed (entrance autoattach is replaced)
		dome_entrance = FindNearestObject(dome.dome_entrances, pos)
	end
	entrance, pos = dome_entrance:GetEntrance(self, nil, enter and "Doorexit1" or "Doorexit2")
	self.safe_pos_on_failure = entrance[#entrance]
	dome:LeadOut(self, entrance)
	self.safe_pos_on_failure = false
	self:PopDestructor()
	local box = self:GetAttach("ResourceStockpileBox")
	if box then
		box:SetAttachOffset(point30)
	end
	
	assert(enter and self.current_dome == dome or not enter and not self.current_dome)
	
	return true
end

-- recalc current dome when exit from outside buildings. We need to recalc current dome when the building's exit is too close to any dome.
function Unit:ValidateCurrentDomeOnExit(building)
	if not IsObjInDome(building) then
		self.dome_version = 0
	end
end

function Unit:CalcCurrentDome()
	if self.dome_version == g_DomeVersion then
		return self.current_dome
	end
	self.dome_version = g_DomeVersion
	local dome, pos
	if self.holder then
		dome = IsObjInDome(self.holder)
	elseif self:IsValidPos() then
		pos = GetPassablePointNearby(GetTopmostParent(self):GetPos(), self.pfclass)
	end
	dome = dome or pos and GetDomeAtPoint(pos) or false
	if self:TimeToPosInterpolationEnd() > 0 and pos and GetDomeAtPoint(self:GetVisualPos2D()) ~= dome then
		self:SetPos(pos)
	end
	if self.current_dome ~= dome then
		if self.current_dome then
			self:OnExitDome(self.current_dome)
		end
		if dome then
			self:OnEnterDome(dome)
		end
	end
	return dome
end

function AreDomesConnectedWithPassageDeep() end

-- goes inside the same dome as obj, or outside domes if obj is not in a dome
function Unit:GotoSameDomeAsObj(obj)
	local obj_dome = IsPoint(obj) and GetDomeAtPoint(obj) or IsObjInDome(obj) or IsKindOf(obj, "Dome") and obj or false
	local unit_dome = self:CalcCurrentDome()

	if unit_dome == obj_dome then
		self:ExitBuilding(self.holder, obj)
		return true
	end
	
	if self.use_passages then
		local conn, through_dome = AreDomesConnectedWithPassageDeep(unit_dome, obj_dome)
		--we need a pnt to go to, go to the passage exit in dest dome closest to us
		if conn then
			local my_pos = self:GetPos()
			local exits = obj_dome.passage_exits[through_dome]
			local best_pos
			for i = 1, #exits do
				if not best_pos or IsCloser2D(my_pos, exits[i], best_pos) then
					best_pos = exits[i]
				end
			end
			return self:Goto(best_pos)
		end
	end

	if unit_dome and obj_dome then
		-- !!! long range transportation of units between domes
	end
	local success = true
	if unit_dome and (IsPoint(obj) or IsValid(obj)) then
		success = EnterExitDome(self, unit_dome, obj, false) -- exit
	end
	if obj_dome and (IsPoint(obj) or IsValid(obj)) then
		success = EnterExitDome(self, obj_dome, obj, "enter") -- enter
	end
	return success
end

function Unit:OnEnterDomeFail(dome)
end

function Unit:GotoUnitSpot(unit, spot)
	-- pathfinding failure shields
	if IsValid(unit) and self:GotoSameDomeAsObj(unit) and IsValid(unit) and self:Goto(unit, spot) then 
		return true
	end
	if not IsValid(unit) then
		return false
	end
	if unit:GetDist2D(self) - unit:GetRadius() - self:GetRadius() < 5*guim then return true end
	local pt = GetPassablePointNearby(unit:GetPos(), self.pfclass)
	if self:Goto(pt) and IsValid(unit) then return true end
	Sleep(1000)
end

function Unit:GotoBuildingSpot(building, spot, force_teleport)
	if not IsValid(building) then
		return false
	end
	
	local goto_args = building:HasMember("destroyed") and building.destroyed and building.orig_state and spot and building.orig_state[spot] and {building.orig_state[spot]} or {building, spot}
	local begin_idx = spot and building:GetSpotBeginIndex("idle", spot) or -1
	local success
	if IsKindOf(building, "Dome") then
		local idx = spot and building:GetNearestSpot("idle", spot, self)
		local dome_at_pos = false
		if idx then
			local spot_pos = GetPassablePointNearby(#goto_args == 2 and building:GetSpotLoc(idx) or goto_args[1][idx - begin_idx + 1], self.pfclass)
			dome_at_pos = GetDomeAtPoint(spot_pos)
		else
			dome_at_pos = building --first passable around origin will be inside
		end
		success = self:GotoSameDomeAsObj(dome_at_pos)
	else
		success = self:GotoSameDomeAsObj(building)
	end
	if not success or not IsValid(building) then
		return false
	end
	
	local result = self:Goto(table.unpack(goto_args))
	
	if not result then
		-- if can't reach a free spot then allow colliding with other units
		result = IsValid(building) and self:Goto_NoDestlock(table.unpack(goto_args))
	end
	if not IsValid(building) then
		return false
	end
	local idx = spot and building:GetNearestSpot("idle", spot, self)
	if not result then
		local spot_pos = (#goto_args == 2 or not idx) and building:GetSpotPos(idx or -1) or goto_args[1][idx - begin_idx + 1]
		if self:GetDist(spot_pos) > 2*guim then
			return false
		end
	end
	if idx then
		local angle = building:GetSpotRotation(idx)
		self:SetAngle(angle, 100)
	else
		self:Face(building, 100)
	end
	return true
end

function Unit:GoToRandomPosInDome(dome)
	assert(dome)
	if not dome then
		return
	end
	local pts = dome.walkable_points
	local idx = self:Random(1, #pts)
	if not self:IsValidPos() then
		self:SetPos(pts[idx])
		return
	end
	self:Goto(pts[idx])
end

function Unit:GetRandomPos(max_radius, min_radius, center, retries, filter)
	retries = retries or 25
	center = center or self:GetVisualPos()
	min_radius = min_radius or 0
	local mw, mh = terrain.GetMapSize()
	if center == InvalidPos() then
		center = point(mw / 2, mh / 2)
	end
	for j = 1, retries do
		local x, y = RotateRadius(min_radius + self:Random(max_radius - min_radius), self:Random(360 * 60), center, true)
		x = Clamp(x, guim, mw - guim)
		y = Clamp(y, guim, mh - guim)
		if terrain.IsPassable(x, y) and (not filter or filter(x, y)) then
			return point(x, y)
		end
	end
end

function Unit:GoToRandomPos(max_radius, min_radius, center, retries, filter)
	local pt = self:GetRandomPos(max_radius, min_radius, center, retries, filter)
	if pt then
		return self:Goto(pt)
	end
end

function Unit:ExitImpassable()
	local pt = GetPassablePointNearby(self:GetVisualPos(), self.pfclass)
	self:Goto(pt)
end

function Unit:Trace(...)
	if config.TraceEnabled then
		print(...)
	end	
end

function Unit:UpdateUI()
	if self == SelectedObj then
		Msg("UIPropertyChanged", self)
	end
end

function Unit:IsInDome()
	return IsObjInDome(self)
end

function Unit:SetHolder(building)
	local holder = self.holder
	building = building or false
	if holder == building or building and not building:IsKindOf("Holder") then
		return
	end
	if holder then
		holder:OnExitHolder(self)
	end
	self.holder = building
	if building then
		building:OnEnterHolder(self)
	end
	assert(self.holder or self:IsValidPos())
end

function Unit:UpdateEntity()
end

--represents the shape a unit is currently obstucting, for large units.
function Unit:GetRotatedShapePoints()
	if pathfind[self.pfclass + 1].large then
		return UngridedObstacle.GetRotatedShapePoints(self)
	end
	
	return FallbackOutline
end

function Unit:StartAlwaysRender(reason)
	if not self.always_renderable then
		if self:GetGameFlags(const.gofAlwaysRenderable) ~= 0 then
			return
		end
		self.always_renderable = {}
	end
	if next(self.always_renderable) == nil then
		self:SetGameFlags(const.gofAlwaysRenderable)
	end
	self.always_renderable[reason] = true	
end

function Unit:StopAlwaysRender(reason)
	if not self.always_renderable then
		return
	end
	self.always_renderable[reason] = nil
	if next(self.always_renderable) == nil then
		self:ClearGameFlags(const.gofAlwaysRenderable)
		self.always_renderable = nil
	end
end

function Unit:InterruptCommand()
	if self:InterruptVisit() then
		return
	end
	self:SetCommand("Idle")
end

function Unit:IsVisitingBuilding()
	if self.lead_in_out or self.visit_end_time then
		return true
	end
	return false
end

function Unit:InterruptVisit()
	if not self.visit_end_time then
		return
	end
	self.visit_end_time = GameTime() -- mark the visit as finished
	Wakeup(self.visit_thread)
	return true
end

function Unit:VisitTimeLeft()
	local time = 0
	if self.visit_end_time then
		time = self.visit_end_time - GameTime()
	end
	if time > 0 and self.visit_spot_end_time then
		time = Clamp(GameTime() - self.visit_spot_end_time, 0, time)
	end
	return time > 0 and time or 0
end

function Unit:WaitVisitEnd()
	repeat
		local wait = self:VisitTimeLeft()
	until self.visit_restart or wait <= 0 or not WaitWakeup(wait)
end

function Unit:PlayPrg(prg, duration, ...)
	self.visit_end_time = GameTime() + duration
	self.visit_spot_end_time = false
	self.visit_thread = CurrentThread()
	-- execute prg in the destructor to make it uninterruptible
	self:PushDestructor(function(self)
		self.visit_end_time = false
		self.visit_spot_end_time = false
		self.visit_restart = false
		self.visit_thread = false
	end)
	if not prg then
		self:DetachFromMap()
		self:SetOutside(false)
	end
	while self:VisitTimeLeft() > 0 do
		self.visit_restart = false
		if prg then
			local prg_start_time = GameTime()
			prg(self, ...)
			if GameTime() - prg_start_time == 0 then
				WaitWakeup(Min(5000, self:VisitTimeLeft()))
			end
		else
			self:WaitVisitEnd() -- interrupted from visit_restart
		end	
	end
	self:PopAndCallDestructor()
end

function Unit:GotoFromUser(...) --goto and dome handling in one
	self:GotoSameDomeAsObj(...)
	self:Goto(...)
end

function Unit:IsDead()
	return IsValid(self)
end

----- Vehicle

DefineClass.Vehicle = {
	__parents = { "Unit" },
	game_flags = { gofSpecialOrientMode = true },
	orient_mode = "terrain",
}

function dbg_ShowMeAllSpots(obj, ss)
	local s_idx = obj:GetSpotBeginIndex(ss)
	local e_idx = obj:GetSpotEndIndex(ss)
	
	for i = s_idx, e_idx do
		ShowMe(obj:GetSpotPos(i))
	end
end
