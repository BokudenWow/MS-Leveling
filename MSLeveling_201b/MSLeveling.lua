local ADDON_NAME = "MSLeveling"
local PREFIX = "|cff66b3ff[MSL]|r "
local ADDON_LINK = "https://github.com/BokudenWow/MS-Leveling/"
local REPLY_HELP = "Automatic message: Whisper your role and aura to sign up, e.g. 'tank aura', 'heal no aura' or 'dps'. Addon: " .. ADDON_LINK
local REPLY_OK = "Automatic message: You are on the queue list. If there is room for your role you will be db.invited."
local WELCOME_TANK = "Automatic message: Welcome! May your shield be as unbreakable as the walls of Ironforge and every foe kneel to your taunt."
local WELCOME_HEAL = "Automatic message: Welcome! May the Holy Light guide your hands, and the fallen always rise again at your call."
local WELCOME_OTHER = "Automatic message: Welcome, you have been auto-invited."
local REJECT_AURA = "Automatic message: Sorry, the slot is reserved for DPS with an Aura right now. Thanks for your interest!"
local REJECT_ROLE_FULL = "Automatic message: Sorry, there is no room for your role right now. Thanks for your interest!"
local REJECT_GROUP_FULL = "Automatic message: Sorry, the group is currently full. Thanks for your interest!"
local FAREWELL_MSG = "Automatic message: Thanks for joining the group, good luck with your rolls! If you want to join again you can grab the addon here: " .. ADDON_LINK

MSLeveling201bDB = MSLeveling201bDB or {}
local db = MSLeveling201bDB

db.channels = db.channels or { 1, 8, 0 }
db.me = db.me or {}
if db.autoReply == nil then
	db.autoReply = false
end
if db.antileech == nil then
	db.antileech = true
end
if db.autoLFG == nil then
	db.autoLFG = false
end
if db.autoLFM == nil then
	db.autoLFM = false
end
if db.enterButtonName == nil then
	db.enterButtonName = ""
end

db.compTank = db.compTank or 2
db.compHeal = db.compHeal or 3

local MAX_TANK, MAX_HEAL, MAX_DPS, MAX_AURA, MAX_TOTAL = 2, 3, 10, 3, 15
local function ApplyComp()
	MAX_TANK = math.max(1, math.min(3, tonumber(db.compTank) or 2))
	MAX_HEAL = math.max(1, math.min(5, tonumber(db.compHeal) or 3))
	db.compTank = MAX_TANK
	db.compHeal = MAX_HEAL
	MAX_DPS = math.max(1, MAX_TOTAL - MAX_TANK - MAX_HEAL)
end
ApplyComp()
local ROW_HEIGHT = 26
local ROWS_CAND = 8
local ROWS_INV = 8

db.candidates = db.candidates or {}
db.invited = db.invited or {}
db.memberReplies = db.memberReplies or {}
db.flaggedPlayers = db.flaggedPlayers or {}
if db.collecting == nil then
	db.collecting = false
end
if db.candCollapsed == nil then
	db.candCollapsed = true
end
if db.invCollapsed == nil then
	db.invCollapsed = true
end
if db.panelLayoutV == nil then
	db.candCollapsed = true
	db.invCollapsed = true
	db.panelLayoutV = 1
end

local ROLE_CYCLE = { Tank = "Heal", Heal = "DPS", DPS = "?", ["?"] = "Tank" }
local ROLE_COLORS = {
	Tank = { 1.0, 0.6, 0.3 },
	Heal = { 0.3, 1.0, 0.5 },
	DPS = { 1.0, 0.85, 0.2 },
	["?"] = { 0.7, 0.7, 0.7 },
}

local THEME = {
	bg     = { 0.035, 0.05, 0.08, 0.97 },
	panel  = { 0.07, 0.09, 0.13, 1 },
	panel2 = { 0.055, 0.075, 0.12, 1 },
	gold   = { 1.0, 0.8, 0.35, 1 },
	border = { 0.45, 0.56, 0.75, 0.9 },
	muted  = { 0.55, 0.58, 0.68, 1 },
}
local chips

local f, counts, selfRow, selfRoleText, selfAuraText, candScroll, candRows, invScroll, invRows, finishBtn, title
local FindInvited, HandleWhisper, RefreshStatus, RefreshSelf, PositionMinimap, HandleRaidChat, CleanLeavers, SortGroups, HandleChannel, KickPlayer, CheckRaidLevels, SendFarewell, FrameToggleRequest, CheckDepartures, CheckAutoOff, UpdateAutoButtons, RemoveInvited, ApplyFrameToggle, RefreshAll, SyncRaidRoster

local collecting = db.collecting
local memberReplies = db.memberReplies

local function SetCollecting(v)
	collecting = v
	db.collecting = v
end
-- Leecher / level-59 warnings panel: { name = { reason = "...", since = time } }
local flaggedPlayers = db.flaggedPlayers
local flagPanel, flagScroll, flagRows = nil, nil, {}

local FLAG_IDLE = "Idle 45s+ (no damage/healing)"
local FLAG_LEECH = "Loading without contributing"
local FLAG_LVL59 = "Reached level 59"
local FLAG_LVL60 = "Reached level 60"

local function FlagPlayer(name, reason)
	if not name or name == "" then return end
	local pname = UnitName("player")
	if name == (pname or ""):gsub("%-.*", "") then return end
	local existing = flaggedPlayers[name]
	if existing and existing.reason == reason then return end
	flaggedPlayers[name] = { reason = reason, since = GetTime() }
	if RefreshFlagPanel then RefreshFlagPanel() end
end

local function UnflagPlayer(name)
	if not name then return end
	if flaggedPlayers[name] then
		flaggedPlayers[name] = nil
		if RefreshFlagPanel then RefreshFlagPanel() end
	end
end

function KickFlagged(name)
	local inv = FindInvited(name)
	if not inv then
		RemoveInvited(name)
		inv = { name = name }
	end
	local reason = flaggedPlayers[name] and flaggedPlayers[name].reason or "Violation"
	local msg = ("You have been removed from the raid: %s. Thank you for participating! If you'd like to join again, you can grab the addon here: %s"):format(reason, ADDON_LINK)
	SendFarewell(name, nil, msg)
	KickPlayer(name, reason)
	UnflagPlayer(name)
end

local pendingSort = false
local sortRunning = false
local sortElapsed = 0
local sortTickFrame
local frameDragging = false
local lastRosterNames = {}
local farewellScheduled = {}
local rejectSent = {}

local addon = CreateFrame("Frame")
addon:RegisterEvent("CHAT_MSG_WHISPER")
addon:RegisterEvent("CHAT_MSG_CHANNEL")
addon:RegisterEvent("CHAT_MSG_SYSTEM")
addon:RegisterEvent("CHAT_MSG_RAID")
addon:RegisterEvent("CHAT_MSG_RAID_WARNING")
addon:RegisterEvent("CHAT_MSG_PARTY")
addon:RegisterEvent("GROUP_ROSTER_UPDATE")
addon:RegisterEvent("PLAYER_REGEN_ENABLED")
addon:RegisterEvent("PLAYER_LOGIN")
addon:RegisterEvent("PLAYER_ENTERING_WORLD")
addon:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
addon:RegisterEvent("ZONE_CHANGED_NEW_AREA")
addon:RegisterEvent("READY_CHECK")
addon:RegisterEvent("READY_CHECK_CONFIRM")
addon:RegisterEvent("PLAYER_LEVEL_UP")
addon:RegisterEvent("UNIT_LEVEL")
addon:SetScript("OnEvent", function(self, event, ...)
	if event == "CHAT_MSG_WHISPER" then
		if HandleWhisper then
			HandleWhisper(...)
		end
	elseif event == "CHAT_MSG_CHANNEL" then
		if HandleChannel then
			HandleChannel(...)
		end
	elseif event == "CHAT_MSG_SYSTEM" then
		local msg = ...
		if type(msg) == "string" then
			local declineName = msg:match("^(.+) declines? your invite.$") or msg:match("^(.+) has declined your invite.$") or msg:match("^(.+) rechaza? tu invitaci.*n.?$") or msg:match("^(.+) ha rechazado tu invitaci.*n.?$")
			if declineName then
				declineName = declineName:gsub("%-.*", "")
				for i = #db.invited, 1, -1 do
					if db.invited[i].name == declineName and db.invited[i].status == "Pending" then
						print(PREFIX .. declineName .. " declined the invite, slot freed.")
						table.remove(db.invited, i)
						RefreshAll()
						break
					end
				end
			end
		end
	elseif event == "CHAT_MSG_RAID" or event == "CHAT_MSG_RAID_WARNING" or event == "CHAT_MSG_PARTY" then
		if HandleRaidChat then
			HandleRaidChat(...)
		end
	elseif event == "GROUP_ROSTER_UPDATE" then
		if SyncRaidRoster then
			SyncRaidRoster()
		end
		if RefreshStatus then
			RefreshStatus()
		end
		if CheckRaidLevels then
			CheckRaidLevels()
		end
		if ApplyRaidIcons then
			ApplyRaidIcons()
		end
	elseif event == "UNIT_LEVEL" or event == "PLAYER_LEVEL_UP" then
		if RefreshStatus then
			RefreshStatus()
		end
		if CheckRaidLevels then
			CheckRaidLevels()
		end
	elseif event == "PLAYER_REGEN_ENABLED" then
		if ApplyFrameToggle then
			ApplyFrameToggle()
		end
		if pendingSort then
			pendingSort = false
			if SortGroups then
				SortGroups()
			end
		end
		if FlushPendingKicks then
			FlushPendingKicks()
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
		if RefreshAll then RefreshAll() end
	elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
		if LeechCombat then
			LeechCombat(...)
		end
	elseif event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" then
		if CheckLeechLoads then
			CheckLeechLoads()
		end
		if CheckManastormEntry then
			CheckManastormEntry()
		end
	elseif event == "READY_CHECK" or event == "READY_CHECK_CONFIRM" then
		if HandleReadyCheck then
			HandleReadyCheck(event, ...)
		end
	end
end)

sortTickFrame = CreateFrame("Frame", "MSL201bSortTick")

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

local AURA_NEG_PHRASES = {
	" no aura ",
	" no auras ",
	" noaura ",
	" noauras ",
	" sinaura ",
	" sinauras ",
	" sin aura",
	" sin auras",
	" without aura ",
	" without an aura ",
	" not aura ",
	" not auras ",
	" do not have aura ",
	" do not have an aura ",
	" dont have aura ",
	" dont have an aura ",
	" no tengo aura",
	" no tengo auras",
	" no tengo",
	" no curacion",
	" no healing",
	" aura no",
	" auras no",
	" no buff",
	" nobuff ",
	" sinbuff ",
	" sin buff",
	" no aura buff",
	" would not",
	" wout aura ",
	" w/o aura ",
	" withoutbuff",
	" no buff aura"
}

local function MessageDeniesAura(m)
	local words = " " .. tostring(m):lower():gsub("[^%a ]", " "):gsub("%s+", " ") .. " "
	for _, p in ipairs(AURA_NEG_PHRASES) do
		if words:find(p, 1, true) then
			return true
		end
	end
	return false
end

local function DetectAura(m)
	if MessageDeniesAura(m) then
		return false
	end
	local positive = HasWord(m, "con aura") or HasWord(m, "with aura") or HasWord(m, "si aura") or HasWord(m, "with buff") or HasWord(m, "con buff") or HasWord(m, "aura si") or HasWord(m, "aura buff")
	if positive then
		return true
	end
	local mentions = HasWord(m, "aura") or HasWord(m, "auras") or HasWord(m, "buff") or HasWord(m, "buffs")
	if not mentions then
		return nil
	end
	local neg = HasWord(m, "no") or HasWord(m, "sin") or HasWord(m, "without") or HasWord(m, "wout") or HasWord(m, "w/o")
	if neg then
		return false
	end
	return true
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
	local compact = m:gsub("%s+", "")
	if compact ~= m then
		t = t or HasNum(compact, "1")
		h = h or HasNum(compact, "2")
		a = a or HasNum(compact, "3")
	end
	if compact:match("^[123]+$") then
		t = compact:find("1", 1, true) ~= nil
		h = compact:find("2", 1, true) ~= nil
		a = compact:find("3", 1, true) ~= nil
	end
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
	local tot = 0
	if db.me.role == "Tank" then
		t = t + 1
	elseif db.me.role == "Heal" then
		h = h + 1
	elseif db.me.role == "DPS" then
		d = d + 1
	end
	tot = 1
	if db.me.aura then
		a = a + 1
	end
	for _, inv in ipairs(db.invited) do
		if inv.status == "Joined" or inv.status == "Pending" then
			tot = tot + 1
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
	end
	return t, h, d, a, tot
end

local function FindCandidate(name)
	for i, v in ipairs(db.candidates) do
		if v.name == name then
			return i, v
		end
	end
end

function FindInvited(name)
	for _, v in ipairs(db.invited) do
		if v.name == name then
			return v
		end
	end
end

local function RefreshCandidates()
	local num = #db.candidates
	FauxScrollFrame_Update(candScroll, num, ROWS_CAND, ROW_HEIGHT)
	local offset = FauxScrollFrame_GetOffset(candScroll)
	for i = 1, ROWS_CAND do
		local row = candRows[i]
		local d = db.candidates[offset + i]
		if d and not db.candCollapsed then
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
	local num = #db.invited
	FauxScrollFrame_Update(invScroll, num, ROWS_INV, ROW_HEIGHT)
	local offset = FauxScrollFrame_GetOffset(invScroll)
	for i = 1, ROWS_INV do
		local row = invRows[i]
		local d = db.invited[offset + i]
		if d and not db.invCollapsed then
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
	if CheckAutoOff then
		CheckAutoOff()
	end
	local t, h, d, a, tot = GetCounts()
	if chips then
		local data = {
			{ "Tanks", t, MAX_TANK },
			{ "Heals", h, MAX_HEAL },
			{ "DPS", d, MAX_DPS },
			{ "Auras", a, MAX_AURA },
			{ "Total", tot, MAX_TOTAL },
		}
		for i, chip in ipairs(chips) do
			local _, cur, max = data[i][1], data[i][2], data[i][3]
			local ratio = max > 0 and math.min(1, cur / max) or 0
			ratio = math.max(0, ratio)
			chip.bar:SetWidth(math.floor((chip.barMax or 74) * ratio))
			local cr, cg, cb
			if max == 0 then
				cr, cg, cb = 0.9, 0.4, 0.4
			elseif cur >= max then
				cr, cg, cb = 0.4, 0.95, 0.5
			else
				cr, cg, cb = 1.0, 0.65, 0.2
			end
			chip:SetBackdropBorderColor(cr * 0.85, cg * 0.85, cb * 0.85, 1)
			chip.bar:SetVertexColor(cr, cg, cb, 0.9)
			chip.num:SetText(cur .. "/" .. max)
			chip.num:SetTextColor(cr, cg, cb)
		end
	end
	if not counts then return end
	counts:SetFormattedText(
		"|cff66b3ffTanks|r |cff%s%d/%d|r   |cff66b3ffHeals|r |cff%s%d/%d|r   |cff66b3ffDPS|r |cff%s%d/%d|r   |cff66b3ffAuras|r |cff%s%d/%d|r   |cff66b3ffTotal|r |cff%s%d/%d|r",
		CountColor(t, MAX_TANK), t, MAX_TANK,
		CountColor(h, MAX_HEAL), h, MAX_HEAL,
		CountColor(d, MAX_DPS), d, MAX_DPS,
		CountColor(a, MAX_AURA), a, MAX_AURA,
		CountColor(tot, MAX_TOTAL), tot, MAX_TOTAL
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

RefreshAll = function()
	RefreshSelf()
	RefreshCounts()
	RefreshCandidates()
	RefreshInvited()
	if RefreshCompLabels then
		RefreshCompLabels()
	end
	if finishBtn then
		finishBtn:SetEnabled(collecting)
	end
	if title then
		title:SetText("|cff66b3ffMS Leveling 2.04|r" .. (collecting and " |cff7dff7d[Collecting...]|r" or ""))
	end
end

local function EnsureRaid()
	if IsInRaid() then
		return true
	end
	if InCombatLockdown() then
		return false
	end
	if GetNumPartyMembers() >= 1 then
		local ok = pcall(ConvertToRaid)
		return ok and IsInRaid()
	end
	return false
end

local function InvitePlayer(name)
	if FindInvited(name) then
		return
	end
	EnsureRaid()
	local idx, cand = FindCandidate(name)
	if not cand then
		return
	end
	local _, _, _, _, tot = GetCounts()
	if tot >= MAX_TOTAL then
		print(PREFIX .. name .. " was not invited: the raid is already full (" .. MAX_TOTAL .. "/" .. MAX_TOTAL .. ").")
		return
	end
	if GetNumRaidMembers() >= MAX_TOTAL then
		print(PREFIX .. name .. " was not invited: the raid already has " .. GetNumRaidMembers() .. "/" .. MAX_TOTAL .. " players.")
		return
	end
	local t, h, d, a = GetCounts()
	if cand.role == "Tank" and t >= MAX_TANK then
		print(PREFIX .. name .. " is a Tank but the tank slots are full.")
		return
	end
	if cand.role == "Heal" and h >= MAX_HEAL then
		print(PREFIX .. name .. " is a Heal but the heal slots are full.")
		return
	end
	table.remove(db.candidates, idx)
	table.insert(db.invited, { name = name, role = cand.role or "?", aura = cand.aura, status = "Pending", inviteTime = GetTime() })
	local ok = pcall(InviteUnit, name)
	if ok then
		print(PREFIX .. "Invited " .. name .. " (" .. (cand.role or "?") .. (cand.aura and " - Aura" or "") .. ")")
	else
		print(PREFIX .. "Could not invite " .. name)
	end
	RefreshAll()
end

local function TryAutoInvite(name, fromChannel)
	local _, cand = FindCandidate(name)
	if not cand then
		return false
	end
	local t, h, d, a, tot = GetCounts()
if tot >= MAX_TOTAL then
		if not fromChannel then
			pcall(SendChatMessage, REJECT_GROUP_FULL, "WHISPER", nil, name)
		end
		return false
	end
	local noRole = cand.role == nil or cand.role == "?"
	if noRole then
		-- No role stated: only auto-invite when they bring an aura and an aura slot is open.
		if cand.aura == true and a < MAX_AURA then
			print(PREFIX .. "Aura slot available for " .. name .. " (no role stated), auto-inviting.")
			InvitePlayer(name)
			return true
		end
		return false
	end
	local role = cand.role
	local rejected = false
	local rejectAura = false
	local auraLastDps = cand.aura == true and d == MAX_DPS - 1
	if role == "Tank" then
		rejected = t >= MAX_TANK and not auraLastDps
	elseif role == "Heal" then
		rejected = h >= MAX_HEAL and not auraLastDps
	elseif role == "DPS" then
		-- DPS without an aura may fill up to the base limit (7 = MAX_DPS - MAX_AURA).
		-- When auras are missing we reserve even more slots for DPS with an Aura:
		-- e.g. 2 auras missing -> 3 slots reserved, 3 auras missing -> 4 slots reserved.
		local missing = math.max(0, MAX_AURA - a)
		local auraReserve = missing + 1
		if auraReserve < MAX_AURA then
			auraReserve = MAX_AURA
		end
		if cand.aura == true then
			-- Aura DPS can always fill an open DPS slot, even when we already have 3+ auras.
			rejected = d >= MAX_DPS
		else
			rejected = d >= (MAX_DPS - auraReserve)
			rejectAura = rejected and a < MAX_AURA
		end
	else
		return false
	end
	if rejected then
		if not fromChannel then
			if rejectAura then
				pcall(SendChatMessage, REJECT_AURA, "WHISPER", nil, name)
			else
				pcall(SendChatMessage, REJECT_ROLE_FULL, "WHISPER", nil, name)
			end
		end
		return false
	end
	print(PREFIX .. "Room available for " .. name .. " (" .. role .. "), auto-inviting.")
	InvitePlayer(name)
	return true
end

function LoadRaid()
	if not IsInRaid() then
		EnsureRaid()
	end
	if not IsInRaid() then
		print(PREFIX .. "You are not in a raid.")
		return
	end
	wipe(db.candidates)
	wipe(db.invited)
	wipe(memberReplies)
	SetCollecting(true)
	SendChatMessage("MSLeveling: reply with '1' Tank, '2' Heal, '3' Aura (e.g. '1 3'). No reply = DPS without aura.", "RAID_WARNING")
	RefreshAll()
	RefreshMTButtons()
	print(PREFIX .. "Raid started: reply in raid chat with 1 (Tank), 2 (Heal), 3 (Aura), e.g. '1 3'. Press 'Finish Count' when everyone has replied.")
end

local function FinalizeCollect()
	if not collecting then
		return
	end
	SetCollecting(false)
	wipe(db.invited)
	local pname = UnitName("player")
	local count = 0
	if IsInRaid() then
		for i = 1, GetNumRaidMembers() do
			local name = GetRaidRosterInfo(i)
			if name then
				name = name:gsub("%-.*", "")
				if name ~= pname then
					local rep = memberReplies[name]
					table.insert(db.invited, {
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
	for _, inv in ipairs(db.invited) do
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
	wipe(db.candidates)
	wipe(db.invited)
	wipe(memberReplies)
	wipe(flaggedPlayers)
	SetCollecting(false)
	print(PREFIX .. "List reset.")
	RefreshAll()
end

local function BuildNeedsList(t, h, d, a, tot)
	local missing = MAX_TOTAL - tot
	if missing <= 0 or missing > 3 then
		return nil
	end
	local roleIcons = { AURA = "{triangle}", Tank = "{circle}", Healer = "{square}", DPS = "{skull}" }
	local needTank = math.max(0, MAX_TANK - t)
	local needHeal = math.max(0, MAX_HEAL - h)
	local needAura = math.max(0, MAX_AURA - a)
	local needDPS = math.max(0, missing - needTank - needHeal - needAura)
	local items = {}
	if needAura > 0 then items[#items + 1] = { needAura, "AURA" } end
	if needTank > 0 then items[#items + 1] = { needTank, "Tank" } end
	if needHeal > 0 then items[#items + 1] = { needHeal, "Healer" } end
	if needDPS > 0 and (needTank > 0 or needHeal > 0) then items[#items + 1] = { needDPS, "DPS" } end
	local parts = {}
	local remaining = missing
	for _, item in ipairs(items) do
		if remaining <= 0 then
			break
		end
		local n = math.min(item[1], remaining)
		remaining = remaining - n
		parts[#parts + 1] = (roleIcons[item[2]] or "") .. n .. " " .. item[2]
	end
	if #parts == 0 then
		return nil
	end
	return table.concat(parts, " | ")
end

local function BroadcastLFM()
	local t, h, d, a, tot = GetCounts()
	local missing = MAX_TOTAL - tot
	local needs = BuildNeedsList(t, h, d, a, tot)
	local msg, preview
	if needs then
		local prefix = "LF" .. missing .. "M"
		msg = string.format("%s MS Leveling %s - reply role + (aura)", prefix, needs)
		preview = string.format("|cffffd000[MS Leveling]|r |cff66b3ff%s|r MS Leveling %s |cff66b3ff- reply role + (aura)|r", prefix, needs)
	else
		local prefix = "LFM"
		if tot == MAX_TOTAL - 1 and a == MAX_AURA - 1 then
			prefix = "LF1M AURA AND GO"
		end
		msg = string.format("%s MS Leveling: {circle}Tank %d/%d {square}Heal %d/%d {skull}DPS %d/%d {triangle}Aura %d/%d - reply role + aura/no", prefix, t, MAX_TANK, h, MAX_HEAL, d, MAX_DPS, a, MAX_AURA)
		preview = string.format(
			"|cffffd000[MS Leveling]|r |cff66b3ff%s|r MS Leveling: {circle}|cff66b3ffTank|r |cff%s%d/%d|r {square}|cff66b3ffHeal|r |cff%s%d/%d|r {skull}|cff66b3ffDPS|r |cff%s%d/%d|r {triangle}|cff66b3ffAura|r |cff%s%d/%d|r |cff66b3ffreply role + aura/no|r",
			prefix,
			CountColor(t, MAX_TANK), t, MAX_TANK,
			CountColor(h, MAX_HEAL), h, MAX_HEAL,
			CountColor(d, MAX_DPS), d, MAX_DPS,
			CountColor(a, MAX_AURA), a, MAX_AURA
		)
	end
	local sent = 0
	local failed = {}
	local channelNames = {}
	local joined = {}
	for i = 1, 50 do
		local num, name = GetChannelName(i)
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
	local now = GetTime()
	for i = #db.invited, 1, -1 do
		local inv = db.invited[i]
		if inv.status == "Pending" and inv.inviteTime and (now - inv.inviteTime) > 90 and not names[inv.name] then
			print(PREFIX .. inv.name .. " did not accept the invite (timed out), slot freed.")
			table.remove(db.invited, i)
			changed = true
		end
	end
	for i = #db.invited, 1, -1 do
		local inv = db.invited[i]
		if inv.status == "Joined" and not names[inv.name] then
			print(PREFIX .. inv.name .. " left the raid, removed from the invited list.")
			table.remove(db.invited, i)
			changed = true
		end
	end
	for _, inv in ipairs(db.invited) do
		local st = names[inv.name] and "Joined" or "Pending"
		if st ~= inv.status then
			inv.status = st
			changed = true
			if st == "Joined" and inv.welcomed ~= true then
				inv.welcomed = true
				local welcome
				if inv.role == "Tank" then
					welcome = WELCOME_TANK
				elseif inv.role == "Heal" then
					welcome = WELCOME_HEAL
				else
					welcome = WELCOME_OTHER
				end
				pcall(SendChatMessage, welcome, "WHISPER", nil, inv.name)
			end
		end
	end
	for i = #db.candidates, 1, -1 do
		if names[db.candidates[i].name] then
			table.remove(db.candidates, i)
			changed = true
		end
	end
	if changed then
		RefreshAll()
	end
	if CheckDepartures then
		CheckDepartures()
	end
end

function CleanLeavers(silent)
	if not IsInRaid() then
		if not silent then
			print(PREFIX .. "You are not in a raid.")
		end
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
	for i = #db.invited, 1, -1 do
		local inv = db.invited[i]
		if not names[inv.name] then
			print(PREFIX .. inv.name .. " left the group, removed from the invited list.")
			table.remove(db.invited, i)
			removed = removed + 1
		end
	end
	local added = 0
	local registered = {}
	for _, inv in ipairs(db.invited) do
		registered[inv.name] = true
	end
	for n in pairs(names) do
		if n ~= pname and not registered[n] then
			table.insert(db.invited, { name = n, role = "DPS", aura = false, status = "Joined" })
			print(PREFIX .. n .. " was in the raid but not registered, added as DPS.")
			added = added + 1
		end
	end
	if removed == 0 and added == 0 then
		if not silent then
			print(PREFIX .. "No changes: everyone on the invited list is still in the raid.")
		end
	end
	RefreshAll()
	RefreshMTButtons()
end

local lastRaidRoster = {}
local rosterSeen = false

local MT_ICONS = { 6, 2, 3, 4, 1, 5, 7, 8 }

local function BuildRoleInfo()
	local info = {}
	local pname = UnitName("player")
	if pname then
		info[pname:gsub("%-.*", "")] = { role = db.me.role, aura = db.me.aura }
	end
	for _, inv in ipairs(db.invited) do
		info[inv.name] = info[inv.name] or {}
		info[inv.name].role = inv.role
		info[inv.name].aura = inv.aura
	end
	return info
end

-- Places the tank icon on every Tank currently in the raid, using the live
-- roster (not a snapshot). Safe to re-run whenever the roster changes so a
-- Tank that joins right after the auto-sort still gets its icon.
function ApplyRaidIcons()
	if not IsInRaid() then
		return
	end
	if not (IsRaidLeader() or IsRaidOfficer()) then
		return
	end
	local info = BuildRoleInfo()
	local tankIndex = 0
	for i = 1, GetNumRaidMembers() do
		local n = GetRaidRosterInfo(i)
		if n then
			local name = n:gsub("%-.*", "")
			if info[name] and info[name].role == "Tank" then
				tankIndex = tankIndex + 1
				if SetRaidTargetIcon then
					pcall(SetRaidTargetIcon, "raid" .. i, MT_ICONS[tankIndex] or MT_ICONS[1])
				end
			end
		end
	end
end

function SyncRaidRoster()
	local now = {}
	if IsInRaid() then
		for i = 1, GetNumRaidMembers() do
			local n = GetRaidRosterInfo(i)
			if n then
				now[n:gsub("%-.*", "")] = true
			end
		end
	end
	local changed = false
	if rosterSeen then
		for n in pairs(lastRaidRoster) do
			if not now[n] then
				changed = true
				break
			end
		end
		if not changed then
			for n in pairs(now) do
				if not lastRaidRoster[n] then
					changed = true
					break
				end
			end
		end
	end
	rosterSeen = true
	lastRaidRoster = now
	if changed and IsInRaid() then
		CleanLeavers(true)
	end
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
	for _, inv in ipairs(db.invited) do
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
		ApplyRaidIcons()
		local mtCommands = {}
		for _, n in ipairs(roster) do
			if info[n] and info[n].role == "Tank" then
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
		local c = db.candidates[idx]
		if role then
			c.role = role
		end
		if aura ~= nil then
			c.aura = aura
		end
		c.time = GetTime()
	else
		table.insert(db.candidates, { name = name, role = role or "?", aura = aura, time = GetTime() })
	end
end

-- Returns true when there is a free slot for this role/aura combo right now,
-- mirroring the invite-capacity logic (tank/heal caps, DPS aura-reserve spots).
local function HasSlot(role, aura)
	local t, h, d, a, tot = GetCounts()
	if tot >= MAX_TOTAL then
		return false, REJECT_GROUP_FULL
	end
	if role == "Tank" then
		if t >= MAX_TANK and not (aura == true and d == MAX_DPS - 1) then return false, REJECT_ROLE_FULL end
		return true
	elseif role == "Heal" then
		if h >= MAX_HEAL and not (aura == true and d == MAX_DPS - 1) then return false, REJECT_ROLE_FULL end
		return true
	elseif role == "DPS" then
		local missing = math.max(0, MAX_AURA - a)
		local auraReserve = missing + 1
		if auraReserve < MAX_AURA then
			auraReserve = MAX_AURA
		end
		if aura == true then
			-- Aura DPS can always fill an open DPS slot, even when we already have 3+ auras.
			if d >= MAX_DPS then
				return false, REJECT_ROLE_FULL
			end
		else
			if d >= (MAX_DPS - auraReserve) then
				return false, (a < MAX_AURA and REJECT_AURA or REJECT_ROLE_FULL)
			end
		end
		return true
	end
	-- Unclear role: don't discard, let the leader assign the slot later.
	return true
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
		if db.autoReply and (role or aura ~= nil) then
			SendChatMessage(REPLY_OK, "WHISPER", nil, name)
		end
		return
	end
	local isNew = not FindCandidate(name)
	UpsertCandidate(name, role, aura)
	if isNew then
		print(PREFIX .. "New candidate: " .. name .. " (" .. (role or "?") .. (aura == true and " - Aura" or aura == false and " - No aura" or "") .. ")")
	end
	RefreshAll()
	local hasSlot, rejectReason = true, nil
	if role then
		hasSlot, rejectReason = HasSlot(role, aura)
	end
	local invitedNow = false
	if (role or aura) and hasSlot then
		invitedNow = TryAutoInvite(name) or false
	end
	if db.autoReply then
		if not hasSlot and rejectReason then
			local now = GetTime()
			if not rejectSent[name] or now - rejectSent[name] >= 60 then
				rejectSent[name] = now
				pcall(SendChatMessage, rejectReason, "WHISPER", nil, name)
			end
		elseif not invitedNow and (role or aura ~= nil) then
			SendChatMessage(REPLY_OK, "WHISPER", nil, name)
		elseif not invitedNow then
			SendChatMessage(REPLY_HELP, "WHISPER", nil, name)
		end
	end
end

local function ChannelNumberFromName(channelName)
	local sn = (tostring(channelName) or ""):match("^%d+")
	if sn then
		local n = tonumber(sn)
		if n and n > 0 then
			return n
		end
	end
	local base = tostring(channelName or ""):gsub("^%d+%.?", ""):gsub("^%s*", ""):gsub("%s*$", ""):lower()
	if base ~= "" then
		for i = 1, 50 do
			local num, name = GetChannelName(i)
			if not name then
				break
			end
			local cleanName = name:gsub("^%d+%.?", ""):gsub("^%s*", ""):gsub("%s*$", ""):lower()
			if cleanName == base then
				return num
			end
		end
	end
	return 0
end

function HandleChannel(msg, author, language, channelName, target, flags, unknown, channelNumber)
	if not db.autoLFG then
		return
	end
	local name = (author or ""):gsub("%-.*", "")
	if name == "" then
		return
	end
	local pname = UnitName("player")
	if pname and name == pname:gsub("%-.*", "") then
		return
	end
	local chNum = tonumber(channelNumber) or ChannelNumberFromName(channelName)
	if not chNum or chNum == 0 then
		return
	end
	local selected = false
	for i = 1, 3 do
		local want = db.channels[i]
		if want and want > 0 and want == chNum then
			selected = true
			break
		end
	end
	if not selected then
		return
	end
local m = string.lower(msg or "")
	-- Only auto-invite people who are looking for a group (LFG / LF).
	-- Never invite recruiters advertising "Looking for More" (LFM / LF1M).
	if not (HasWord(m, "lfg") or HasWord(m, "lf")) then
		return
	end
	if HasWord(m, "lfm") or m:match("lf%d*m") then
		return
	end
	-- Only invite people looking for MS Leveling / Manastorm groups.
	-- Require at least one of these keywords so we don't pull in LFG for other raids.
	local msKeywords = { "msleveling", "ms leveling", "mslevel", "ms level", "msl", "manastorm", "mana storm" }
	local isMS = false
	for _, kw in ipairs(msKeywords) do
		if HasWord(m, kw) then
			isMS = true
			break
		end
	end
	-- Also accept bare "ms" when it appears as a standalone word (not part of another word)
	if not isMS and HasWord(m, "ms") then
		isMS = true
	end
	if not isMS then
		return
	end
	local role = DetectRole(m)
	local aura = DetectAura(m)
	if role == nil and aura == nil then
		return
	end
	if FindInvited(name) then
		return
	end
	local has, _ = HasSlot(role, aura)
	if not has then
		return
	end
	local isNew = not FindCandidate(name)
	UpsertCandidate(name, role, aura)
	if isNew then
		local _, c = FindCandidate(name)
		print(PREFIX .. "LFG channel: new candidate: " .. name .. " (" .. (c.role or "?") .. (c.aura and " - Aura" or " - Without aura") .. ")")
	end
	RefreshAll()
	TryAutoInvite(name, true)
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

RemoveInvited = function(name)
	for i, inv in ipairs(db.invited) do
		if inv.name == name then
			table.remove(db.invited, i)
			break
		end
	end
	print(PREFIX .. name .. " removed from invited.")
	RefreshAll()
end

local farewellSent = {}

SendFarewell = function(name, reason, full)
	if not name or name == "" then return end
	local now = GetTime()
	if farewellSent[name] and now - farewellSent[name] < 60 then return end
	farewellSent[name] = now
	local msg
	if full then
		msg = full
	elseif reason then
		msg = reason .. " " .. FAREWELL_MSG
	else
		msg = FAREWELL_MSG
	end
	local ok = pcall(SendChatMessage, msg, "WHISPER", nil, name)
	if not ok then
		print(PREFIX .. "Could not send farewell whisper to " .. name)
	end
end

local pendingKicks = {}

function DoKickPlayer(name, reason)
	local ok = UninviteUnit(name)
	if ok then
		RemoveInvited(name)
		SendFarewell(name, reason or "You have been removed from the raid.")
		print(PREFIX .. "Kicked " .. name .. " from the raid.")
	else
		print(PREFIX .. "Could not kick " .. name .. " (protected action, kick manually).")
	end
end

function KickPlayer(name, reason)
	if InCombatLockdown() or (UnitAffectingCombat and UnitAffectingCombat("player")) then
		pendingKicks[#pendingKicks + 1] = { name = name, reason = reason }
		return
	end
	DoKickPlayer(name, reason)
end

function FlushPendingKicks()
	local list = pendingKicks
	pendingKicks = {}
	for i = 1, #list do
		DoKickPlayer(list[i].name, list[i].reason)
	end
end

function CheckRaidLevels()
	if not IsInRaid() then
		fastLevelPoll = false
		return false, false
	end
	if not IsRaidLeader() and not IsRaidOfficer() then
		fastLevelPoll = false
		return false, false
	end
	local pname = (UnitName("player") or ""):gsub("%-.*", "")
	local present = {}
	local has59 = false
	local has60 = false
	for i = 1, GetNumRaidMembers() do
		local n = GetRaidRosterInfo(i)
		if n then
			n = n:gsub("%-.*", "")
			present[n] = true
			if n ~= pname then
				local _, _, _, rosterLevel = GetRaidRosterInfo(i)
				local lvl = UnitLevel and UnitLevel("raid" .. i) or rosterLevel
				if (not lvl or lvl < 1) and rosterLevel then
					lvl = rosterLevel
				end
			if lvl and lvl >= 59 then
				if lvl >= 60 then
					has60 = true
					if not flaggedPlayers[n] or flaggedPlayers[n].reason ~= FLAG_LVL60 then
						FlagPlayer(n, FLAG_LVL60)
						SendChatMessage("[MSL] " .. n .. " reached LEVEL 60.", "RAID_WARNING")
					end
				else
					has59 = true
					if not flaggedPlayers[n] or flaggedPlayers[n].reason ~= FLAG_LVL59 then
						FlagPlayer(n, FLAG_LVL59)
						SendChatMessage("[MSL] " .. n .. " reached LEVEL 59.", "RAID_WARNING")
					end
				end
			else
				UnflagPlayer(n)
			end
			end
		end
	end
	for n in pairs(flaggedPlayers) do
		if not present[n] then UnflagPlayer(n) end
	end
	fastLevelPoll = has59
	return has59, has60
end

-- ===== Feature buttons: Ready Check / Enter MS1 / Disband+Re-invite / Anti-leech =====

local tickOptions = {}

local function After(delay, fn)
	tickOptions[#tickOptions + 1] = { delay = delay, elapsed = 0, fn = fn }
end

local pendingFrameShow = nil

ApplyFrameToggle = function()
	if pendingFrameShow == nil then
		return
	end
	local show = pendingFrameShow
	pendingFrameShow = nil
	if f then
		local ok = pcall(function()
			if show then
				f:Show()
				f:Raise()
			else
				f:Hide()
			end
		end)
		if not ok then
			pendingFrameShow = show
		end
	end
end

-- Toggle de la ventana principal. El frame contiene botones seguros (SecureActionButton),
-- asi que Show/Hide en combate esta bloqueado por el cliente (taint) y pcall no lo captura.
-- Se difiere SIEMPRE a PLAYER_REGEN_ENABLED cuando hay combate activo.
FrameToggleRequest = function(show)
	if f then
		if InCombatLockdown() then
			pendingFrameShow = show
			return
		end
		local ok = pcall(function()
			if show then
				f:Show()
				f:Raise()
			else
				f:Hide()
			end
			if flagPanel then
				if not show then
					flagPanel:Hide()
				elseif next(flaggedPlayers) then
					flagPanel:Show()
				end
			end
		end)
		if ok then
			pendingFrameShow = nil
			return
		end
	end
	pendingFrameShow = show
end

-- Detect when a member actually leaves the raid and send the farewell then,
-- instead of when the user clicks "Update raid".
function CheckDepartures()
	if not IsInRaid() then
		wipe(lastRosterNames)
		return
	end
	local current = {}
	for i = 1, GetNumRaidMembers() do
		local n = GetRaidRosterInfo(i)
		if n then
			current[n:gsub("%-.*", "")] = true
		end
	end
	local pname = UnitName("player")
	if pname then
		current[pname:gsub("%-.*", "")] = true
	end
	local removed = false
	for i = #db.invited, 1, -1 do
		local inv = db.invited[i]
		if not current[inv.name] and lastRosterNames[inv.name] then
			table.remove(db.invited, i)
			removed = true
			print(PREFIX .. inv.name .. " left the group, removed from the invited list.")
			if not farewellScheduled[inv.name] then
				farewellScheduled[inv.name] = true
				After(5, function()
					farewellScheduled[inv.name] = nil
					SendFarewell(inv.name, "Thank you for participating!")
				end)
			end
			RefreshAll()
		end
	end
	if removed then
		CleanLeavers(true)
	end
	local _, name
	for name in pairs(current) do
		lastRosterNames[name] = true
	end
	for name in pairs(lastRosterNames) do
		if not current[name] then
			lastRosterNames[name] = nil
		end
	end
end

local AFK_CHECK_INTERVAL = 20
local AFK_WINDOW = 35
local afkCheckAccum = 0
local levelPollAccum = 0
local fastLevelPoll = false
local autoLFMAccum = 0

local timerFeature = CreateFrame("Frame", "MSL201bFeatureTimer")
local dragStuckGrace = 0
timerFeature:SetScript("OnUpdate", function(self, dt)
	if frameDragging then
		if not IsMouseButtonDown("LeftButton") then
			dragStuckGrace = dragStuckGrace + dt
			if dragStuckGrace > 0.15 then
				frameDragging = false
				dragStuckGrace = 0
				if f then
					f:StopMovingOrSizing()
					local _, _, x, y = f:GetPoint(1)
					db.framePos = { x, y }
				end
			end
		else
			dragStuckGrace = 0
		end
	else
		dragStuckGrace = 0
	end
	for i = #tickOptions, 1, -1 do
		local t = tickOptions[i]
		t.elapsed = t.elapsed + dt
		if t.elapsed >= t.delay then
			table.remove(tickOptions, i)
			if t.fn then
				t.fn()
			end
		end
	end
	if CheckAFKActivity then
		afkCheckAccum = afkCheckAccum + dt
		if afkCheckAccum >= AFK_CHECK_INTERVAL then
			afkCheckAccum = 0
			CheckAFKActivity()
		end
	end
	if CheckRaidLevels then
		levelPollAccum = levelPollAccum + dt
		local interval = fastLevelPoll and 0.5 or 2
		if levelPollAccum >= interval then
			levelPollAccum = 0
			CheckRaidLevels()
		end
	end
	if db.autoLFM then
		autoLFMAccum = autoLFMAccum + dt
		if autoLFMAccum >= 30 then
			autoLFMAccum = 0
			BroadcastLFM()
		end
	end
	if RefreshFlagPanel then
	if flagPanel and flagPanel:IsShown() then
		RefreshFlagPanel()
	end
	end
end)

function DoFeatureReady()
	if not IsInRaid() then
		print(PREFIX .. "You are not in a raid.")
		return
	end
	SendChatMessage(PREFIX .. "Ready check initiated - please confirm.", "RAID_WARNING")
	pcall(DoReadyCheck)
end

function HandleReadyCheck(event, unit)
	if event == "READY_CHECK" then
		print(PREFIX .. "Ready check is running, confirm when prompted.")
	end
end

-- Leech detection: track who actually contributes damage/healing while raiding.

local leechContributed = {}
local leechStrikes = {}
local raidBattled = false
local lastHit = {}
local lastManastormState = nil
local lastAntileechAnnounce = 0

function LeechCombat(...)
	if not db.antileech then
		return
	end
	local _, subevent, _, sourceGUID, sourceName = ...
	if not subevent or type(sourceName) ~= "string" or sourceName == "" then
		return
	end
	if subevent:match("_DAMAGE") or subevent:match("_HEAL") or subevent:match("_LEECH") then
		raidBattled = true
		local name = sourceName:gsub("%-.*", "")
		if name ~= UnitName("player") then
			leechContributed[name] = true
			lastHit[name] = GetTime()
		end
	end
end

local IDLE_FLAG_THRESHOLD = 45

local function KickAFK(name)
	local last = lastHit[name]
	if not last then
		FlagPlayer(name, FLAG_IDLE)
		return true
	end
	local idleSec = GetTime() - last
	if idleSec >= IDLE_FLAG_THRESHOLD then
		FlagPlayer(name, FLAG_IDLE)
		return true
	else
		UnflagPlayer(name)
		return false
	end
end

local function PlayerIsActive(name, now)
	local last = lastHit[name]
	return last and (now - last) <= AFK_WINDOW
end

function AnnounceIdle()
	if not IsInRaid() then
		print(PREFIX .. "You are not in a raid.")
		return
	end
	local now = GetTime()
	local pname = (UnitName("player") or ""):gsub("%-.*", "")
	local idleList = {}
	for i = 1, GetNumRaidMembers() do
		local n = GetRaidRosterInfo(i)
		if n then
			local name = n:gsub("%-.*", "")
			if name ~= pname then
				local last = lastHit[name]
				if not last or (now - last) >= IDLE_FLAG_THRESHOLD then
					local idleSec = last and math.floor(now - last) or "?"
					idleList[#idleList + 1] = name .. " (" .. idleSec .. "s)"
				end
			end
		end
	end
	if #idleList == 0 then
		SendChatMessage("MSLeveling: All raid members are active (dealing damage or healing).", "RAID_WARNING")
	else
		SendChatMessage("MSLeveling: IDLE players (no damage/healing for 45s+): " .. table.concat(idleList, ", "), "RAID_WARNING")
	end
end

local afkSeen = {}
local afkAnnounced = {}

function CheckAFKActivity()
	if not db.antileech then
		return
	end
	if not IsInRaid() then
		return
	end
	local now = GetTime()
	local pname = (UnitName("player") or ""):gsub("%-.*", "")
	local members = {}
	local activeAny = false
	for i = 1, GetNumRaidMembers() do
		local n = GetRaidRosterInfo(i)
		if n then
			local name = n:gsub("%-.*", "")
			members[name] = true
			if name ~= pname and PlayerIsActive(name, now) then
				activeAny = true
			end
		end
	end
	-- Clean up data of players who are no longer in the raid:
	for name in pairs(lastHit) do
		if not members[name] then lastHit[name] = nil end
	end
	for name in pairs(afkSeen) do
		if not members[name] then afkSeen[name] = nil end
	end
	for name in pairs(flaggedPlayers) do
		if not members[name] then UnflagPlayer(name) end
	end
	for name in pairs(afkAnnounced) do
		if not members[name] then afkAnnounced[name] = nil end
	end
	-- If nobody in the raid is actively fighting, this is an idle/lobby period:
	-- don't penalize anyone (avoids waves of false positives between pulls).
	if not activeAny then
		return
	end

	local newlyIdle = {}
	for i = 1, GetNumRaidMembers() do
		local n = GetRaidRosterInfo(i)
		if n then
			local name = n:gsub("%-.*", "")
			if name ~= pname then
				if not afkSeen[name] then
					afkSeen[name] = now
				end
				if (now - afkSeen[name]) >= AFK_CHECK_INTERVAL then
					local isIdle = KickAFK(name)
					if isIdle then
						if not afkAnnounced[name] then
							newlyIdle[#newlyIdle + 1] = name
							afkAnnounced[name] = true
						end
					else
						afkAnnounced[name] = nil
					end
				end
			end
		end
	end
	if #newlyIdle > 0 then
		SendChatMessage("MSLeveling: AFK warning (no damage/healing for 45s+): " .. table.concat(newlyIdle, ", "), "RAID_WARNING")
	end
end

function CheckLeechLoads()
	if not db.antileech then
		return
	end
	if not IsInRaid() then
		return
	end
	-- If no real combat happened during this segment, never penalize anyone:
	-- otherwise the whole raid would "strike" on every idle load window.
	if not raidBattled then
		for k in pairs(leechContributed) do leechContributed[k] = nil end
		return
	end
	local pname = UnitName("player") or ""
	pname = pname:gsub("%-.*", "")
	for i = 1, GetNumRaidMembers() do
		local n = GetRaidRosterInfo(i)
		if n then
			local name = n:gsub("%-.*", "")
			if name ~= pname then
				if leechContributed[name] then
					leechStrikes[name] = 0
					UnflagPlayer(name)
				else
					leechStrikes[name] = (leechStrikes[name] or 0) + 1
					local strikes = leechStrikes[name]
					if strikes >= 2 then
						FlagPlayer(name, FLAG_LEECH)
					else
						UnflagPlayer(name)
					end
				end
				leechContributed[name] = nil
			end
		end
	end
	raidBattled = false
end

local function IsInsideManastorm()
	local ok, inside = pcall(function()
		if type(C_Manastorm) == "table" and type(C_Manastorm.IsInManastorm) == "function" then
			return C_Manastorm.IsInManastorm()
		end
		return nil
	end)
	if ok and inside then
		return true
	end
	return false
end

local function IsManastormZone()
	local ok, instance = pcall(GetInstanceInfo)
	if ok and instance then
		return tostring(instance):match("Manastorm")
	end
	return false
end

function CheckManastormEntry()
	local now = GetTime()
	if IsInsideManastorm() or IsManastormZone() then
		if lastManastormState ~= true then
			lastManastormState = true
			if db.antileech and IsInRaid() and now - lastAntileechAnnounce >= 600 then
				lastAntileechAnnounce = now
				SendChatMessage("Anti-leech is ACTIVE: perform real damage/healing or accumulate load screens. Warning after 2 idle loads, kick after 4.", "RAID_WARNING")
			end
		end
	elseif lastManastormState == true then
		lastManastormState = false
	end
end

function DoFeatureEnter()
	if not IsInRaid() then
		print(PREFIX .. "You must be in a raid to enter Group Manastorm.")
		return
	end
	local found = false
	-- 1) custom configured frame name
	local candidate = db.enterButtonName and type(db.enterButtonName) == "string" and _G[db.enterButtonName]
	if db.enterButtonName and candidate and candidate:GetObjectType() ~= "Button" then
		print(PREFIX .. "Configured button '" .. db.enterButtonName .. "' is not clickable.")
	end
	if candidate then
		found = true
		local ok = pcall(candidate.Click, candidate, "LeftButton")
		if ok then
			print(PREFIX .. "MS1 Enter pressed (" .. db.enterButtonName .. ").")
			return
		end
	end
	-- 2) Ascension's own API if present
	if type(C_Manastorm) == "table" and type(C_Manastorm.Enter) == "function" then
		found = true
		local ok = pcall(C_Manastorm.Enter, C_Manastorm)
		if ok then
			print(PREFIX .. "C_Manastorm.Enter called.")
			return
		end
	end
	-- 3) Ascension's Mana Storm panel button; open the panel first if hidden
	local native = _G.ManastormQueueFrameRightPanelEnterButton
	if native and native:GetObjectType() == "Button" then
		found = true
		local queueFrame = _G.ManastormQueueFrame
		if queueFrame and type(queueFrame.IsShown) == "function" and not queueFrame:IsShown() and type(queueFrame.Show) == "function" then
			pcall(queueFrame.Show, queueFrame)
		end
		local ok = pcall(native.Click, native, "LeftButton")
		if ok then
			print(PREFIX .. "Enter pressed (ManastormQueueFrameRightPanelEnterButton).")
			return
		end
	end
	-- 4) Manastormer's helper global if it is installed
	if type(ClickManastormEnter) == "function" then
		found = true
		local ok = pcall(ClickManastormEnter)
		if ok then
			print(PREFIX .. "Enter (ClickManastormEnter) done.")
			return
		end
	end
	if found then
		print(PREFIX .. "Could not trigger Enter Manastorm (protected while in combat?). Open Ascension's Mana Storm panel and click Enter Manastorm manually.")
	else
		print(PREFIX .. "No MS1 entry button found. Open Ascension's Mana Storm panel and click Enter Manastorm manually.")
	end
end

local disbandNames = {}
local disbandInfo = {}
local disbandPending = false

function DoFeatureDisband()
	if not IsInRaid() then
		print(PREFIX .. "Not in a raid.")
		return
	end
	if disbandPending then
		print(PREFIX .. "Disband already in progress.")
		return
	end
	wipe(disbandNames)
	wipe(disbandInfo)
	local selfName = (UnitName("player") or ""):gsub("%-.*", "")
	for i = 1, GetNumRaidMembers() do
		local n = GetRaidRosterInfo(i)
		if n then
			n = n:gsub("%-.*", "")
			if n ~= selfName then
				disbandNames[#disbandNames + 1] = n
				local inv = FindInvited(n)
				disbandInfo[n] = { role = (inv and inv.role) or "?", aura = inv and inv.aura }
				RemoveInvited(n)
			end
		end
	end
	SendChatMessage(PREFIX .. "Disbanding - re-inviting after leaving the dungeon.", "RAID_WARNING")
	local disbanded = false
	if type(DisbandRaid) == "function" then
		disbanded = DisbandRaid()
	end
	if not disbanded then
		for _, n in ipairs(disbandNames) do
			UninviteUnit(n)
		end
	end
	disbandPending = true
	local waitAnnounced = false
	local function TryReinvite()
		if not disbandPending then
			return
		end
		if IsInInstance() then
			if not waitAnnounced then
				waitAnnounced = true
				print(PREFIX .. "Waiting to leave the dungeon before re-inviting...")
			end
			After(2, TryReinvite)
			return
		end
		disbandPending = false
		local pending = {}
		for _, n in ipairs(disbandNames) do
			local info = disbandInfo[n] or {}
			if not FindInvited(n) then
				table.insert(db.invited, {
					name = n,
					role = info.role or "?",
					aura = info.aura,
					status = "Pending",
					inviteTime = GetTime(),
				})
			end
			pending[#pending + 1] = n
		end
		local function InviteList(list)
			local invited = 0
			for _, n in ipairs(list) do
				if pcall(InviteUnit, n) then
					invited = invited + 1
				end
			end
			return invited
		end
		local first = {}
		local rest = {}
		for i, n in ipairs(pending) do
			if i <= 4 then
				first[#first + 1] = n
			else
				rest[#rest + 1] = n
			end
		end
		EnsureRaid()
		local okCount = InviteList(first)
		local function FinishReinvite()
			okCount = okCount + InviteList(rest)
			print(PREFIX .. "Re-invited " .. okCount .. " player(s).")
			RefreshAll()
		end
		if #rest == 0 then
			FinishReinvite()
		else
			local tries = 0
			local function InviteRest()
				if not IsInRaid() and GetNumPartyMembers() >= 1 and not InCombatLockdown() then
					pcall(ConvertToRaid)
				end
				if IsInRaid() then
					FinishReinvite()
					return
				end
				tries = tries + 1
				if tries < 30 then
					After(1, InviteRest)
				else
					FinishReinvite()
					print(PREFIX .. "Could not convert the party to raid. Invite the remaining players manually.")
				end
			end
			After(1, InviteRest)
		end
	end
	After(3, TryReinvite)
end

local function StyleMSLButton(b)
	b:SetNormalTexture("Interface\\Buttons\\WHITE8X8")
	b:GetNormalTexture():SetVertexColor(0.12, 0.16, 0.23, 1)
	b:SetPushedTexture("Interface\\Buttons\\WHITE8X8")
	b:GetPushedTexture():SetVertexColor(0.06, 0.08, 0.12, 1)
	b:SetHighlightTexture("Interface\\Buttons\\WHITE8X8")
	b:GetHighlightTexture():SetVertexColor(0.22, 0.3, 0.42, 1)
	local fs = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	fs:SetAllPoints(b)
	fs:SetJustifyH("CENTER")
	fs:SetJustifyV("MIDDLE")
	fs:SetTextColor(0.82, 0.87, 0.95)
	b:SetFontString(fs)
	return b
end

local function CreateMSLButton(parent, text, w, h)
	local b = StyleMSLButton(CreateFrame("Button", nil, parent))
	b:SetSize(w, h)
	b:SetText(text or "")
	return b
end

local function CreateRow(parent, isCandidate)
	local row = CreateFrame("Frame", nil, parent)
	row:SetSize(300, ROW_HEIGHT)
	row.bg = row:CreateTexture(nil, "BACKGROUND")
	row.bg:SetAllPoints(row)
	row.bg:SetTexture(1, 1, 1, 0.05)
	row.bg:Hide()
	row:EnableMouse(true)
	row:SetScript("OnEnter", function(self)
		self.bg:Show()
	end)
	row:SetScript("OnLeave", function(self)
		self.bg:Hide()
	end)

	row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.name:SetPoint("LEFT", 4, 0)
	row.name:SetWidth(104)
	row.name:SetJustifyH("LEFT")

	row.role = CreateMSLButton(row, "", 38, ROW_HEIGHT - 6)
	row.role:SetPoint("LEFT", 112, 0)
	row.roleText = row.role:GetFontString()

	row.aura = CreateMSLButton(row, "", 42, ROW_HEIGHT - 6)
	row.aura:SetPoint("LEFT", 154, 0)
	row.auraText = row.aura:GetFontString()

	row.role:SetScript("OnClick", function(self)
		local d = self:GetParent().data
		if d then
			d.role = ROLE_CYCLE[d.role or "?"]
			RefreshAll()
		end
	end)
	row.aura:SetScript("OnClick", function(self)
		local d = self:GetParent().data
		if d then
			d.aura = not d.aura
			RefreshAll()
		end
	end)

	if isCandidate then
		row.action = CreateMSLButton(row, "Invite", 58, ROW_HEIGHT - 6)
		row.action:SetPoint("LEFT", 200, 0)
		row.actionText = row.action:GetFontString()
		row.action:SetScript("OnClick", function(self)
			local d = self:GetParent().data
			if d then
				InvitePlayer(d.name)
			end
		end)
	else
		row.status = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		row.status:SetPoint("LEFT", 196, 0)
		row.status:SetWidth(54)
		row.status:SetJustifyH("LEFT")
		row.kick = CreateMSLButton(row, "Remove", 46, ROW_HEIGHT - 6)
		row.kick:SetPoint("LEFT", 252, 0)
		row.kickText = row.kick:GetFontString()
		row.kick:SetScript("OnClick", function(self)
			local d = self:GetParent().data
			if d then
				RemoveInvited(d.name)
			end
		end)
	end
	return row
end

f = CreateFrame("Frame", "MSL201bFrame", UIParent)
f:SetSize(660, 870)
f:SetPoint("CENTER")
f:SetBackdrop({
	bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
	edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
	tile = true,
	tileSize = 16,
	edgeSize = 16,
	insets = { left = 4, right = 4, top = 4, bottom = 4 },
})
f:SetBackdropColor(THEME.bg[1], THEME.bg[2], THEME.bg[3], 0.96)
f:SetBackdropBorderColor(0.12, 0.18, 0.3, 1)
f:SetFrameStrata("DIALOG")
f:EnableMouse(true)
f:SetMovable(true)
f:RegisterForDrag("LeftButton")
f:SetClampedToScreen(true)
f:SetScript("OnDragStart", function(self)
	frameDragging = true
	self:StartMoving()
end)
f:SetScript("OnDragStop", function(self)
	self:StopMovingOrSizing()
	frameDragging = false
	local _, _, x, y = self:GetPoint(1)
	db.framePos = { x, y }
end)
f:SetScript("OnShow", function()
	RefreshAll()
end)

local headerBar = f:CreateTexture(nil, "BACKGROUND")
headerBar:SetTexture("Interface\\Buttons\\WHITE8X8")
headerBar:SetVertexColor(0.1, 0.15, 0.24, 1)
headerBar:SetPoint("TOPLEFT", 1, -1)
headerBar:SetPoint("TOPRIGHT", -1, -1)
headerBar:SetHeight(52)

local headerLine = f:CreateTexture(nil, "BACKGROUND")
headerLine:SetTexture("Interface\\Buttons\\WHITE8X8")
headerLine:SetVertexColor(THEME.gold[1], THEME.gold[2], THEME.gold[3], 0.85)
headerLine:SetPoint("TOPLEFT", 16, -48)
headerLine:SetPoint("TOPRIGHT", -16, -48)
headerLine:SetHeight(1)

title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
title:SetPoint("TOPLEFT", 18, -8)
title:SetText("|cff66b3ffMS Leveling 2.04|r")

local subtitle = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
subtitle:SetPoint("TOPLEFT", 18, -32)
subtitle:SetTextColor(0.55, 0.6, 0.7)
subtitle:SetText("Manastorm raid manager - by Bokuden")

local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
closeBtn:SetPoint("TOPRIGHT", -5, -5)
closeBtn:SetScript("OnClick", function()
	if FrameToggleRequest then
		FrameToggleRequest(false)
	end
end)

counts = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
counts:SetPoint("TOPLEFT", 16, -36)
counts:SetJustifyH("LEFT")
counts:Hide()

chips = {}
local chipWidth = 118
for i = 1, 5 do
	local chip = CreateFrame("Frame", nil, f)
	chip:SetSize(chipWidth, 58)
	chip:SetPoint("TOPLEFT", f, "TOPLEFT", 12 + (i - 1) * 128, -62)
	chip:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Buttons\\WHITE8X8",
		edgeSize = 1,
		insets = { left = 1, right = 1, top = 1, bottom = 1 },
	})
	chip:SetBackdropColor(THEME.panel2[1], THEME.panel2[2], THEME.panel2[3], 0.9)
	chip:SetBackdropBorderColor(THEME.border[1], THEME.border[2], THEME.border[3], 1)

	local label = chip:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	label:SetPoint("TOP", 0, -6)
	label:SetTextColor(THEME.gold[1], THEME.gold[2], THEME.gold[3])
	chip.label = label

	chip.num = chip:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	chip.num:SetPoint("CENTER", 0, 6)
	chip.num:SetText("0/0")

	chip.bar = chip:CreateTexture(nil, "ARTWORK")
	chip.bar:SetTexture("Interface\\Buttons\\WHITE8X8")
	chip.bar:SetWidth(chipWidth - 16)
	chip.bar:SetHeight(6)
	chip.bar:SetPoint("BOTTOM", 0, 6)
	chip.bar:SetVertexColor(1.0, 0.65, 0.2, 0.9)
	chip.barMax = chipWidth - 16

	chips[i] = chip
end
local chipDefs = { "TANKS", "HEALS", "DPS", "AURAS", "TOTAL" }
for i, chip in ipairs(chips) do
	chip.label:SetText(chipDefs[i])
end

local compRow = CreateFrame("Frame", nil, f)
compRow:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -128)
compRow:SetSize(620, 26)

local compLabel = compRow:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
compLabel:SetPoint("LEFT", 0, 1)
compLabel:SetTextColor(THEME.gold[1], THEME.gold[2], THEME.gold[3])
compLabel:SetText("Comp:")

local tankLbl = compRow:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
tankLbl:SetPoint("LEFT", 52, 1)
tankLbl:SetTextColor(0.85, 0.88, 0.95)
tankLbl:SetText("Tank")

local tankMinus = CreateMSLButton(compRow, "-", 24, 24)
tankMinus:SetPoint("LEFT", 92, 0)
local tankVal = compRow:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
tankVal:SetPoint("LEFT", 120, 0)
tankVal:SetWidth(34)
tankVal:SetJustifyH("CENTER")
tankVal:SetTextColor(1.0, 0.6, 0.3)
local tankPlus = CreateMSLButton(compRow, "+", 24, 24)
tankPlus:SetPoint("LEFT", 158, 0)

local healLbl = compRow:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
healLbl:SetPoint("LEFT", 210, 1)
healLbl:SetTextColor(0.85, 0.88, 0.95)
healLbl:SetText("Heal")
local healMinus = CreateMSLButton(compRow, "-", 24, 24)
healMinus:SetPoint("LEFT", 250, 0)
local healVal = compRow:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
healVal:SetPoint("LEFT", 278, 0)
healVal:SetWidth(34)
healVal:SetJustifyH("CENTER")
healVal:SetTextColor(0.3, 1.0, 0.5)
local healPlus = CreateMSLButton(compRow, "+", 24, 24)
healPlus:SetPoint("LEFT", 316, 0)

local dpsLbl = compRow:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
dpsLbl:SetPoint("LEFT", 372, 1)
dpsLbl:SetTextColor(0.85, 0.88, 0.95)
dpsLbl:SetText("DPS (auto)")
local dpsVal = compRow:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
dpsVal:SetPoint("LEFT", 448, 0)
dpsVal:SetWidth(44)
dpsVal:SetJustifyH("CENTER")
dpsVal:SetTextColor(1.0, 0.85, 0.2)

local function changeComp(key, delta, lo, hi)
	local v = math.max(lo, math.min(hi, (tonumber(db[key]) or lo) + delta))
	if db[key] ~= v then
		db[key] = v
		ApplyComp()
		RefreshCompLabels()
		RefreshAll()
		RefreshMTButtons()
	end
end
tankMinus:SetScript("OnClick", function() changeComp("compTank", -1, 1, 3) end)
tankPlus:SetScript("OnClick", function() changeComp("compTank", 1, 1, 3) end)
healMinus:SetScript("OnClick", function() changeComp("compHeal", -1, 1, 5) end)
healPlus:SetScript("OnClick", function() changeComp("compHeal", 1, 1, 5) end)

RefreshCompLabels = function()
	if tankVal then tankVal:SetText(MAX_TANK) end
	if healVal then healVal:SetText(MAX_HEAL) end
	if dpsVal then dpsVal:SetText(MAX_DPS) end
end
RefreshCompLabels()

RefreshCounts()

selfRow = CreateFrame("Frame", nil, f)
selfRow:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -296)
selfRow:SetSize(620, ROW_HEIGHT)

selfRow.name = selfRow:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
selfRow.name:SetPoint("LEFT", 8, 0)
selfRow.name:SetWidth(300)
selfRow.name:SetJustifyH("LEFT")

local selfRole = CreateMSLButton(selfRow, "", 70, ROW_HEIGHT - 6)
selfRole:SetPoint("LEFT", 320, 0)
selfRoleText = selfRole:GetFontString()
selfRole:SetScript("OnClick", function()
	db.me.role = ROLE_CYCLE[db.me.role or "?"]
	RefreshAll()
end)

local selfAura = CreateMSLButton(selfRow, "", 84, ROW_HEIGHT - 6)
selfAura:SetPoint("LEFT", 396, 0)
selfAuraText = selfAura:GetFontString()
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

local function CreateSectionTitle(y, text)
	local t = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	t:SetPoint("TOPLEFT", 12, y)
	t:SetTextColor(THEME.gold[1], THEME.gold[2], THEME.gold[3])
	t:SetText(text)
	return t
end

CreateSectionTitle(-158, "Form Raid")
CreateSectionTitle(-204, "Manage raid")
CreateSectionTitle(-250, "GO")

local lfmBtn = CreateMSLButton(f, "Post LFM", 96, 22)
lfmBtn:SetPoint("TOPLEFT", 12, -176)
lfmBtn:SetScript("OnClick", BroadcastLFM)

local autoLFMBtn = CreateMSLButton(f, db.autoLFM and "AutoLFM: On" or "AutoLFM: Off", 100, 22)
autoLFMBtn:SetPoint("LEFT", lfmBtn, "RIGHT", 6, 0)
autoLFMBtn:SetScript("OnClick", function(self)
	db.autoLFM = not db.autoLFM
	UpdateAutoButtons()
	print(PREFIX .. "Auto-LFM (auto-post every 30s): " .. (db.autoLFM and "ON" or "OFF"))
end)

local autoLFGBtn = CreateMSLButton(f, db.autoLFG and "Auto-LFG: ON" or "Auto-LFG: OFF", 106, 22)
autoLFGBtn:SetPoint("LEFT", autoLFMBtn, "RIGHT", 6, 0)
autoLFGBtn:SetScript("OnClick", function(self)
	db.autoLFG = not db.autoLFG
	UpdateAutoButtons()
	print(PREFIX .. "Auto-LFG (auto-invite from selected channels): " .. (db.autoLFG and "ON" or "OFF"))
end)

local autoBtn = CreateMSLButton(f, db.autoReply and "AutoReply: On" or "AutoReply: Off", 100, 22)
autoBtn:SetPoint("LEFT", autoLFGBtn, "RIGHT", 6, 0)
autoBtn:SetScript("OnClick", function(self)
	db.autoReply = not db.autoReply
	UpdateAutoButtons()
	print(PREFIX .. "Automatic whisper reply: " .. (db.autoReply and "enabled" or "disabled"))
end)

local raidBtn = CreateMSLButton(f, "Load Raid", 96, 22)
raidBtn:SetPoint("TOPLEFT", 12, -222)
raidBtn:SetScript("OnClick", LoadRaid)

finishBtn = CreateMSLButton(f, "Finish Count", 110, 22)
finishBtn:SetPoint("LEFT", raidBtn, "RIGHT", 6, 0)
finishBtn:SetScript("OnClick", FinalizeCollect)

local sortBtn = CreateMSLButton(f, "Sort Groups", 110, 22)
sortBtn:SetPoint("LEFT", finishBtn, "RIGHT", 6, 0)
sortBtn:SetScript("OnClick", SortGroups)

local cleanBtn = CreateMSLButton(f, "Update raid", 104, 22)
cleanBtn:SetPoint("LEFT", sortBtn, "RIGHT", 6, 0)
cleanBtn:SetScript("OnClick", function()
	CleanLeavers()
end)

UpdateAutoButtons = function()
	if autoLFMBtn then
		autoLFMBtn:SetText(db.autoLFM and "AutoLFM: On" or "AutoLFM: Off")
	end
	if autoLFGBtn then
		autoLFGBtn:SetText(db.autoLFG and "Auto-LFG: ON" or "Auto-LFG: OFF")
	end
	if autoBtn then
		autoBtn:SetText(db.autoReply and "AutoReply: On" or "AutoReply: Off")
	end
end
UpdateAutoButtons()

local fullWiped = false
local autoSortDone = false
CheckAutoOff = function()
	local _, _, _, _, tot = GetCounts()
	if tot >= MAX_TOTAL then
		if not fullWiped then
			fullWiped = true
			if #db.candidates > 0 then
				wipe(db.candidates)
				print(PREFIX .. "Raid complete (15/15), candidate list cleared.")
				RefreshCandidates()
			end
		end
		if not autoSortDone then
			autoSortDone = true
			if (IsRaidLeader() or IsRaidOfficer()) then
				print(PREFIX .. "Raid full, sorting groups automatically.")
				SendChatMessage("Raid full.", "RAID")
				SendChatMessage("Sorting groups in 3 seconds..", "RAID")
				After(3, function()
					SortGroups()
				end)
			end
		end
		if db.autoLFM then
			db.autoLFM = false
			print(PREFIX .. "Raid full (15/15), Auto-LFM disabled.")
		end
		if db.autoLFG then
			db.autoLFG = false
			print(PREFIX .. "Raid full (15/15), Auto-LFG disabled.")
		end
		UpdateAutoButtons()
	else
		fullWiped = false
		autoSortDone = false
	end
end

local resetBtn = CreateMSLButton(f, "Reset all data", 110, 22)
resetBtn:SetPoint("BOTTOMRIGHT", f, "TOPLEFT", 644, -662)
resetBtn:SetScript("OnClick", function()
	StaticPopup_Show("MSL201B_RESET")
end)

local manastormQueueFrame
local manastormEnterButton
local manastormLevelDropDown

local function ManastormFrameText(frame)
	if not frame then
		return ""
	end
	if type(frame.GetText) == "function" then
		local txt = frame:GetText()
		if txt then
			return tostring(txt)
		end
	end
	if type(frame.GetNumRegions) == "function" then
		for i = 1, frame:GetNumRegions() do
			local region = select(i, frame:GetRegions())
			if region and type(region.GetText) == "function" then
				local txt = region:GetText()
				if txt then
					return tostring(txt)
				end
			end
		end
	end
	return ""
end

local function ManastormFindEnterInChildren(frame, depth, seen)
	if not frame or seen[frame] or depth > 10 then
		return nil
	end
	seen[frame] = true
	if type(frame.GetObjectType) == "function" and frame:GetObjectType() == "Button"
		and ManastormFrameText(frame):match("Enter") then
		return frame
	end
	if type(frame.GetChildren) == "function" then
		local child
		for _, child in ipairs({ frame:GetChildren() }) do
			local found = ManastormFindEnterInChildren(child, depth + 1, seen)
			if found then
				return found
			end
		end
	end
	return nil
end

local function ResolveManastormFrames()
	local eb = _G.ManastormQueueFrameRightPanelEnterButton
	if eb and eb:GetObjectType() == "Button" then
		manastormQueueFrame = _G.ManastormQueueFrame
		manastormEnterButton = eb
		manastormLevelDropDown = _G.ManastormQueueFrameRightPanelLevelDropDown
		return manastormQueueFrame, manastormEnterButton, manastormLevelDropDown, true
	end
	if manastormEnterButton and manastormEnterButton:GetObjectType() == "Button" then
		return manastormQueueFrame, manastormEnterButton, manastormLevelDropDown, true
	end
	manastormQueueFrame, manastormEnterButton, manastormLevelDropDown = nil, nil, nil
	local foundAny = false
	for k, v in pairs(_G) do
		if type(v) == "table" and type(v.GetObjectType) == "function" and tostring(k):match("[Mm]anastorm") then
			foundAny = true
			local ot = v:GetObjectType()
			if ot == "Button" then
				local n = tostring(k)
				if n:match("Enter") then
					manastormEnterButton = v
				elseif n:match("DropDown") or n:match("Level") then
					manastormLevelDropDown = manastormLevelDropDown or v
				end
			elseif ot == "Frame" and not manastormQueueFrame then
				manastormQueueFrame = v
			end
		end
	end
	if not manastormEnterButton and manastormQueueFrame then
		manastormEnterButton = ManastormFindEnterInChildren(manastormQueueFrame, 0, {})
	end
	return manastormQueueFrame, manastormEnterButton, manastormLevelDropDown, foundAny
end

local function ManastormLevelOneSelected(dropdown)
	if not dropdown then
		return true
	end
	local txt = ManastormFrameText(dropdown)
	return txt and tonumber(txt:match("[Ll]evel%s*(%d+)")) == 1
end

local function GetManastormEnterState()
	local queueFrame, enterButton, dropdown, uiLoaded = ResolveManastormFrames()
	if not uiLoaded then
		return "noload"
	end
	if not queueFrame or not enterButton then
		return "missing"
	end
	if type(queueFrame.IsShown) == "function" and not queueFrame:IsShown() then
		if type(queueFrame.Show) == "function" then
			pcall(queueFrame.Show, queueFrame)
		end
		return "opened"
	end
	if not ManastormLevelOneSelected(dropdown) then
		return "level"
	end
	if type(enterButton.IsEnabled) == "function" and not enterButton:IsEnabled() then
		return "disabled"
	end
	return "ready", enterButton
end

function PrintManastormApi()
	print(PREFIX .. "Manastorm diagnostics:")
	local any = false
	for k, v in pairs(_G) do
		if type(v) == "table" and type(v.GetObjectType) == "function" and tostring(k):match("[Mm]anastorm") then
			any = true
			local shown = type(v.IsShown) == "function" and v:IsShown()
			print("  " .. k .. " (" .. v:GetObjectType() .. ")" .. (shown and " [shown]" or ""))
		end
	end
	if not any then
		print("  No Manastorm frames in _G. Open Ascension's Mana Storm panel, then run /mslv api again.")
	end
	local ok, detail = pcall(function()
		local qf, eb, dd, loaded = ResolveManastormFrames()
		return "resolved: loaded=" .. tostring(loaded) .. " queue=" .. tostring(qf and qf:GetName() or "nil") .. " enter=" .. tostring(eb and eb:GetName() or "nil") .. " dropdown=" .. tostring(dd and dd:GetName() or "nil")
	end)
	print("  " .. (ok and detail or "resolve error"))
end

local featureButtons = {}
local featureDefs = { { "Ready Check", "Ready" }, { "Enter MS 1", "EnterMS" }, { "Disband+Re-inv", "Disband" }, { "Anti-leech", "Anti" } }
for i, def in ipairs(featureDefs) do
	local b
	if def[2] == "EnterMS" then
		b = CreateFrame("Button", nil, f, "SecureActionButtonTemplate, UIPanelButtonTemplate")
		b:SetAttribute("type", "click")
		b:SetAttribute("clickbutton", nil)
		b:SetScript("PreClick", function(self)
			self:SetAttribute("clickbutton", nil)
			if not IsInRaid() then
				print(PREFIX .. "You must be in a raid to enter Group Manastorm.")
				return
			end
			local state, enterButton = GetManastormEnterState()
			if state == "ready" then
				self:SetAttribute("clickbutton", enterButton)
			elseif state == "opened" then
				print(PREFIX .. "Mana Storm panel opened. Select Level 1 on it, then click Enter MS 1 again.")
			elseif state == "level" then
				print(PREFIX .. "Select Level 1 on Ascension's Mana Storm panel first.")
			elseif state == "disabled" then
				print(PREFIX .. "Ascension's Enter Group Manastorm button is currently disabled.")
			elseif state == "noload" then
				print(PREFIX .. "Ascension's Mana Storm panel is not loaded. Open it once in-game (its own button/window), then click Enter MS 1 again. Run /mslv api if it still fails.")
			else
				print(PREFIX .. "Manastorm UI found but the Enter button is missing. Run /mslv api to inspect, or configure it with: /mslv enter <ButtonName>")
			end
		end)
		b:SetScript("PostClick", function(self)
			self:SetAttribute("clickbutton", nil)
		end)
	else
		b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	end
	StyleMSLButton(b)
	b:SetSize(110, 22)
	b:SetPoint("TOPLEFT", 12 + (i - 1) * 118, -268)
	b:SetText(def[1])
	if def[2] ~= "EnterMS" then
		b:SetScript("OnClick", function()
			if def[2] == "Ready" then
				DoFeatureReady()
			elseif def[2] == "Disband" then
				DoFeatureDisband()
			elseif def[2] == "Anti" then
				db.antileech = not db.antileech
				b:SetText(db.antileech and "Anti-leech" or "Anti-leech*")
				print(PREFIX .. "Anti-leech: " .. (db.antileech and "ON" or "OFF"))
			end
		end)
	end
	featureButtons[i] = b
end
refreshFeatureButtons = function()
	featureButtons[4]:SetText(db.antileech and "Anti-leech" or "Anti-leech*")
end
refreshFeatureButtons()

local mtLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
mtLabel:SetPoint("TOPLEFT", 16, -330)
mtLabel:SetTextColor(THEME.gold[1], THEME.gold[2], THEME.gold[3])
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
			for _, c in ipairs(db.invited) do
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
			b:SetSize(112, 24)
			b:SetPoint("TOPLEFT", 12 + (i - 1) * 118, -344)
			b:SetAttribute("type", "macro")
			mtButtons[i] = b
		end
		StyleMSLButton(b)
		b:SetText("MT: " .. name)
		b:SetAttribute("macrotext", "/maintank " .. name)
		b:Show()
	end
end
RefreshMTButtons()

local chLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
chLabel:SetPoint("TOPLEFT", 16, -376)
chLabel:SetTextColor(THEME.gold[1], THEME.gold[2], THEME.gold[3])
chLabel:SetText("LFM channels (click to change, 0 = none):")

local chButtons = {}
for i = 1, 3 do
	local b = CreateMSLButton(f, tostring(db.channels[i] or 0), 38, 24)
	b:SetPoint("TOPLEFT", 240 + (i - 1) * 44, -390)
	b:SetScript("OnClick", function(self)
		db.channels[i] = ((db.channels[i] or 0) + 1) % 11
		self:SetText(tostring(db.channels[i]))
	end)
	chButtons[i] = b
end

local hint = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
hint:SetPoint("BOTTOMLEFT", 16, 8)
hint:SetTextColor(0.55, 0.6, 0.7)
hint:SetText("Click Role/Aura to edit | /ms201b toggles | /ms201rw idle")

local function BuildListPanels()
local PANEL_LEFT = 8
local PANEL_MID = 328
local PANEL_RIGHT = 652
local PANEL_TOP = -420
local LIST_TOP = -446
local LIST_BOTTOM = -654

local function CreateListHeader(x, w, text)
	local bar = CreateFrame("Frame", nil, f)
	bar:SetPoint("TOPLEFT", f, "TOPLEFT", x, PANEL_TOP)
	bar:SetSize(w, 22)
	bar:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Buttons\\WHITE8X8",
		tile = true,
		tileSize = 8,
		edgeSize = 1,
		insets = { left = 1, right = 1, top = 1, bottom = 1 },
	})
	bar:SetBackdropColor(THEME.panel2[1], THEME.panel2[2], THEME.panel2[3], THEME.panel2[4])
	bar:SetBackdropBorderColor(0.4, 0.48, 0.65, 0.55)
	local title = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	title:SetPoint("LEFT", 8, 0)
	title:SetJustifyH("LEFT")
	title:SetTextColor(THEME.gold[1], THEME.gold[2], THEME.gold[3])
	title:SetText(text)
	return bar, title
end

local function CreateListToggle(bar)
	local b = CreateFrame("Button", nil, bar)
	b:SetSize(20, 20)
	b:SetPoint("RIGHT", -4, 0)
	b:SetNormalTexture("Interface\\Buttons\\WHITE8X8")
	b:GetNormalTexture():SetVertexColor(0.1, 0.15, 0.23, 1)
	b:SetPushedTexture("Interface\\Buttons\\WHITE8X8")
	b:GetPushedTexture():SetVertexColor(0.06, 0.08, 0.12, 1)
	b:SetHighlightTexture("Interface\\Buttons\\WHITE8X8")
	b:GetHighlightTexture():SetVertexColor(0.22, 0.3, 0.42, 1)
	local arrow = b:CreateTexture(nil, "OVERLAY")
	arrow:SetSize(14, 14)
	arrow:SetPoint("CENTER")
	b.arrow = arrow
	return b
end

local candBar, candHeader = CreateListHeader(PANEL_LEFT, PANEL_MID - PANEL_LEFT, "Candidates (whispers)")
local invBar, invHeader = CreateListHeader(PANEL_MID + 4, PANEL_RIGHT - (PANEL_MID + 4), "Invited")
local candToggle = CreateListToggle(candBar)
local invToggle = CreateListToggle(invBar)

local function SetListArrow(btn, expanded)
	btn.arrow:SetTexture(expanded and "Interface\\Buttons\\ArrowDown" or "Interface\\Buttons\\ArrowRight")
	btn.arrow:SetVertexColor(0.85, 0.9, 1, 1)
end

local function UpdateListPanelHeight()
	local collapsed = db.candCollapsed and db.invCollapsed
	local target = collapsed and 450 or 870
	if math.floor(f:GetHeight() + 0.5) ~= target then
		local px, py = f:GetLeft(), f:GetTop()
		f:ClearAllPoints()
		if px and py then
			f:SetPoint("TOPLEFT", UIParent, "TOPLEFT", px, py)
		else
			f:SetPoint("CENTER")
		end
		f:SetSize(660, target)
	end
	if hint then
		hint:SetShown(not collapsed)
	end
	if resetBtn then
		resetBtn:SetShown(not collapsed)
	end
end

local function SetCandCollapsed(collapsed)
	db.candCollapsed = collapsed
	candScroll:SetShown(not collapsed)
	for _, r in ipairs(candRows) do
		r:SetShown(not collapsed)
	end
	SetListArrow(candToggle, not collapsed)
	if not collapsed then
		RefreshCandidates()
	end
	UpdateListPanelHeight()
end

local function SetInvCollapsed(collapsed)
	db.invCollapsed = collapsed
	invScroll:SetShown(not collapsed)
	for _, r in ipairs(invRows) do
		r:SetShown(not collapsed)
	end
	SetListArrow(invToggle, not collapsed)
	if not collapsed then
		RefreshInvited()
	end
	UpdateListPanelHeight()
end

local vDivider = f:CreateTexture(nil, "BACKGROUND")
vDivider:SetTexture("Interface\\Buttons\\WHITE8X8")
vDivider:SetVertexColor(1, 1, 1, 0.12)
vDivider:SetPoint("TOP", f, "TOPLEFT", PANEL_MID, PANEL_TOP)
vDivider:SetPoint("BOTTOM", f, "TOPLEFT", PANEL_MID, LIST_BOTTOM)
vDivider:SetWidth(1)

candScroll = CreateFrame("ScrollFrame", "MSL201bCandScroll", f, "FauxScrollFrameTemplate")
candScroll:SetPoint("TOPLEFT", f, "TOPLEFT", PANEL_LEFT, LIST_TOP)
candScroll:SetPoint("TOPRIGHT", f, "TOPLEFT", PANEL_MID - 4, LIST_TOP)
candScroll:SetPoint("BOTTOMLEFT", f, "TOPLEFT", PANEL_LEFT, LIST_BOTTOM)
candScroll:SetPoint("BOTTOMRIGHT", f, "TOPLEFT", PANEL_MID - 4, LIST_BOTTOM)
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
	candRows[i]:SetPoint("TOPLEFT", f, "TOPLEFT", 10, LIST_TOP - (i - 1) * ROW_HEIGHT)
end

invScroll = CreateFrame("ScrollFrame", "MSL201bInvScroll", f, "FauxScrollFrameTemplate")
invScroll:SetPoint("TOPLEFT", f, "TOPLEFT", PANEL_MID + 4, LIST_TOP)
invScroll:SetPoint("TOPRIGHT", f, "TOPLEFT", PANEL_RIGHT, LIST_TOP)
invScroll:SetPoint("BOTTOMLEFT", f, "TOPLEFT", PANEL_MID + 4, LIST_BOTTOM)
invScroll:SetPoint("BOTTOMRIGHT", f, "TOPLEFT", PANEL_RIGHT, LIST_BOTTOM)
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
	invRows[i]:SetPoint("TOPLEFT", f, "TOPLEFT", 334, LIST_TOP - (i - 1) * ROW_HEIGHT)
end

candToggle:SetScript("OnClick", function()
	SetCandCollapsed(not db.candCollapsed)
end)
invToggle:SetScript("OnClick", function()
	SetInvCollapsed(not db.invCollapsed)
end)

SetCandCollapsed(db.candCollapsed)
SetInvCollapsed(db.invCollapsed)
end
BuildListPanels()

local LEECH_PANEL_WIDTH = 300
local LEECH_ROW_HEIGHT = 24
local LEECH_MAX_ROWS = 8

flagPanel = CreateFrame("Frame", "MSL201bFlagPanel", UIParent)
flagPanel:SetSize(LEECH_PANEL_WIDTH, 28 + LEECH_ROW_HEIGHT * LEECH_MAX_ROWS + 36)
flagPanel:SetFrameStrata("DIALOG")
flagPanel:SetBackdrop({
	bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
	edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
	tile = true,
	tileSize = 16,
	edgeSize = 16,
	insets = { left = 4, right = 4, top = 4, bottom = 4 },
})
flagPanel:SetBackdropColor(THEME.bg[1], THEME.bg[2], THEME.bg[3], THEME.bg[4])
flagPanel:SetBackdropBorderColor(0.8, 0.2, 0.2, 0.9)
flagPanel:SetPoint("CENTER", UIParent, "CENTER", 250, 0)
flagPanel:SetClampedToScreen(true)
flagPanel:EnableMouse(true)
flagPanel:SetMovable(true)
flagPanel:RegisterForDrag("LeftButton")
flagPanel:SetScript("OnDragStart", function(self) self:StartMoving() end)
flagPanel:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)

local flagHeaderBar = flagPanel:CreateTexture(nil, "BACKGROUND")
flagHeaderBar:SetTexture("Interface\\Buttons\\WHITE8X8")
flagHeaderBar:SetVertexColor(0.15, 0.05, 0.05, 1)
flagHeaderBar:SetPoint("TOPLEFT", 1, -1)
flagHeaderBar:SetPoint("TOPRIGHT", -1, -1)
flagHeaderBar:SetHeight(28)

local flagTitle = flagPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
flagTitle:SetPoint("TOPLEFT", 10, -8)
flagTitle:SetText("|cffff4444⚠ Leech / Lvl 59+ Warnings|r")

local flagClose = CreateFrame("Button", nil, flagPanel, "UIPanelCloseButton")
flagClose:SetPoint("TOPRIGHT", -2, -2)
flagClose:SetScript("OnClick", function() flagPanel:Hide() end)

flagScroll = CreateFrame("ScrollFrame", "MSL201bFlagScroll", flagPanel, "FauxScrollFrameTemplate")
flagScroll:SetPoint("TOPLEFT", 6, -30)
flagScroll:SetPoint("TOPRIGHT", flagPanel, "TOPRIGHT", -22, -30)
flagScroll:SetHeight(LEECH_ROW_HEIGHT * LEECH_MAX_ROWS)
flagScroll:SetScript("OnVerticalScroll", function(self, offset)
	FauxScrollFrame_OnVerticalScroll(self, offset, LEECH_ROW_HEIGHT, RefreshFlagPanel)
end)
flagScroll:EnableMouseWheel(true)
flagScroll:SetScript("OnMouseWheel", function(self, delta)
	local sb = _G[self:GetName() .. "ScrollBar"]
	sb:SetValue(sb:GetValue() - delta * LEECH_ROW_HEIGHT)
end)

local function CreateFlagRow(parent)
	local row = CreateFrame("Frame", nil, parent)
	row:SetSize(LEECH_PANEL_WIDTH - 30, LEECH_ROW_HEIGHT)
	row.bg = row:CreateTexture(nil, "BACKGROUND")
	row.bg:SetAllPoints(row)
	row.bg:SetTexture(1, 1, 1, 0.05)
	row.bg:Hide()
	row:EnableMouse(true)
	row:SetScript("OnEnter", function(self) self.bg:Show() end)
	row:SetScript("OnLeave", function(self) self.bg:Hide() end)

	row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.name:SetPoint("LEFT", 4, 0)
	row.name:SetWidth(110)
	row.name:SetJustifyH("LEFT")

	row.reason = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.reason:SetPoint("LEFT", 118, 0)
	row.reason:SetWidth(60)
	row.reason:SetJustifyH("LEFT")

	row.kick = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
	row.kick:SetSize(52, LEECH_ROW_HEIGHT - 4)
	row.kick:SetPoint("RIGHT", -4, 0)
	row.kickText = row.kick:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.kickText:SetAllPoints(row.kick)
	row.kickText:SetJustifyH("CENTER")
	row.kickText:SetJustifyV("MIDDLE")
	row.kickText:SetText("Kick")
	row.kick:SetScript("OnClick", function(self)
		local d = self:GetParent().data
		if d then
			KickFlagged(d.name)
		end
	end)

	return row
end

flagRows = {}
for i = 1, LEECH_MAX_ROWS do
	flagRows[i] = CreateFlagRow(flagPanel)
	flagRows[i]:SetPoint("TOPLEFT", flagPanel, "TOPLEFT", 6, -30 - (i - 1) * LEECH_ROW_HEIGHT)
end

function RefreshFlagPanel()
	local list = {}
	for name, info in pairs(flaggedPlayers) do
		list[#list + 1] = { name = name, reason = info.reason, since = info.since }
	end
	table.sort(list, function(a, b) return a.since < b.since end)
	local num = #list
	FauxScrollFrame_Update(flagScroll, num, LEECH_MAX_ROWS, LEECH_ROW_HEIGHT)
	local offset = FauxScrollFrame_GetOffset(flagScroll)
	for i = 1, LEECH_MAX_ROWS do
		local row = flagRows[i]
		local d = list[offset + i]
		if d then
			row:Show()
			row.data = d
			row.name:SetText(d.name)
			row.reason:SetText(d.reason)
			if d.reason == FLAG_IDLE then
				row.reason:SetTextColor(1.0, 0.5, 0.2)
			elseif d.reason == FLAG_LEECH then
				row.reason:SetTextColor(1.0, 0.3, 0.3)
			elseif d.reason == FLAG_LVL59 then
				row.reason:SetTextColor(1.0, 0.8, 0.2)
			else
				row.reason:SetTextColor(1.0, 0.2, 0.2)
			end
		else
			row:Hide()
			row.data = nil
		end
	end
end

flagPanel:SetScript("OnShow", function()
	RefreshFlagPanel()
end)

function ToggleFlagPanel()
	if flagPanel:IsShown() then
		flagPanel:Hide()
	else
		flagPanel:Show()
		RefreshFlagPanel()
	end
end

if not next(flaggedPlayers) then
	flagPanel:Hide()
end

StaticPopupDialogs["MSL201B_RESET"] = {
	text = "Reset all MS Leveling data? Candidates and invited players will be removed.",
	button1 = "Reset all data",
	button2 = "Cancel",
	timeout = 0,
	whileDead = 1,
	hideOnEscape = 1,
	preferredIndex = 3,
	OnAccept = function()
		ResetAll()
	end,
}

local mm = CreateFrame("Button", "MSL201bMinimapButton", Minimap)
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
	if FrameToggleRequest then
		if f:IsShown() then
			FrameToggleRequest(false)
		else
			FrameToggleRequest(true)
		end
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

SLASH_MSLV1 = "/ms201b"
SLASH_MSLV2 = "/msl2"
SLASH_MSLV3 = "/mslv"
SlashCmdList["MSLV"] = function(arg)
	arg = (arg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
	local cmd, rest = arg:match("^(%S+)%s*(.*)$")
	if cmd == "reset" then
		ResetAll()
	elseif cmd == "lfm" then
		BroadcastLFM()
	elseif cmd == "raid" then
		LoadRaid()
	elseif cmd == "enter" then
		local btn = rest:gsub("%s+$", "")
		if btn == "" then
			btn = db.enterButtonName
		end
		if not btn or btn == "" then
			print(PREFIX .. "Usage: /mslv enter <button-name>")
			return
		end
		db.enterButtonName = btn
		DoFeatureEnter()
	elseif cmd == "entersave" then
		local btn = rest:gsub("%s+$", "")
		if btn == "" then
			print(PREFIX .. "Usage: /mslv entersave <button-name>")
			return
		end
		db.enterButtonName = btn
		print(PREFIX .. "Enter button set to " .. btn)
	elseif cmd == "idle" or cmd == "rw" then
		AnnounceIdle()
	elseif cmd == "api" then
		PrintManastormApi()
	elseif cmd == "warnings" or cmd == "w" then
		if ToggleFlagPanel then ToggleFlagPanel() end
	else
		if FrameToggleRequest then
			if f:IsShown() then
				FrameToggleRequest(false)
			else
				FrameToggleRequest(true)
			end
		end
	end
end

SLASH_MSLVRW1 = "/ms201rw"
SlashCmdList["MSLRW"] = function()
	AnnounceIdle()
end

SLASH_MSLVW1 = "/msw"
SLASH_MSLVW2 = "/mswarnings"
SlashCmdList["MSLVW"] = function()
	if ToggleFlagPanel then ToggleFlagPanel() end
end

RefreshAll()
PositionMinimap()