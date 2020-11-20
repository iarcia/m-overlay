local bit = require("bit")
local ffi = require("ffi")
local log = require("log")
local process = require("memory." .. jit.os:lower())
local clones = require("games.clones")
local notification = require("notification")
local filesystem = love.filesystem

require("extensions.string")

local NULL = 0x00000000

local GAME_ID_ADDR  = 0x80000000
local GAME_VER_ADDR = 0x80000007
local GAME_ID_LEN   = 0x06
local GAME_NONE     = "\0\0\0\0\0\0"

local VC_ID_ADDR    = 0x80003180
local VC_ID_LEN     = 0x04
local VC_NONE       = "\0\0\0\0"

local memory = {
	gameid = GAME_NONE,
	vcid = VC_NONE,
	process = process,
	permissions = process:hasPermissions(),

	hooked = false,
	initialized = false,

	ingame = false,
	hooked = false,

	map = {},
	values = {},

	hooks = {},
	wildcard_hooks = {},

	hook_queue = {},
}

setmetatable(memory, {__index = memory.values})

local bswap = bit.bswap
local function bswap16(n)
	return bit.bor(bit.rshift(n, 8), bit.lshift(bit.band(n, 0xFF), 8))
end

function memory.readGameID()
	return memory.read(GAME_ID_ADDR, GAME_ID_LEN)
end

function memory.readVirtualConsoleID()
	return memory.read(VC_ID_ADDR, VC_ID_LEN)
end

function memory.readGameVersion()
	return memory.readUByte(GAME_VER_ADDR)
end

function memory.read(addr, len)
	local output = ffi.new("char[?]", len)
	local size = ffi.sizeof(output)
	process:read(addr, output, size)
	return ffi.string(output, size)
end

function memory.readByte(addr)
	if not process:hasProcess() then return 0 end
	local output = ffi.new("int8_t[1]")
	process:read(addr, output, ffi.sizeof(output))
	return output[0]
end

function memory.writeByte(addr, value)
	if not process:hasProcess() then return end
	local input = ffi.new("int8_t[1]", value)
	return process:write(addr, input, ffi.sizeof(input))
end

function memory.readBool(addr)
	if not process:hasProcess() then return false end
	return memory.readByte(addr) == 1
end

function memory.writeBool(addr, value)
	if not self:hasProcess() then return end
	self:writeByte(addr, value == true and 1 or 0)
end

function memory.readUByte(addr)
	if not process:hasProcess() then return 0 end
	local output = ffi.new("uint8_t[1]")
	process:read(addr, output, ffi.sizeof(output))
	return output[0]
end

function memory.writeUByte(addr, value)
	if not process:hasProcess() then return end
	local input = ffi.new("uint8_t[1]", value)
	return process:write(addr, input, ffi.sizeof(input))
end

function memory.readShort(addr)
	if not process:hasProcess() then return 0 end
	local output = ffi.new("int16_t[1]")
	process:read(addr, output, ffi.sizeof(output))
	return bswap16(output[0])
end

function memory.writeShort(addr, value)
	if not process:hasProcess() then return end
	local input = ffi.new("int16_t[1]", value)
	return process:write(addr, input, ffi.sizeof(input))
end

function memory.readUShort(addr)
	if not process:hasProcess() then return 0 end
	local output = ffi.new("uint16_t[1]")
	process:read(addr, output, ffi.sizeof(output))
	return bswap16(output[0])
end

function memory.writeUShort(addr, value)
	if not process:hasProcess() then return end
	local input = ffi.new("uint16_t[1]", value)
	return process:write(addr, input, ffi.sizeof(input))
end

do
	local floatconversion = ffi.new("union { uint32_t i; float f; }")

	function memory.readFloat(addr)
		if not process:hasProcess() then return 0 end
		local output = ffi.new("uint32_t[1]")
		process:read(addr, output, ffi.sizeof(output))
		floatconversion.i = bswap(output[0])
		return floatconversion.f, floatconversion.i
	end
end

function memory.writeFloat(addr, value)
	if not process:hasProcess() then return end
	local input = ffi.new("float[1]", value)
	return process:write(addr, input, ffi.sizeof(input))
end

function memory.readInt(addr)
	if not process:hasProcess() then return 0 end
	local output = ffi.new("int32_t[1]")
	process:read(addr, output, ffi.sizeof(output))
	return bswap(output[0])
end

function memory.writeInt(addr, value)
	if not process:hasProcess() then return end
	local input = ffi.new("int32_t[1]", value)
	return process:write(addr, input, ffi.sizeof(input))
end

function memory.readUInt(addr)
	if not process:hasProcess() then return 0 end
	local output = ffi.new("uint32_t[1]")
	process:read(addr, output, ffi.sizeof(output))
	return bswap(output[0])
end

function memory.writeUInt(addr, value)
	if not process:hasProcess() then return end
	local input = ffi.new("uint32_t[1]", value)
	return process:write(addr, input, ffi.sizeof(input))
end

local TYPES_READ = {
	["bool"] = memory.readBool,

	["sbyte"] = memory.readByte,
	["byte"] = memory.readUByte,
	["short"] = memory.readShort,

	["u8"] = memory.readUByte,
	["s8"] = memory.readByte,
	["u16"] = memory.readUShort,
	["s16"] = memory.readShort,
	["u32"] = memory.readUInt,
	["s32"] = memory.readInt,

	["float"] = memory.readFloat,

	["data"] = memory.read,
}

-- Creates or updates a tree of values for easy indexing
-- Example a path of "player.name" will become memory.players = { name = value }
function memory.cacheValue(table, path, value)
	local last = table
	local last_key = nil

	local keys = {}
	for key in string.gmatch(path, "[^%.]+") do
		keys[#keys + 1] = tonumber(key) or key
	end

	for i, key in ipairs(keys) do
		if i < #keys then
			last[key] = last[key] or {}
			last = last[key]
		else
			if type(last) ~= "table" then
				return error(("Failed to index a %s value (%q)"):format(type(last), keys[i-1]))
			end
			last[key] = value
			last_key = key
		end
	end

	-- Return the table that the value is being stored in, and the key name
	return last, last_key
end

local ADDRESS = {}
ADDRESS.__index = ADDRESS

function memory.newvalue(addr, offset, struct, name)
	assert(type(addr) == "number", "argument #1 'address' must be a number")
	assert(TYPES_READ[struct.type] ~= nil, "unhandled type: " .. struct.type)

	name = name or struct.name or ""

	-- create/get a new value cache based off of the value name
	local tbl, key = memory.cacheValue(memory.values, name, struct.init or NULL)

	--log.debug("[MEMORY] VALUE CREATED %08X + %X %q", addr, offset, name)

	return setmetatable({
		name = name,

		address = addr, -- Where in memory this value is located
		offset = offset, -- How far past the address value we should get the value from

		-- Assign the function we will be using to read from memory
		read = TYPES_READ[struct.type],

		-- Setup the cache
		cache = tbl,
		cache_key = key,

		debug = struct.debug,
	}, ADDRESS)
end

function ADDRESS:update()
	if self.address == NULL then return end

	-- value = converted value
	-- orig = Non-converted value (Only available for floats)
	local value, orig = self.read(self.address + self.offset)

	-- Check if there has been a value change
	if self.cache[self.cache_key] ~= value then
		self.cache[self.cache_key] = value

		if self.debug then
			local numValue = tonumber(orig) or tonumber(value) or (value and 1 or 0)
			log.debug("[MEMORY] [0x%08X  = 0x%08X] %s = %s", self.address + self.offset, numValue, self.name, value)
		end

		-- Queue up a hook event
		table.insert(memory.hook_queue, {name = self.name, value = value, debug = self.debug})
	end
end

local POINTER = {}
POINTER.__index = POINTER

function memory.newpointer(addr, offset, pointer, name)
	local pstruct = {}

	name = name or pointer.name

	--log.debug("[MEMORY] POINTER CREATED %08X + %X %q", addr, offset, name or "nil")

	-- Loop through the pointers children
	for poffset, struct in pairs(pointer.struct) do
		local sname = name
		if sname and struct.name then
			sname = sname .. "." .. struct.name
		end
		if struct.type == "pointer" then
			pstruct[poffset] = memory.newpointer(NULL, poffset, struct, sname)
		else
			pstruct[poffset] = memory.newvalue(NULL, poffset, struct, sname)
		end
	end

	return setmetatable({
		parent = addr ~= NULL and pointer or nil,
		name = name,
		address = addr,
		offset = offset,
		location = NULL,
		struct = pstruct,
	}, POINTER)
end

function POINTER:getAddress()
	return ("0x%08X"):format(self.address + self.offset)
end

function POINTER:getPointerPath()
	local parent = self
	while parent do
		local path = parent:getAddress()
		path = parent:getAddress() .. " -> " .. path
		parent = parent.parent
	end
	return path
end

function POINTER:update()
	local addr = self.address + self.offset
	local ploc = memory.readUInt(addr)

	if self.location ~= ploc then
		self.location = ploc

		if ploc == NULL then
			log.debug("[MEMORY] [0x%08X -> 0x0 (NULL)] %s -> 0x%08X", addr, self.name, ploc)
		else
			log.debug("[MEMORY] [0x%08X -> 0x%08X] %s -> 0x%08X", addr, ploc, self.name, ploc)
		end
	end

	for offset, struct in pairs(self.struct) do
		-- Set the address space to be where the containing pointer is pointing to
		struct.address = ploc
		-- Update the value/pointer recursively
		struct:update()
	end
end

function memory.loadmap(map)
	for address, struct in pairs(map) do
		if struct.type == "pointer" then
			memory.map[address] = memory.newpointer(address, NULL, struct)
		else
			memory.map[address] = memory.newvalue(address, NULL, struct)
		end
	end
end

function memory.hasPermissions()
	return memory.permissions
end

function memory.isInGame()
	local gid = memory.gameid
	local vcid = memory.vcid
	return gid ~= GAME_NONE or vcid ~= VC_NONE
end

function memory.isMelee()
	local gid = memory.gameid

	-- Force the GAMEID and VERSION to be Melee 1.02, since Fizzi seems to be using the gameid address space for something..
	if gid ~= GAME_NONE and PANEL_SETTINGS:IsSlippiNetplay() then
		gid = "GALE01"
		version = 0x02
	end

	local clone = clones[gid]
	if clone then gid = clone.id end

	return gid == "GALE01"
end

local timer = love.timer.getTime()

function memory.loadGameScript(path)
	-- Try to load the game table
	local status, game = xpcall(require, debug.traceback, ("games.%s"):format(path))

	log.debug("[DOLPHIN] GAMEID: %s", path)
	love.updateTitle(("M'Overlay - Dolphin hooked (%s)"):format(path))
	memory.runhook("OnGameOpen")

	if status then
		memory.game = game
		log.info("[DOLPHIN] Loaded game config: %s", path)
		memory.init(game.memorymap)
	else
		notification.error(("Unsupported game %s"):format(path))
		notification.error("Playing slippi netplay? Press 'escape' and enable Rollback/Netplay mode")
		log.error("[DOLPHIN] %s", game) -- game variable is an error string
	end
end

function memory.findGame()
	local gid = memory.readGameID()
	local vcid = memory.readVirtualConsoleID()
	local version = memory.readGameVersion()

	-- Force the GAMEID and VERSION to be Melee 1.02, since Fizzi seems to be using the gameid address space for something..
	if gid ~= GAME_NONE and PANEL_SETTINGS:IsSlippiNetplay() then
		gid = "GALE01"
		version = 0x02
	end

	-- When playing Slippi netplay.. the game ID can and will change..
	-- This would normally break things, but if you enable Rollback/Netplay mode it will force the gameid to always be GALE01 v1.02
	local meleeMode = (memory.isMelee() and memory.gameid ~= gid)

	if not memory.ingame and gid == GAME_NONE and vcid ~= VC_NONE then
		memory.reset()
		memory.ingame = true
		memory.vcid = vcid

		memory.loadGameScript(vcid)
	elseif (not memory.ingame or meleeMode) and gid ~= GAME_NONE then
		memory.reset()
		memory.ingame = true
		memory.gameid = gid
		memory.version = version

		-- See if this GameID is a clone of another
		local clone = clones[gid]

		if clone then
			version = clone.version
			gid = clone.id
		end

		memory.loadGameScript(("%s-%d"):format(gid, version))
	elseif (memory.ingame or meleeMode) and (gid == GAME_NONE and vcid == VC_NONE) then
		memory.reset()
		memory.ingame = false
		memory.gameid = gid
		memory.vcid = vcid
		memory.version = version

		love.updateTitle("M'Overlay - Dolphin hooked")
		memory.runhook("OnGameClosed")
		memory.process:clearGamecubeRAMOffset() -- Clear the memory address space location (When a new game is opened, we recheck this)
		log.info("[DOLPHIN] Game closed..")
	end
end

function memory.update()
	if not memory.hasPermissions() then return end

	if not process:isProcessActive() and process:hasProcess() then
		process:close()
		love.updateTitle("M'Overlay - Waiting for Dolphin..")
		log.info("[DOLPHIN] Unhooked")
		memory.hooked = false
	end

	local t = love.timer.getTime()

	-- Only check for the dolphin process once per second to reduce CPU load
	if not process:hasProcess() or not process:hasGamecubeRAMOffset() then
		if timer <= t then
			timer = t + 0.5
			if process:findprocess() then
				log.info("[DOLPHIN] Hooked")
				love.updateTitle("M'Overlay - Dolphin hooked")
				memory.hooked = true
			elseif not process:hasGamecubeRAMOffset() and process:findGamecubeRAMOffset() then
				log.info("[DOLPHIN] Watching ram: %X [%X]", process:getGamecubeRAMOffset(), process:getGamecubeRAMSize())
			end
		end
	else
		memory.updatememory()

		local frame = memory.frame or 0
		if frame == 0 or memory.game_frame ~= frame then
			memory.game_frame = frame
			memory.runhooks()
		end
	end
end

function memory.init(map)
	log.info("[MEMORY] Mapping game memory..")
	memory.initialized = true
	memory.loadmap(map)
end

function memory.reset()
	memory.initialized = false
	memory.ingame = false
	memory.hooked = false
	memory.map = {}
	memory.values = {}
	memory.gameid = GAME_NONE
	memory.version = 0
	memory.game = nil
	setmetatable(memory, {__index = memory.values})
end

function memory.updatememory()
	memory.findGame()

	for addr, value in pairs(memory.map) do
		value:update()
	end
end

local function hookPattern(name)
	-- Convert '*' into capture patterns
	if string.find(name, "*", 1, true) then
		return true, '^' .. name:escape():gsub("%%%*", "([^.]-)") .. '$'
	end
	return false, name
end

function memory.hook(name, desc, callback)
	local wildcard, name = hookPattern(name)
	if wildcard then
		memory.wildcard_hooks[name] = memory.wildcard_hooks[name] or {}
		memory.wildcard_hooks[name][desc] = callback
	else
		memory.hooks[name] = memory.hooks[name] or {}
		memory.hooks[name][desc] = callback
	end
end

function memory.unhook(name, desc)
	memory.hook(name, desc, nil)
end

function memory.runhooks()
	local pop
	while true do
		pop = table.remove(memory.hook_queue, #memory.hook_queue)
		if not pop then break end
		memory.runhook(pop.name, pop.value)
	end
end

do
	local args = {}
	local matches = {}

	function memory.runhook(name, ...)
		-- Normal hooks
		if memory.hooks[name] then
			for desc, callback in pairs(memory.hooks[name]) do
				local succ, err
				if type(desc) == "table" then
					-- Assume a table is an object, so call it as so
					succ, err = xpcall(callback, debug.traceback, desc, ...)
				else
					succ, err = xpcall(callback, debug.traceback, ...)
				end
				if not succ then
					log.error("[MEMORY] hook error: %s (%s)", desc, err)
				end
			end
		end

		local varargs = {...}

		-- Allow for wildcard hooks
		for pattern, hooks in pairs(memory.wildcard_hooks) do
			if string.find(name, pattern) then
				args = {}
				matches = {name:match(pattern)}

				for k, match in ipairs(matches) do
					table.insert(args, tonumber(match) or match)
				end
				for k, arg in ipairs(varargs) do
					table.insert(args, arg)
				end

				for desc, callback in pairs(hooks) do
					local succ, err
					if type(desc) == "table" then
						-- Assume a table is an object, so call it as so
						succ, err = xpcall(callback, debug.traceback, desc, unpack(args))
					else
						succ, err = xpcall(callback, debug.traceback, unpack(args))
					end
					if not succ then
						log.error("[MEMORY] wildcard hook error: %s (%s)", desc, err)
					end
				end
			end
		end
	end
end

return memory