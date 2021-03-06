local function GetMaintananceResourcesDropDownItems()
	local ret = table.copy(ResourcesDropDownListItems)
	--rem stuff that cannot be maintanance
	table.remove_entry(ret, "value", nil)
	table.remove_entry(ret, "value", "Water")
	table.remove_entry(ret, "value", "BlackCube")
	table.remove_entry(ret, "value", "Colonist")
	table.remove_entry(ret, "value", "WasteRock")
	
	--add maintanance specific stuff
	table.insert(ret, 1, {text = T{122, "No maintenance"}, value = "no_maintenance"})
	table.insert(ret, 1, {text = T{123, "No resource"}, value = "no_resource"})
	
	return ret
end

--maintanance (aka dust, but slightly different)
--[[@@@
@class RequiresMaintenance
class overview...
--]]
DefineClass.RequiresMaintenance = {
	__parents = { "TaskRequester", "BuildingVisualDustComponent" }, --we use dust visuals to represent accumulated maintenance pnts
	
	properties = {
		{template = true, category = "Maintenance", name = T{124, "Maintenance Resource Type"},  id = "maintenance_resource_type", editor = "dropdownlist", items = GetMaintananceResourcesDropDownItems(), default = GetMaintananceResourcesDropDownItems()[2].value, help = "The type of resource associated with maintenance demands.",},
		{template = true, category = "Maintenance", name = T{125, "Maintenance Resource Amount"},id = "maintenance_resource_amount", editor = "number", scale = const.ResourceScale, default = const.ResourceScale, modifiable = true, help = "The amount of resources required to maintain this building in working order.",},
		{template = true, category = "Maintenance", name = T{126, "Maintenance Threshold"},      id = "maintenance_threshold_base", editor = "number",  default = const.MaxMaintenance, modifiable = true, help = "This base value is randomized within 50% - 150% range to determine the maintenance threshold. When the threshold is reached the building requests maintenance." },
		{template = true, category = "Maintenance", name = T{127, "Maintenance Build Up Per Hr"},id = "maintenance_build_up_per_hr", editor = "number",  default = const.DefaultMaintenanceBuildUpPerHour, modifiable = true, help = "Amount of maintenance pnts accumulated per hr.", no_edit = true, },
		{template = true, id = "disable_maintenance", name = T{128, "Disable Maintenance"}, no_edit = true, modifiable = true, editor = "number", default = 0, help = "So maintenance can be turned off with modifiers"},
	},
	
	
	maintenance_threshold_current = 0, --generated based on _base, actual threshold
	accumulated_maintenance_points = 0, --actual maintance pnts amount atm.
	accumulate_maintenance_points = true, --whether we are currently accumulating pnts. always true in current design
	accumulate_dust = true, --generally, adding dust translates to AccumulateMaintenancePoints, but some special cases (solar, stirling) bld should accum maintenance pnts, but ignore dust accum
	
	last_maintenance_points_accumulation_ts = false, --when we generated maintenance pnts for the last time
	last_enter_maintenance_mode_ts = false, --when last maintenance request began (could be user/auto)
	last_maintenance_points_full_ts = false, --when maintenance pnts reached threshold
	last_maintenance_serviced_ts = false, --when mainenance cycle was completed for the last time.
	
	maintenance_phase = false, --false, "demand", "work"
	maintenance_request_is_highest_prio = false, --when user requests maintenance it should be highest prio
	
	is_malfunctioned = false, --no work possible
	
	maintenance_request_lookup = false,
	maintenance_work_request = false,
	maintenance_resource_request = false,
	
	show_dust_visuals = true, --uses dust visuals to represent maintenance pnts, 0-70% dust visual = 0-100% mnt pnts, 100% dust vis = malfunction
	
	UpdateConsumption = __empty_function__,
}
--[[
--use this override for sync repairing - accumulated_maintenance_points will update as soon as the drone repairing ticks.
--bar is currenlty not visible in this state so this is useless.
function RequiresMaintenance.AddResourceRepairWorkReqOverride(req, add)
	TaskRequest.AddResource(req, add)
	if add < 0 then
		--we are removing work from the req, so rem
		req:GetBuilding().accumulated_maintenance_points = req:GetBuilding().accumulated_maintenance_points + add
	end
end
]]
function GetMaintenancePntsAccumulation(maintenance_accumulation_per_hour, current, max, now, last_update_ts)
	local t_delta = now - last_update_ts
	if t_delta > const.HourDuration then --just don't update when less to avoid rounding down to 0 for vry fast updates
		local accum = MulDivRound(maintenance_accumulation_per_hour, t_delta, const.HourDuration)
		if accum > 0 then
			accum = Min(accum, max - current)
		elseif accum < 0 then
			accum = Max(accum, -current)
		end
		return accum
	end
end

function RequiresMaintenance:GetPriorityForRequest(req)
	if self.maintenance_request_is_highest_prio and self.maintenance_request_lookup[req] then
		return const.MaxBuildingPriority
	else
		return TaskRequester.GetPriorityForRequest(self, req)
	end
end

function RequiresMaintenance:OnModifiableValueChanged(prop)
	if prop == "disable_maintenance" then
		if self.disable_maintenance >= 1 then --no reenabling for now.
			self:DisableMaintenance()
		end
	end
end

function RequiresMaintenance:InitMaintenanceRequests() --init is 2 early, gameinit is 2 late, settemplatename is just right.
	if self.disable_maintenance >= 1 then
		self:DisableMaintenance()
	end
	
	if self:DoesRequireMaintenance() then
		self.maintenance_request_lookup = {}
		self.maintenance_work_request = self:AddWorkRequest("repair", 0, 0, 1)
		self.maintenance_request_lookup[self.maintenance_work_request] = true
		if self:DoesMaintenanceRequireResources() then
			local resource_unit_count = 1 + (self.maintenance_resource_amount / (const.ResourceScale * 10)) --1 per 10
			local r_req = self:AddDemandRequest(self.maintenance_resource_type, 0, 0, resource_unit_count)
			self.maintenance_resource_request = r_req
			self.maintenance_request_lookup[r_req] = true
		end
		
		self:GenerateMaintenanceThreshold()
	else
		self.accumulate_maintenance_points = false
		self.GetPriorityForRequest = g_Classes[self.class].GetPriorityForRequest or TaskRequester.GetPriorityForRequest --flatten
		self.AccumulateMaintenancePoints = __empty_function__
	end
end

function RequiresMaintenance:GameInit()
end

function RequiresMaintenance:Done()
end

function RequiresMaintenance:DoesMaintenanceRequireResources()
	return self:DoesRequireMaintenance() and self.maintenance_resource_type ~= "no_resource" and 
				self.maintenance_resource_amount > 0
end

function RequiresMaintenance:DoesRequireMaintenance()
	return not self.destroyed and self.maintenance_resource_type ~= "no_maintenance"
end

function RequiresMaintenance:BuildingUpdate(delta, day, hour)
	if not self:IsMalfunctioned() then
		if not self.last_maintenance_points_full_ts then --not in maintenance mode
			self:AccumulateMaintenancePoints()
		elseif GameTime() - self.last_maintenance_points_full_ts >= const.DayDuration then
			--should malf within 1 sol
			self:SetMalfunction()
		end
	end
end

function RequiresMaintenance:AddDust(amount)
	--generally, adding dust translates to AccumulateMaintenancePoints, 
	--but some special cases (solar, stirling) bld should accum maintenance pnts, but ignore dust accum.
	--hence the separate method.
	if self:IsKindOf("Building") then
		amount = MulDivRound(amount, g_Consts.BuildingDustModifier, 100)
	end
	if self.accumulate_dust then
		self:AccumulateMaintenancePoints(amount)
	end
end

function RequiresMaintenance:SetAccumulateMaintenancePoints(val)
	if val == self.accumulate_maintenance_points then return end
	--when playing around with this toggle, update the ts as well so that next update doesn't accum the entire missing amount.
	self.accumulate_maintenance_points = val
	if val then
		self.last_maintenance_points_accumulation_ts = GameTime()
	else
		assert(self.maintenance_request_lookup ~= false, "Early accumulate_maintenance_points toggle will prevent maintenance request initialization")
		self.last_maintenance_points_accumulation_ts = false
	end
end

function RequiresMaintenance:DeduceAndReapplyDustVisualsFromState()
	self:SetDustVisualsPerc(self:GetDustPerc())
end

function RequiresMaintenance:AccumulateMaintenancePoints(amount)
	if self.accumulate_maintenance_points then
		--accumulate maintenance pnts.
		local now = GameTime()
		local accum = amount or GetMaintenancePntsAccumulation(self.maintenance_build_up_per_hr, 
																self.accumulated_maintenance_points, self.maintenance_threshold_current,
																now, (self.last_maintenance_points_accumulation_ts or now))
		if accum and accum ~= 0 then
			if not amount then --auto accum, mark it.
				self.last_maintenance_points_accumulation_ts = now
			end
			
			accum = MulDivRound(accum, g_Consts.BuildingMaintenancePointsModifier, 100)
			
			self.accumulated_maintenance_points = Clamp(self.accumulated_maintenance_points + accum, 0, self.maintenance_threshold_current)
			self:SetDustVisualsPerc(self:GetDustPerc())
			
			if self.maintenance_phase and self.maintenance_phase == "work" then --if we are in maintenance phase keep the req in sync
				self.maintenance_work_request:AddAmount(accum)
				if self.maintenance_work_request:GetActualAmount() <= 0 then
					--we got repaired by a scrubber.
					self:Repair()
				end
			end
			
			if self.accumulated_maintenance_points >= self.maintenance_threshold_current then
				self:OnMaintenanceThresholdReached()
			end
		end
	end
end

function RequiresMaintenance:OnMaintenanceThresholdReached()
	self.last_maintenance_points_full_ts = self.last_maintenance_points_full_ts or GameTime()
	if not self.maintenance_phase then --if we havn't requested..
		self:RequestMaintenance()
	end
end

function RequiresMaintenance:StartDemandPhase()
	local req = self.maintenance_resource_request
	req:AddAmount(self.maintenance_resource_amount)
	
	self.maintenance_phase = "demand"
	RebuildInfopanel(self)
end

function RequiresMaintenance:StartWorkPhase(drone)
	self.maintenance_phase = "work"

	if self.accumulated_maintenance_points > 0 then
		local req = self.maintenance_work_request
		req:AddAmount(self.accumulated_maintenance_points)
		if drone then --we've been given a drone by the drone gods.
			drone:SetCommand("Work", req, "repair", Min(g_Consts.DroneBuildingRepairAmount, self.accumulated_maintenance_points))
		end
		RebuildInfopanel(self)
	else
		--probably got scrubbed up by scrubber while waiting for maintenance resource.
		self:Repair()
	end
end

function RequiresMaintenance:GenerateMaintenanceThreshold()
	self.last_maintenance_points_accumulation_ts = GameTime()
	local rand_percent = 80 + self:Random(41)
	self.maintenance_threshold_current = MulDivRound(self.maintenance_threshold_base, rand_percent, 100)
end

function RequiresMaintenance:GetDailyMaintenance(resources)
	local threshold = self.working and self.accumulate_maintenance_points and self.maintenance_threshold_current or 0
	if threshold > 0 then
		local res = self.maintenance_resource_type
		if res ~= "no_maintenance" then
			local points_per_day = MulDivRound(self.maintenance_build_up_per_hr * const.HoursPerDay, g_Consts.BuildingMaintenancePointsModifier, 100)
			local res_per_day = MulDivRound(self.maintenance_resource_amount, points_per_day, threshold)
			resources[res] = (resources[res] or 0) + res_per_day
		end
	end
end

function RequiresMaintenance:GetDustPerc()
	return self.is_malfunctioned and 100 or self.maintenance_threshold_current ~= 0 and MulDivRound(self.accumulated_maintenance_points, 70, self.maintenance_threshold_current) or 0
end

function RequiresMaintenance:SetMalfunction()
	if not self:DoesRequireMaintenance() then return end --blds that do not require maintenance cannot malfunction.
	--we can get called outside of normal flow, (prototypes for example), in which case we need to boot up requests.
	if not self.is_malfunctioned then
		self.is_malfunctioned = true
		self:AttachSign(true, "SignMalfunction")
		self:SetDustVisualsPerc(self:GetDustPerc())

		self:UpdateWorking(false)
		self:UpdateConsumption()
		
		if self.maintenance_phase == false then 
			--We haven't requested maintenance. Hence this is a direct call to break this bld
			self.accumulated_maintenance_points = self.maintenance_threshold_current --max out maint pnts so there is something to repair
			self.last_maintenance_points_full_ts = self.last_maintenance_points_full_ts or GameTime() --mark max out
			self:RequestMaintenance()
		end
		
		RebuildInfopanel(self)
	end
end

--resets maintenance state and malf state as needed.
function RequiresMaintenance:Repair()
	if self.maintenance_phase then --we should be running mainenance if we are malfunctionned. we might not be malfunctionned if we are running maintenance..
		self:ResetMaintenanceState()
	end
	
	if self:IsMalfunctioned() then
		self.is_malfunctioned = false
		self:AttachSign(false, "SignMalfunction")
		self:UpdateWorking() --canwork blockers on our part have been cleared
		self:UpdateConsumption()
	end
	
	RebuildInfopanel(self)
end

function RequiresMaintenance:ResetMaintenanceWorkRequest()
	if self.maintenance_work_request:GetTargetAmount() ~= self.maintenance_work_request:GetActualAmount() then
		self:InterruptDrones(nil, function(drone)
											if drone.command == "Work" and drone.target == self and drone.resource and drone.resource == "repair" then
												return drone --doing our work req
											end
											
											return false
										end)
	end

	self.maintenance_work_request:ResetAmount()
end

function RequiresMaintenance:ResetMaintenanceRequests()
	if not self:DoesRequireMaintenance() or self.maintenance_request_lookup == false then return end --maintenance_request_lookup == false when not initialized, hence nothign to reset
	local should_reset_drones = false
	
	for req, _ in pairs(self.maintenance_request_lookup) do
		should_reset_drones = should_reset_drones or req:GetTargetAmount() ~= req:GetActualAmount()
		req:AddAmount(-req:GetActualAmount())
	end
	
	if should_reset_drones then
		self:InterruptDrones(nil, function(drone)
											if drone.command == "Work" and drone.target == self and drone.resource and drone.resource == "repair" then
												return drone --doing our work req
											elseif drone.d_request and drone.d_request == self.maintenance_resource_request then
												return drone --doing our resource req
											end
											
											return false
										end)
	end
end

function RequiresMaintenance:DisableMaintenance()
	self:ResetMaintenanceRequests() --zero up reqs and interrupt drones
	self.is_malfunctioned = false --so ismalfunctioned returns false when maint is disabled, regardless of the state it was disabled in.
	self.maintenance_resource_type = "no_maintenance" --makes any further maint points application impossible
	self.accumulate_maintenance_points = false
	self:AttachSign(false, "SignMalfunction")
end

function RequiresMaintenance:ResetMaintenanceState()
	assert(self.maintenance_phase ~= false) --what r u resetting?
	
	self:ResetMaintenanceRequests()
	
	if self.maintenance_request_is_highest_prio then --restore req prio
		self.maintenance_request_is_highest_prio = false
		self:DisconnectFromCommandCenters()
		self:ConnectToCommandCenters()
	end
	
	self.maintenance_phase = false
	self.accumulated_maintenance_points = 0
	self.last_maintenance_points_full_ts = false
	self:SetDustVisualsPerc(0)
	self.last_maintenance_serviced_ts = GameTime()
	self:GenerateMaintenanceThreshold()
end

function RequiresMaintenance:UIRequestMaintenance()
	RebuildInfopanel(self)
	return self:RequestMaintenance(true)
end

function RequiresMaintenance:GetUIRequestMaintenanceStatus()
	if self.accumulated_maintenance_points > 0 then
		if self.maintenance_phase == false then
			return T{7329, "Maintenance needed"}
		else
			return T{389, "Maintenance already requested"}
		end
	end
	return T{390, "No deterioration"}
end

function RequiresMaintenance:RequestMaintenance(is_user_requested)
	--if we have resource maintenance, we need to fire up the resource req,
	--if not, we have to fire up the wrk req.
	if self.maintenance_phase == false then
		if self.accumulated_maintenance_points > 0 then --we can request at 0, but it will only get executed when there is @ least 
			self.maintenance_request_is_highest_prio = is_user_requested
			self.last_enter_maintenance_mode_ts = GameTime()
			
			if is_user_requested then
				self:DisconnectFromCommandCenters() --our reqs should now have highest prio, rearrange them
				self:ConnectToCommandCenters()
			end
			
			if self:DoesMaintenanceRequireResources() then
				self:StartDemandPhase()
			else
				self:StartWorkPhase()
			end
		end
	elseif is_user_requested and self.maintenance_request_is_highest_prio ~= is_user_requested then
		self.maintenance_request_is_highest_prio = true
		self:DisconnectFromCommandCenters() --our reqs should now have highest prio, rearrange them
		self:ConnectToCommandCenters()
	end
end

function RequiresMaintenance:MaintenanceDroneUnload(drone, req, resource, amount)
	if req == self.maintenance_resource_request then
		self.city:OnMaintenanceResourceConsumed(resource, amount)
		if req:GetActualAmount() <= 0 then
			--enough resources have been delivered for this phase, start next
			self:StartWorkPhase(drone)
		end
	end
end

function RequiresMaintenance:IsMalfunctioned()
	return self.is_malfunctioned
end

function RequiresMaintenance:DroneWork(drone, request, resource, amount)
	if request == self.maintenance_work_request then
		assert(self.maintenance_phase == "work")

		--amount keeps getting minned, so the drone can correctly assign, meanwhile however the req may have received more work.
		--cont task also mins to protect from negatives, so we should use max possible val
		amount = DroneResourceUnits.repair

		drone:PushDestructor(function(drone)
			if drone.w_request:GetActualAmount() <= 0 then
				--maintenance finished cleanly.
				drone.target:Repair()
			end
		end)

		drone:ContinuousTask(request, amount, g_Consts.DroneBuildingRepairBatteryUse, "repairBuildingStart", "repairBuildingIdle", "repairBuildingEnd", "Repair", 
			function(drone, request)
				if request:GetActualAmount() <= 0 then 
					--drone sleeps after decrementing req amounts, in which time someone can increment it and cause infinite repair.
					--if after decrementing the req is done finish this.
					drone:SetCommand("Idle")
				end
			end)

		drone:PopAndCallDestructor()
	end
end

function RequiresMaintenance:SetDustVisualsPerc(...)
	if self.show_dust_visuals then
		BuildingVisualDustComponent.SetDustVisualsPerc(self, ...)
	end
end

function RequiresMaintenance:GetMaintenanceProgress()
	if self.maintenance_threshold_current == 0 then
		return 0
	end
	return MulDivRound(self.accumulated_maintenance_points, 100, self.maintenance_threshold_current)
end

function RequiresMaintenance:GetLastMaintenance()
	return self.last_maintenance_serviced_ts and T{129, "<n> h", n = (GameTime() - self.last_maintenance_serviced_ts) / const.HourDuration} or T{130, "N/A"}
end

function RequiresMaintenance:OnSetUIWorking(working)
	BaseBuilding.OnSetUIWorking(self, working)
	if not self:DoesRequireMaintenance() then return end
	
	--remove/add maintenance reqs from req stack
	self:InterruptDrones(nil, function(drone)
										if drone.d_request == self.maintenance_work_request or drone.d_request == self.maintenance_resource_request then
											return drone
										end
									 end)
	self:DisconnectFromCommandCenters()
	if working then
		assert(self.maintenance_work_request and self.maintenance_resource_request)
		table.insert(self.task_requests, self.maintenance_work_request)
		table.insert(self.task_requests, self.maintenance_resource_request)
	else
		table.remove_entry(self.task_requests, self.maintenance_work_request)
		table.remove_entry(self.task_requests, self.maintenance_resource_request)
	end
	self:ConnectToCommandCenters()
end