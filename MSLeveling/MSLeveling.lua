local ADDON_NAME = "MSLeveling"
local PREFIX = "|cff66b3ff[MSL]|r "
local REPLY_HELP = "Hello! This is the MS-Leveling addon by Bokuden (https://github.com/BokudenWow/MS-Leveling). To sign up, whisper your role and whether you have aura, e.g. 'tank with aura', 'heal without aura' or 'dps'. You'll be added to the candidate list automatically."
local REPLY_OK = "Automatically added to the candidate list. Bokuden blesses you!"

MSLevelingDB = MSLevelingDB or {}
local db = MSLevelingDB

db.channels = db.channels or { 1, 8, 0 }
db.me = db.me or {}
if db.autoReply == nil then
	db.autoReply = true
end

local MAX_TANK, MAX_HEAL, MAX_DPS, MAX_AURA, MAX_TOTAL = 2, 3, 10, 3, 15
local ROW_HEIGHT = 22
local ROWS_CAND = 8
local ROWS_INV = 9

local CANDIDATES = {}
local INVITED = {}

local ROLE_CYCLE = { Tank = "Heal", Heal = "DPS", DPS = "?", ["?"] = "Tank" }
local ROLE_COLORS = {
	Tank = { 1.0, 0.6, 0.3 },
	Heal = { 0.3, 1.0, 0.5 },
	DPS = { 1.0, 0.85, 0.2 },
	["?"] = { 0.7, 0.7, 0.7 },
}

local f, counts, selfRow, selfRoleText, selfAuraText, candScroll, candRows, invScroll, invRows, finishBtn, title
local HandleWhisper, RefreshStatus, RefreshSelf, PositionMinimap, HandleRaidChat, CleanLeavers, SortGroups

local collecting = false
local memberReplies = {}
local pendingSort = false
local sortRunning = false
local sortElapsed = 0
local sortTickFrame

local addon = CreateFrame("Frame")
addon:RegisterEvent("CHAT_MSG_WHISPER")
addon:RegisterEvent("CHAT_MSG_RAID")
addon:RegisterEvent("CHAT_MSG_RAID_WARNING")
addon:RegisterEvent("CHAT_MSG_PARTY")
addon:RegisterEvent("GROUP_ROSTER_UPDATE")
addon:RegisterEvent("PLAYER_REGEN_ENABLED")
addon:RegisterEvent("PLAYER_LOGIN")
addon:SetScript("OnEvent", function(self, event, ...)
	if event == "CHAT_MSG_WHISPER" then
		if HandleWhisper then
			HandleWhisper(...)
		end
	elseif event == "CHAT_MSG_RAID" or event == "CHAT_MSG_RAID_WARNING" or event == "CHAT_MSG_PARTY" then
		if HandleRaidChat then
			HandleRaidChat(...)
		end
	elseif event == "GROUP_ROSTER_UPDATE" then
		if RefreshStatus then
			RefreshStatus()
		end
	elseif event == "PLAYER_REGEN_ENABLED" then
		if pendingSort then
			pendingSort = false
			if SortGroups then
				SortGroups()
			end
		end
	elseif event == "PLAYER_LOGIN" then
		if db.framePos and type(db.framePos) == "table" and f then
			f:ClearAllPoints()
			f:SetPoint("TOPLEFT", UIParent, "TOPLEFT", db.framePos[1], db.framePos[2])
		end
		if PositionMinimap then
			PositionMinimap()
		end
		if RefreshSelf then
			RefreshSelf()
		end
	end
end)

sortTickFrame = CreateFrame("Frame", "MSLvlingSortTick")

local function HasWord(m, w)
	if not m:find(w, 1, true) then
		return false
	end
	if m == w then
		return true
	end
	if m:find("%A" .. w .. "%A") then
		return true
	end
	if m:find("^" .. w .. "%A") then
		return true
	end
	if m:find("%A" .. w .. "$") then
		return true
	end
	if #w >= 3 then
		return true
	end
	return false
end

local function DetectRole(m)
	if HasWord(m, "tank") or HasWord(m, "tanque") or HasWord(m, "tanq") then
		return "Tank"
	end
	if HasWord(m, "heal") or HasWord(m, "healer") or HasWord(m, "sanador") or HasWord(m, "cura") or HasWord(m, "curar") or HasWord(m, "curacion") then
		return "Heal"
	end
	if HasWord(m, "dps") or HasWord(m, "dd") or HasWord(m, "dano") then
		return "DPS"
	end
	return nil
end

local function DetectAura(m)
	local mentions = HasWord(m, "aura") or HasWord(m, "buff")
	if not mentions then
		return nil
	end
	local neg = HasWord(m, "no") or HasWord(m, "sin") or HasWord(m, "without") or HasWord(m, "wout")
	return not neg
end

local function HasNum(m, n)
	if m == n then
		return true
	end
	if m:find("%D" .. n .. "%D") then
		return true
	end
	if m:find("^" .. n .. "%D") then
		return true
	end
	if m:find("%D" .. n .. "$") then
		return true
	end
	return false
end

local function ParseNumbers(m)
	local t = HasNum(m, "1")
	local h = HasNum(m, "2")
	local a = HasNum(m, "3")
	if t and h then
		return nil, a
	end
	if t then
		return "Tank", a
	end
	if h then
		return "Heal", a
	end
	return nil, a
end

local function MergeReply(name, role, aura)
	local rep = memberReplies[name]
	if not rep then
		memberReplies[name] = { role = role or "DPS", aura = aura }
		return
	end
	if role then
		rep.role = role
	end
	if aura ~= nil then
		rep.aura = aura
	end
end

local function GetCounts()
	local t, h, d, a = 0, 0, 0, 0
	if db.me.role == "Tank" then
		t = t + 1
	elseif db.me.role == "Heal" then
		h = h + 1
	elseif db.me.role == "DPS" then
		d = d + 1
	end
	if db.me.aura then
		a = a + 1
	end
	for _, inv in ipairs(INVITED) do
		if inv.role == "Tank" then
			t = t + 1
		elseif inv.role == "Heal" then
			h = h + 1
		elseif inv.role == "DPS" then
			d = d + 1
		end
		if inv.aura then
			a = a + 1
		end
	end
	return t, h, d, a, 1 + #INVITED
end

local function FindCandidate(name)
	for i, v in ipairs(CANDIDATES) do
		if v.name == name then
			return i, v
		end
	end
end

local function FindInvited(name)
	for _, v in ipairs(INVITED) do
		if v.name == name then
			return v
		end
	end
end

local function RefreshCandidates()
	local num = #CANDIDATES
	FauxScrollFrame_Update(candScroll, num, ROWS_CAND, ROW_HEIGHT)
	local offset = FauxScrollFrame_GetOffset(candScroll)
	for i = 1, ROWS_CAND do
		local row = candRows[i]
		local d = CANDIDATES[offset + i]
		if d then
			row:Show()
			row.data = d
			row.name:SetText(d.name)
			row.roleText:SetText(d.role or "?")
			local c = ROLE_COLORS[d.role or "?"]
			row.roleText:SetTextColor(c[1], c[2], c[3])
			row.auraText:SetText(d.aura == nil and "?" or (d.aura and "Aura" or "No"))
			if d.aura then
				row.auraText:SetTextColor(0.3, 1.0, 0.5)
			elseif d.aura == nil then
				row.auraText:SetTextColor(0.7, 0.7, 0.7)
			else
				row.auraText:SetTextColor(0.8, 0.8, 0.8)
			end
		else
			row:Hide()
			row.data = nil
		end
	end
end

local function RefreshInvited()
	local num = #INVITED
	FauxScrollFrame_Update(invScroll, num, ROWS_INV, ROW_HEIGHT)
	local offset = FauxScrollFrame_GetOffset(invScroll)
	for i = 1, ROWS_INV do
		local row = invRows[i]
		local d = INVITED[offset + i]
		if d then
			row:Show()
			row.data = d
			row.name:SetText(d.name)
			row.roleText:SetText((d.role == "Tank" and "MT") or (d.role or "?"))
			local c = ROLE_COLORS[d.role or "?"]
			row.roleText:SetTextColor(c[1], c[2], c[3])
			row.auraText:SetText(d.aura == nil and "?" or (d.aura and "Aura" or "No"))
			if d.aura then
				row.auraText:SetTextColor(0.3, 1.0, 0.5)
			elseif d.aura == nil then
				row.auraText:SetTextColor(0.7, 0.7, 0.7)
			else
				row.auraText:SetTextColor(0.8, 0.8, 0.8)
			end
			if d.status == "Joined" then
				row.status:SetText("In group")
				row.status:SetTextColor(0.3, 1.0, 0.5)
			else
				row.status:SetText("Pending")
				row.status:SetTextColor(1.0, 0.9, 0.3)
			end
		else
			row:Hide()
			row.data = nil
		end
	end
end

local function CountColor(cur, max)
	if cur >= max then
		return "ff5c5c"
	end
	return "7dff7d"
end

local function RefreshCounts()
	local t, h, d, a, tot = GetCounts()
	counts:SetFormattedText(
		"|cff66b3ffTanks|r |cff%s%d/2|r   |cff66b3ffHeals|r |cff%s%d/3|r   |cff66b3ffDPS|r |cff%s%d/10|r   |cff66b3ffAuras|r |cff%s%d/3|r   |cff66b3ffTotal|r |cff%s%d/15|r",
		CountColor(t, 2), t, CountColor(h, 3), h, CountColor(d, 10), d, CountColor(a, MAX_AURA), a, CountColor(tot, 15), tot
	)
end

function RefreshSelf()
	local pname = UnitName("player") or "?"
	selfRow.name:SetText("You: " .. pname)
	selfRoleText:SetText((db.me.role == "Tank" and "MT") or (db.me.role or "?"))
	local c = ROLE_COLORS[db.me.role or "?"]
	selfRoleText:SetTextColor(c[1], c[2], c[3])
	selfAuraText:SetText(db.me.aura == nil and "?" or (db.me.aura and "Aura" or "No"))
	if db.me.aura then
		selfAuraText:SetTextColor(0.3, 1.0, 0.5)
	elseif db.me.aura == nil then
		selfAuraText:SetTextColor(0.7, 0.7, 0.7)
	else
		selfAuraText:SetTextColor(0.8, 0.8, 0.8)
	end
end

local function RefreshAll()
	RefreshSelf()
	RefreshCounts()
	RefreshCandidates()
	RefreshInvited()
	if finishBtn then
		finishBtn:SetEnabled(collecting)
	end
	if title then
		title:SetText("|cff66b3ffMS Leveling|r - Addon by Bokuden" .. (collecting and " |cff7dff7dCollecting...|r" or ""))
	end
end

local function InvitePlayer(name)
	if FindInvited(name) then
		return
	end
	local idx, cand = FindCandidate(name)
	if not cand then
		return
	end
	table.remove(CANDIDATES, idx)
	table.insert(INVITED, { name = name, role = cand.role or "?", aura = cand.aura, status = "Pending" })
	local ok = pcall(InviteUnit, name)
	if ok then
		print(PREFIX .. "Invited " .. name .. " (" .. (cand.role or "?") .. (cand.aura and " - Aura" or "") .. ")")
	else
		print(PREFIX .. "Could not invite " .. name)
	end
	RefreshAll()
end

function LoadRaid()
	if not IsInRaid() then
		print(PREFIX .. "You are not in a raid.")
		return
	end
	wipe(CANDIDATES)
	wipe(INVITED)
	wipe(memberReplies)
	collecting = true
	SendChatMessage("MSLeveling: reply with '1' Tank, '2' Heal, '3' Aura (e.g. '1 3'). No reply = DPS without aura.", "RAID_WARNING")
	RefreshAll()
	RefreshMTButtons()
	print(PREFIX .. "Raid started: reply in raid chat with 1 (Tank), 2 (Heal), 3 (Aura), e.g. '1 3'. Press 'Finish Count' when everyone has replied.")
end

local function FinalizeCollect()
	if not collecting then
		return
	end
	collecting = false
	wipe(INVITED)
	local pname = UnitName("player")
	local count = 0
	if IsInRaid() then
		for i = 1, GetNumRaidMembers() do
			local name = GetRaidRosterInfo(i)
			if name then
				name = name:gsub("%-.*", "")
				if name ~= pname then
					local rep = memberReplies[name]
					table.insert(INVITED, {
						name = name,
						role = rep and rep.role or "DPS",
						aura = rep and rep.aura or false,
						status = "Joined",
					})
					count = count + 1
				end
			end
		end
	end
	if count == 0 then
		print(PREFIX .. "No raid members to collect.")
		RefreshAll()
		return
	end
	wipe(memberReplies)
	local t, h, d, a = GetCounts()
	SendChatMessage(string.format("MSLeveling: Group ready: {circle}%d Tank {square}%d Heal {skull}%d DPS {triangle}%d Aura", t, h, d, a), "RAID")
	local tanks, heals, auras = {}, {}, {}
	local pn = UnitName("player") or "?"
	if db.me.role == "Tank" then
		table.insert(tanks, pn)
	end
	if db.me.role == "Heal" then
		table.insert(heals, pn)
	end
	if db.me.aura then
		table.insert(auras, pn)
	end
	for _, inv in ipairs(INVITED) do
		if inv.role == "Tank" then
			table.insert(tanks, inv.name)
		end
		if inv.role == "Heal" then
			table.insert(heals, inv.name)
		end
		if inv.aura then
			table.insert(auras, inv.name)
		end
	end
	SendChatMessage("MSLeveling: {circle}Tanks: " .. (#tanks > 0 and table.concat(tanks, ", ") or "none"), "RAID")
	SendChatMessage("MSLeveling: {square}Heals: " .. (#heals > 0 and table.concat(heals, ", ") or "none"), "RAID")
	SendChatMessage("MSLeveling: {triangle}Auras: " .. (#auras > 0 and table.concat(auras, ", ") or "none"), "RAID")
	print(PREFIX .. string.format("Raid collected: %d players (DPS without aura by default).", count))
	RefreshAll()
	RefreshMTButtons()
end

local function ResetAll()
	wipe(CANDIDATES)
	wipe(INVITED)
	print(PREFIX .. "List reset.")
	RefreshAll()
end

local function BroadcastLFM()
	local t, h, d, a = GetCounts()
	local msg = string.format("LFM MS Leveling: {circle}Tank %d/2 {square}Heal %d/3 {skull}DPS %d/10 {triangle}Aura %d/3 - reply role + aura/no", t, h, d, a)
	local preview = string.format(
		"|cffffd000[MS Leveling]|r |cff66b3ffLFM|r MS Leveling: {circle}|cff66b3ffTank|r |cff%s%d/2|r {square}|cff66b3ffHeal|r |cff%s%d/3|r {skull}|cff66b3ffDPS|r |cff%s%d/10|r {triangle}|cff66b3ffAura|r |cff%s%d/3|r |cff66b3ffreply role + aura/no|r",
		CountColor(t, 2), t,
		CountColor(h, 3), h,
		CountColor(d, 10), d,
		CountColor(a, MAX_AURA), a
	)
	local sent = 0
	local failed = {}
	local channelNames = {}
	local joined = {}
	for i = 1, 50 do
		local name, num = GetChannelList(i)
		if not name then
			break
		end
		channelNames[num] = name
		table.insert(joined, name .. " (" .. num .. ")")
	end
	for i = 1, 3 do
		local ch = db.channels[i]
		if ch and ch > 0 then
			local ok = pcall(SendChatMessage, msg, "CHANNEL", nil, ch)
			if ok then
				sent = sent + 1
			else
				table.insert(failed, tostring(ch) .. (channelNames[ch] and (" (" .. channelNames[ch] .. ")") or ""))
			end
		end
	end
	if sent == 0 and #failed > 0 then
		print(PREFIX .. "LFM not sent: channel" .. (#failed > 1 and "s" or "") .. " " .. table.concat(failed, ", ") .. " failed. Make sure you are joined to them (channel buttons).")
		print(PREFIX .. "Your joined channels: " .. (#joined > 0 and table.concat(joined, ", ") or "none"))
	elseif sent == 0 then
		print(PREFIX .. "Configure at least one LFM channel (channel buttons).")
	else
		print(PREFIX .. "LFM sent: " .. preview)
	end
end

function RefreshStatus()
	local names = {}
	local pname = UnitName("player")
	if pname then
		names[pname] = true
	end
	for i = 1, GetNumPartyMembers() do
		local n = UnitName("party" .. i)
		if n then
			names[n:gsub("%-.*", "")] = true
		end
	end
	for i = 1, GetNumRaidMembers() do
		local n = GetRaidRosterInfo(i)
		if n then
			names[n:gsub("%-.*", "")] = true
		end
	end
	local changed = false
	for _, inv in ipairs(INVITED) do
		local st = names[inv.name] and "Joined" or "Pending"
		if st ~= inv.status then
			inv.status = st
			changed = true
		end
	end
	for i = #CANDIDATES, 1, -1 do
		if names[CANDIDATES[i].name] then
			table.remove(CANDIDATES, i)
			changed = true
		end
	end
	if changed then
		RefreshAll()
	end
end

function CleanLeavers()
	if not IsInRaid() then
		print(PREFIX .. "You are not in a raid.")
		return
	end
	local names = {}
	local pname = UnitName("player")
	if pname then
		names[pname:gsub("%-.*", "")] = true
	end
	for i = 1, GetNumPartyMembers() do
		local n = UnitName("party" .. i)
		if n then
			names[n:gsub("%-.*", "")] = true
		end
	end
	for i = 1, GetNumRaidMembers() do
		local n = GetRaidRosterInfo(i)
		if n then
			names[n:gsub("%-.*", "")] = true
		end
	end
	local removed = 0
	for i = #INVITED, 1, -1 do
		local inv = INVITED[i]
		if not names[inv.name] then
			print(PREFIX .. inv.name .. " left the group, removed from the invited list.")
			table.remove(INVITED, i)
			removed = removed + 1
		end
	end
	if removed == 0 then
		print(PREFIX .. "No changes: everyone on the invited list is still in the raid.")
	end
	RefreshAll()
	RefreshMTButtons()
end

function SortGroups()
	if not IsInRaid() then
		print(PREFIX .. "You must be in a raid to sort groups.")
		return
	end
	if not IsRaidLeader() and not IsRaidOfficer() then
		print(PREFIX .. "You must be the raid leader or an assistant to sort groups.")
		return
	end
	if InCombatLockdown() or (UnitAffectingCombat and UnitAffectingCombat("player")) then
		if not pendingSort then
			pendingSort = true
			print(PREFIX .. "You are in combat. The group layout will be sorted automatically when combat ends.")
		end
		return
	end
	if sortRunning then
		print(PREFIX .. "Sort already in progress.")
		return
	end
	pendingSort = false
	sortRunning = true
	local roster = {}
	local currentGroup = {}
	local fullName = {}
	local pname = (UnitName("player") or ""):gsub("%-.*", "")
	local numMembers = GetNumRaidMembers()
	for i = 1, numMembers do
		local n, _, subgroup = GetRaidRosterInfo(i)
		if n then
			fullName[n] = n
			n = n:gsub("%-.*", "")
			roster[#roster + 1] = n
			currentGroup[n] = subgroup or 1
		end
	end
	local info = {}
	info[pname] = { role = db.me.role, aura = db.me.aura }
	for _, inv in ipairs(INVITED) do
		info[inv.name] = info[inv.name] or {}
		info[inv.name].role = inv.role
		info[inv.name].aura = inv.aura
	end
	local groups = math.max(1, math.ceil(numMembers / 5))
	local groupOf = {}
	local countOf = {}
	for g = 1, groups do
		countOf[g] = 0
	end
	local function addToGroup(name, g)
		if not groupOf[name] and countOf[g] < 5 then
			groupOf[name] = g
			countOf[g] = countOf[g] + 1
		end
	end
	for _, n in ipairs(roster) do
		if info[n] and info[n].role == "Tank" then
			addToGroup(n, 1)
		end
	end
	local function hasIn(g, pred)
		for _, n in ipairs(roster) do
			if groupOf[n] == g and pred(info[n]) then
				return true
			end
		end
		return false
	end
	local function healIn(g)
		return hasIn(g, function(inf)
			return inf and inf.role == "Heal"
		end)
	end
	local function auraIn(g)
		return hasIn(g, function(inf)
			return inf and inf.aura
		end)
	end
	for _, n in ipairs(roster) do
		if not groupOf[n] and info[n] and info[n].role == "Heal" then
			local placed = false
			for g = 1, groups do
				if not placed and not healIn(g) and countOf[g] < 5 then
					addToGroup(n, g)
					placed = true
				end
			end
			if not placed then
				for g = 1, groups do
					if not placed and countOf[g] < 5 then
						addToGroup(n, g)
						placed = true
					end
				end
			end
		end
	end
	for _, n in ipairs(roster) do
		if not groupOf[n] and info[n] and info[n].aura then
			local placed = false
			for g = 1, groups do
				if not placed and not auraIn(g) and countOf[g] < 5 then
					addToGroup(n, g)
					placed = true
				end
			end
			if not placed then
				for g = 1, groups do
					if not placed and countOf[g] < 5 then
						addToGroup(n, g)
						placed = true
					end
				end
			end
		end
	end
	for _, n in ipairs(roster) do
		if not groupOf[n] then
			for g = 1, groups do
				addToGroup(n, g)
				if groupOf[n] then
					break
				end
			end
		end
	end
	local function liveGroup(name)
		for i = 1, GetNumRaidMembers() do
			local n, _, sg = GetRaidRosterInfo(i)
			if n and n:gsub("%-.*", "") == name then
				return sg or 1
			end
		end
		return 1
	end
	local function countIn(g)
		local c = 0
		for _, n in ipairs(roster) do
			if liveGroup(n) == g then
				c = c + 1
			end
		end
		return c
	end
	local function findHolding()
		for g = groups + 1, 8 do
			if countIn(g) < 5 then
				return g
			end
		end
	end
	local function getIndex(name)
		for i = 1, GetNumRaidMembers() do
			local n = GetRaidRosterInfo(i)
			if n and n:gsub("%-.*", "") == name then
				return i
			end
		end
	end
	local moved, failed = 0, 0
	local blocked = nil
	local function capture(err)
		if not blocked and err then
			blocked = tostring(err)
		end
	end
	local function moveTo(name, g)
		local idx = getIndex(name)
		if not idx then
			return false
		end
		local ok, err = pcall(SetRaidSubgroup, idx, g)
		if not ok then
			capture(err)
			return false
		end
		return liveGroup(name) == g
	end
	local function trySwap(n, t)
		local i1 = getIndex(n)
		if not i1 then
			return false
		end
		for _, m in ipairs(roster) do
			if groupOf[m] ~= t and liveGroup(m) == t then
				local i2 = getIndex(m)
				if i2 then
					local ok, err = pcall(SwapRaidSubgroup, i1, i2)
					if not ok then
						capture(err)
					end
					return liveGroup(n) == t
				end
			end
		end
		return false
	end
	local function findHolding()
		for g = groups + 1, 8 do
			if countIn(g) < 5 then
				return g
			end
		end
	end
	local function tryPlace(n)
		local t = groupOf[n]
		if not t then
			return true
		end
		if liveGroup(n) == t then
			return true
		end
		if not getIndex(n) then
			return true
		end
		if countIn(t) < 5 then
			moveTo(n, t)
			return liveGroup(n) == t
		end
		if trySwap(n, t) then
			return true
		end
		local h = findHolding()
		if h then
			for _, m in ipairs(roster) do
				if groupOf[m] ~= t and liveGroup(m) == t then
					moveTo(m, h)
					break
				end
			end
			if countIn(t) < 5 then
				moveTo(n, t)
			end
		end
		return liveGroup(n) == t
	end
	local pending = {}
	for _, n in ipairs(roster) do
		if groupOf[n] and liveGroup(n) ~= groupOf[n] then
			pending[#pending + 1] = n
		end
	end
	local ticks = 0
	local cursor = 0
	local finished = false
	local function finish()
		if finished then
			return
		end
		finished = true
		sortRunning = false
		sortTickFrame:SetScript("OnUpdate", nil)
		local moved, failed = 0, 0
		local failedNames = {}
		for _, n in ipairs(roster) do
			if groupOf[n] then
				if liveGroup(n) == groupOf[n] then
					if currentGroup[n] ~= groupOf[n] then
						moved = moved + 1
					end
				else
					failed = failed + 1
					failedNames[#failedNames + 1] = n
				end
			end
		end
		local MT_ICONS = { 1, 5, 2, 3, 4, 6, 7, 8 }
		local mtCommands = {}
		local tankIndex = 0
		for _, n in ipairs(roster) do
			local idx = getIndex(n)
			if info[n] and info[n].role == "Tank" then
				tankIndex = tankIndex + 1
				if idx and SetRaidTargetIcon then
					pcall(SetRaidTargetIcon, "raid" .. idx, MT_ICONS[tankIndex] or MT_ICONS[1])
				end
				mtCommands[#mtCommands + 1] = "/maintank " .. n
			end
		end
		local auraParts, healParts = {}, {}
		local tankList = {}
		for g = 1, groups do
			local auraNames, healNames = {}, {}
			for _, n in ipairs(roster) do
				if groupOf[n] == g then
					if info[n] and info[n].role == "Tank" then
						table.insert(tankList, n)
					end
					if info[n] and info[n].role == "Heal" then
						table.insert(healNames, n)
					end
					if info[n] and info[n].aura then
						table.insert(auraNames, n)
					end
				end
			end
			if #auraNames > 0 then
				auraParts[#auraParts + 1] = string.format("G%d Aura: %s", g, table.concat(auraNames, ", "))
			end
			if #healNames > 0 then
				healParts[#healParts + 1] = string.format("G%d Heal: %s", g, table.concat(healNames, ", "))
			end
		end
		local function joinList(list)
			if #list == 0 then
				return "none"
			elseif #list == 1 then
				return list[1]
			end
			return table.concat(list, ", ", 1, #list - 1) .. " and " .. list[#list]
		end
		if #auraParts > 0 then
			SendChatMessage("MSLeveling: " .. table.concat(auraParts, ", "), "RAID")
		end
		if #healParts > 0 then
			SendChatMessage("MSLeveling: " .. table.concat(healParts, "; "), "RAID")
		end
		SendChatMessage("MSLeveling: Tanks: " .. joinList(tankList), "RAID")
		print(PREFIX .. string.format("Groups sorted: %d moved, %d failed.", moved, failed))
		if #failedNames > 0 then
			print(PREFIX .. "Could not place: " .. table.concat(failedNames, ", "))
		end
		if blocked then
			print(PREFIX .. "Client blocked an action: " .. blocked)
			print(PREFIX .. "Try sorting while not in combat and as raid leader.")
		end
		if #mtCommands > 0 then
			print(PREFIX .. "Click a Mark MT button to set the Main Tank in the raid frame.")
		end
		RefreshAll()
		RefreshMTButtons()
	end
	local function tick()
		ticks = ticks + 1
		if ticks > 60 then
			finish()
			return
		end
		local attempts = 0
		local still = {}
		for i = 1, #pending do
			local n = pending[((cursor + i - 1) % #pending) + 1]
			if liveGroup(n) == groupOf[n] then
			elseif attempts < 2 then
				attempts = attempts + 1
				if not tryPlace(n) then
					still[#still + 1] = n
				end
			else
				still[#still + 1] = n
			end
		end
		cursor = (cursor + attempts) % math.max(1, #pending)
		pending = still
		if #pending == 0 then
			finish()
		end
	end
	if #pending == 0 then
		finish()
	else
		sortElapsed = 0
		sortTickFrame:SetScript("OnUpdate", function(self, dt)
			sortElapsed = sortElapsed + dt
			if sortElapsed >= 0.15 then
				sortElapsed = 0
				tick()
			end
		end)
	end
	RefreshAll()
	RefreshMTButtons()
end

local function UpsertCandidate(name, role, aura)
	local idx = FindCandidate(name)
	if idx then
		local c = CANDIDATES[idx]
		if role then
			c.role = role
		end
		if aura ~= nil then
			c.aura = aura
		end
		c.time = GetTime()
	else
		table.insert(CANDIDATES, { name = name, role = role or "?", aura = aura, time = GetTime() })
	end
end

function HandleWhisper(msg, author)
	msg = msg or ""
	author = author or "?"
	local m = string.lower(msg)
	local role = DetectRole(m)
	local aura = DetectAura(m)
	local name = author:gsub("%-.*", "")
	if collecting then
		if role == nil or aura == nil then
			local r, a = ParseNumbers(m)
			if not role and r then
				role = r
			end
			if aura == nil and a ~= nil then
				aura = a
			end
		end
		if role or aura then
			MergeReply(name, role, aura)
			local rep = memberReplies[name]
			print(PREFIX .. name .. " replied (" .. rep.role .. (rep.aura and " - Aura" or " - Without aura") .. ")")
			if db.autoReply then
				SendChatMessage(REPLY_OK, "WHISPER", nil, name)
			end
		end
		return
	end
	if not role and aura == nil then
		if db.autoReply then
			SendChatMessage(REPLY_HELP, "WHISPER", nil, name)
		end
	elseif db.autoReply then
		SendChatMessage(REPLY_OK, "WHISPER", nil, name)
	end
	local inv = FindInvited(name)
	if inv then
		if role then
			inv.role = role
		end
		if aura ~= nil then
			inv.aura = aura
		end
		print(PREFIX .. name .. " updated (" .. inv.role .. " - " .. (inv.aura == nil and "?" or (inv.aura and "Aura" or "No")) .. ")")
		RefreshAll()
		return
	end
	local isNew = not FindCandidate(name)
	UpsertCandidate(name, role, aura)
	if isNew then
		local _, c = FindCandidate(name)
		print(PREFIX .. "New candidate: " .. name .. " (" .. (c.role or "?") .. " - " .. (c.aura == nil and "?" or (c.aura and "Aura" or "No")) .. ")")
	end
	RefreshAll()
end

function HandleRaidChat(msg, author)
	if not collecting then
		return
	end
	local m = string.lower(msg or "")
	local name = (author or "?"):gsub("%-.*", "")
	local pname = UnitName("player")
	if pname and name == pname:gsub("%-.*", "") then
		return
	end
	local role = DetectRole(m)
	local aura = DetectAura(m)
	if role == nil or aura == nil then
		local r, a = ParseNumbers(m)
		if not role and r then
			role = r
		end
		if aura == nil and a ~= nil then
			aura = a
		end
	end
	if role or aura then
		MergeReply(name, role, aura)
		local rep = memberReplies[name]
		print(PREFIX .. name .. " replied (" .. rep.role .. (rep.aura and " - Aura" or " - Without aura") .. ")")
	end
end

local function RemoveInvited(name)
	for i, inv in ipairs(INVITED) do
		if inv.name == name then
			table.remove(INVITED, i)
			break
		end
	end
	print(PREFIX .. name .. " removed from invited.")
	RefreshAll()
end

local function CreateRow(parent, isCandidate)
	local row = CreateFrame("Frame", nil, parent)
	row:SetSize(360, ROW_HEIGHT)
	row.bg = row:CreateTexture(nil, "BACKGROUND")
	row.bg:SetAllPoints(row)
	row.bg:SetTexture(1, 1, 1, 0.06)
	row.bg:Hide()
	row:EnableMouse(true)
	row:SetScript("OnEnter", function(self)
		self.bg:Show()
	end)
	row:SetScript("OnLeave", function(self)
		self.bg:Hide()
	end)

	row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.name:SetPoint("LEFT", 2, 0)
	row.name:SetWidth(150)
	row.name:SetJustifyH("LEFT")

	row.role = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
	row.role:SetSize(52, ROW_HEIGHT - 4)
	row.role:SetPoint("LEFT", 154, 0)
	row.roleText = row.role:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.roleText:SetAllPoints(row.role)
	row.roleText:SetJustifyH("CENTER")
	row.roleText:SetJustifyV("MIDDLE")
	row.role:SetScript("OnClick", function(self)
		local d = self:GetParent().data
		if d then
			d.role = ROLE_CYCLE[d.role or "?"]
			RefreshAll()
		end
	end)

	row.aura = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
	row.aura:SetSize(56, ROW_HEIGHT - 4)
	row.aura:SetPoint("LEFT", 210, 0)
	row.auraText = row.aura:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.auraText:SetAllPoints(row.aura)
	row.auraText:SetJustifyH("CENTER")
	row.auraText:SetJustifyV("MIDDLE")
	row.aura:SetScript("OnClick", function(self)
		local d = self:GetParent().data
		if d then
			d.aura = not d.aura
			RefreshAll()
		end
	end)

	if isCandidate then
		row.action = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
		row.action:SetSize(68, ROW_HEIGHT - 4)
		row.action:SetPoint("LEFT", 274, 0)
		row.actionText = row.action:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		row.actionText:SetAllPoints(row.action)
		row.actionText:SetJustifyH("CENTER")
		row.actionText:SetJustifyV("MIDDLE")
		row.actionText:SetText("Invite")
		row.action:SetScript("OnClick", function(self)
			local d = self:GetParent().data
			if d then
				InvitePlayer(d.name)
			end
		end)
	else
		row.status = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		row.status:SetPoint("LEFT", 262, 0)
		row.status:SetWidth(48)
		row.status:SetJustifyH("LEFT")
		row.kick = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
		row.kick:SetSize(48, ROW_HEIGHT - 4)
		row.kick:SetPoint("LEFT", 312, 0)
		row.kickText = row.kick:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		row.kickText:SetAllPoints(row.kick)
		row.kickText:SetJustifyH("CENTER")
		row.kickText:SetJustifyV("MIDDLE")
		row.kickText:SetText("Remove")
		row.kick:SetScript("OnClick", function(self)
			local d = self:GetParent().data
			if d then
				RemoveInvited(d.name)
			end
		end)
	end
	return row
end

f = CreateFrame("Frame", "MSLevelingFrame", UIParent)
f:SetSize(430, 640)
f:SetPoint("CENTER")
f:SetBackdrop({
	bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
	edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
	tile = true,
	tileSize = 16,
	edgeSize = 16,
	insets = { left = 4, right = 4, top = 4, bottom = 4 },
})
f:SetBackdropColor(0, 0, 0, 0.92)
f:SetBackdropBorderColor(0.4, 0.5, 0.7, 0.9)
f:SetFrameStrata("DIALOG")
f:EnableMouse(true)
f:SetMovable(true)
f:RegisterForDrag("LeftButton")
f:SetClampedToScreen(true)
f:SetScript("OnDragStart", function(self)
	self:StartMoving()
end)
f:SetScript("OnDragStop", function(self)
	self:StopMovingOrSizing()
	local _, _, x, y = self:GetPoint(1)
	db.framePos = { x, y }
end)
f:SetScript("OnShow", function()
	RefreshAll()
end)

title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
title:SetPoint("TOPLEFT", 16, -10)
title:SetText("|cff66b3ffMS Leveling|r - Addon by Bokuden")

local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
closeBtn:SetPoint("TOPRIGHT", -5, -5)
closeBtn:SetScript("OnClick", function()
	f:Hide()
end)

counts = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
counts:SetPoint("TOPLEFT", 16, -60)
counts:SetJustifyH("LEFT")

selfRow = CreateFrame("Frame", nil, f)
selfRow:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -34)
selfRow:SetSize(360, ROW_HEIGHT)

selfRow.name = selfRow:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
selfRow.name:SetPoint("LEFT", 2, 0)
selfRow.name:SetWidth(150)
selfRow.name:SetJustifyH("LEFT")

local selfRole = CreateFrame("Button", nil, selfRow, "UIPanelButtonTemplate")
selfRole:SetSize(52, ROW_HEIGHT - 4)
selfRole:SetPoint("LEFT", 154, 0)
selfRoleText = selfRole:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
selfRoleText:SetAllPoints(selfRole)
selfRoleText:SetJustifyH("CENTER")
selfRoleText:SetJustifyV("MIDDLE")
selfRole:SetScript("OnClick", function()
	db.me.role = ROLE_CYCLE[db.me.role or "?"]
	RefreshAll()
end)

local selfAura = CreateFrame("Button", nil, selfRow, "UIPanelButtonTemplate")
selfAura:SetSize(56, ROW_HEIGHT - 4)
selfAura:SetPoint("LEFT", 210, 0)
selfAuraText = selfAura:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
selfAuraText:SetAllPoints(selfAura)
selfAuraText:SetJustifyH("CENTER")
selfAuraText:SetJustifyV("MIDDLE")
selfAura:SetScript("OnClick", function()
	if db.me.aura == nil then
		db.me.aura = true
	elseif db.me.aura then
		db.me.aura = false
	else
		db.me.aura = nil
	end
	RefreshAll()
end)

local lfmBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
lfmBtn:SetSize(110, 22)
lfmBtn:SetPoint("TOPLEFT", 16, -84)
lfmBtn:SetText("Post LFM")
lfmBtn:SetScript("OnClick", BroadcastLFM)

local raidBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
raidBtn:SetSize(95, 22)
raidBtn:SetPoint("LEFT", lfmBtn, "RIGHT", 6, 0)
raidBtn:SetText("Load Raid")
raidBtn:SetScript("OnClick", LoadRaid)

local resetBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
resetBtn:SetSize(70, 22)
resetBtn:SetPoint("LEFT", raidBtn, "RIGHT", 6, 0)
resetBtn:SetText("Reset")
resetBtn:SetScript("OnClick", function()
	StaticPopup_Show("MSLEVELING_RESET")
end)

finishBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
finishBtn:SetSize(100, 22)
finishBtn:SetPoint("TOPLEFT", 16, -108)
finishBtn:SetText("Finish Count")
finishBtn:SetScript("OnClick", FinalizeCollect)

local autoBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
autoBtn:SetSize(104, 22)
autoBtn:SetPoint("LEFT", finishBtn, "RIGHT", 6, 0)
autoBtn:SetText(db.autoReply and "AutoReply: On" or "AutoReply: Off")
autoBtn:SetScript("OnClick", function(self)
	db.autoReply = not db.autoReply
	self:SetText(db.autoReply and "AutoReply: On" or "AutoReply: Off")
	print(PREFIX .. "Automatic whisper reply: " .. (db.autoReply and "enabled" or "disabled"))
end)

local sortBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
sortBtn:SetSize(110, 22)
sortBtn:SetPoint("LEFT", autoBtn, "RIGHT", 6, 0)
sortBtn:SetText("Sort Groups")
sortBtn:SetScript("OnClick", SortGroups)

local cleanBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
cleanBtn:SetSize(66, 22)
cleanBtn:SetPoint("LEFT", sortBtn, "RIGHT", 6, 0)
cleanBtn:SetText("Clean")
cleanBtn:SetScript("OnClick", CleanLeavers)

local mtLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
mtLabel:SetPoint("TOPLEFT", 16, -176)
mtLabel:SetText("Mark MT (click = /maintank)")

local mtButtons = {}
function RefreshMTButtons()
	for _, b in ipairs(mtButtons) do
		b:Hide()
	end
	local tanks = {}
	local seen = {}
	local pname = UnitName("player")
	local function addTank(n)
		if n and not seen[n] then
			seen[n] = true
			tanks[#tanks + 1] = n
		end
	end
	if db.me.role == "Tank" then
		addTank(pname)
	end
	for i = 1, GetNumRaidMembers() do
		local n = GetRaidRosterInfo(i)
		if n then
			n = n:gsub("%-.*", "")
			local role
			for _, c in ipairs(INVITED) do
				if c.name == n then
					role = c.role
					break
				end
			end
			if role == "Tank" then
				addTank(n)
			end
		end
	end
	for i, name in ipairs(tanks) do
		local b = mtButtons[i]
		if not b then
			b = CreateFrame("Button", nil, f, "SecureActionButtonTemplate, UIPanelButtonTemplate")
			b:SetSize(112, 22)
			b:SetPoint("TOPLEFT", 200 + (i - 1) * 118, -176)
			b:SetAttribute("type", "macro")
			mtButtons[i] = b
		end
		b:SetText("MT: " .. name)
		b:SetAttribute("macrotext", "/maintank " .. name)
		b:Show()
	end
end
RefreshMTButtons()

local chLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
chLabel:SetPoint("TOPLEFT", 16, -134)
chLabel:SetText("LFM channels (click to change, 0 = none):")

local chButtons = {}
for i = 1, 3 do
	local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	b:SetSize(36, 20)
	b:SetPoint("TOPLEFT", 16 + (i - 1) * 42, -150)
	b:SetText(tostring(db.channels[i] or 0))
	b:SetScript("OnClick", function(self)
		db.channels[i] = ((db.channels[i] or 0) + 1) % 11
		self:SetText(tostring(db.channels[i]))
	end)
	chButtons[i] = b
end

local candHeader = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
candHeader:SetPoint("TOPLEFT", 16, -204)
candHeader:SetText("Candidates (whispers):")

candScroll = CreateFrame("ScrollFrame", "MSLevelingCandScroll", f, "FauxScrollFrameTemplate")
candScroll:SetPoint("TOPLEFT", 8, -220)
candScroll:SetPoint("TOPRIGHT", f, "TOPRIGHT", -24, -220)
candScroll:SetPoint("BOTTOMLEFT", f, "TOPLEFT", 8, -396)
candScroll:SetPoint("BOTTOMRIGHT", f, "TOPRIGHT", -24, -396)
candScroll:SetScript("OnVerticalScroll", function(self, offset)
	FauxScrollFrame_OnVerticalScroll(self, offset, ROW_HEIGHT, RefreshCandidates)
end)
candScroll:EnableMouseWheel(true)
candScroll:SetScript("OnMouseWheel", function(self, delta)
	local sb = _G[self:GetName() .. "ScrollBar"]
	sb:SetValue(sb:GetValue() - delta * ROW_HEIGHT)
end)

candRows = {}
for i = 1, ROWS_CAND do
	candRows[i] = CreateRow(f, true)
	candRows[i]:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -220 - (i - 1) * ROW_HEIGHT)
end

local invHeader = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
invHeader:SetPoint("TOPLEFT", 16, -404)
invHeader:SetText("Invited:")

invScroll = CreateFrame("ScrollFrame", "MSLevelingInvScroll", f, "FauxScrollFrameTemplate")
invScroll:SetPoint("TOPLEFT", 8, -420)
invScroll:SetPoint("TOPRIGHT", f, "TOPRIGHT", -24, -420)
invScroll:SetPoint("BOTTOMLEFT", f, "TOPLEFT", 8, -630)
invScroll:SetPoint("BOTTOMRIGHT", f, "TOPRIGHT", -24, -630)
invScroll:SetScript("OnVerticalScroll", function(self, offset)
	FauxScrollFrame_OnVerticalScroll(self, offset, ROW_HEIGHT, RefreshInvited)
end)
invScroll:EnableMouseWheel(true)
invScroll:SetScript("OnMouseWheel", function(self, delta)
	local sb = _G[self:GetName() .. "ScrollBar"]
	sb:SetValue(sb:GetValue() - delta * ROW_HEIGHT)
end)

invRows = {}
for i = 1, ROWS_INV do
	invRows[i] = CreateRow(f, false)
	invRows[i]:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -420 - (i - 1) * ROW_HEIGHT)
end

local hint = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
hint:SetPoint("BOTTOMLEFT", 16, 8)
hint:SetText("Click Role/Aura to edit | /mslv toggles the window")

StaticPopupDialogs["MSLEVELING_RESET"] = {
	text = "Reset the MS Leveling list? Candidates and invited players will be removed.",
	button1 = "Reset",
	button2 = "Cancel",
	timeout = 0,
	whileDead = 1,
	hideOnEscape = 1,
	preferredIndex = 3,
	OnAccept = function()
		ResetAll()
	end,
}

local mm = CreateFrame("Button", "MSLevelingMinimapButton", Minimap)
mm:SetSize(32, 32)
mm:SetFrameStrata("MEDIUM")
mm:SetFrameLevel(8)
mm:RegisterForClicks("LeftButtonUp")
mm:RegisterForDrag("LeftButton")
mm:SetClampedToScreen(true)

local mmIcon = mm:CreateTexture(nil, "ARTWORK")
mmIcon:SetTexture("Interface\\Icons\\spell_holy_guardianspirit")
mmIcon:SetSize(26, 26)
mmIcon:SetPoint("CENTER", mm, "CENTER", 0, -1)

local mmBorder = mm:CreateTexture(nil, "OVERLAY")
mmBorder:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
mmBorder:SetSize(52, 52)
mmBorder:SetPoint("CENTER", mm, "CENTER", 0, -1)

function PositionMinimap()
	local angle = math.rad(db.minimapPos or 0)
	mm:SetPoint("CENTER", Minimap, "CENTER", 80 * math.cos(angle), 80 * math.sin(angle))
end

mm:SetScript("OnClick", function()
	if f:IsShown() then
		f:Hide()
	else
		f:Show()
		f:Raise()
	end
end)

mm:SetScript("OnDragStart", function()
	mm:SetScript("OnUpdate", function()
		local x, y = GetCursorPosition()
		local scale = Minimap:GetEffectiveScale()
		x = x / scale
		y = y / scale
		local cx, cy = Minimap:GetCenter()
		local angle = math.atan2(y - cy, x - cx)
		db.minimapPos = math.deg(angle)
		mm:SetPoint("CENTER", Minimap, "CENTER", 80 * math.cos(angle), 80 * math.sin(angle))
	end)
end)

mm:SetScript("OnDragStop", function()
	mm:SetScript("OnUpdate", nil)
end)

SLASH_MSLV1 = "/mslv"
SLASH_MSLV2 = "/msleveling"
SlashCmdList["MSLV"] = function(arg)
	arg = (arg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
	if arg == "reset" then
		ResetAll()
	elseif arg == "lfm" then
		BroadcastLFM()
	elseif arg == "raid" then
		LoadRaid()
	else
		if f:IsShown() then
			f:Hide()
		else
			f:Show()
			f:Raise()
		end
	end
end

RefreshAll()
PositionMinimap()
