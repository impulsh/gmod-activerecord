
local library = {
	__buffer = {},
	__queue = {
		connected = false,
		push = {
			schemas = {},
			objects = {}
		},
		pull = {}
	},

	mysql = mysql,
	config = {
		prefix = "ar_",
		suppress = false
	},

	meta = {
		schema = {},
		replication = {
			bEnabled = false,
			bSync = false,
			bSyncExisting = false,
			bAllowDatabasePull = false,
			condition = function() end
		},
		model = {
			__schema = {},
			__replication = {}
		},
		object = {}
	},
	model = {}
};

local function Log(text)
	if (!library.config.suppress) then
		print(string.format("[activerecord] %s", text));
	end;
end;

if (SERVER) then
	if (!library.mysql) then
		Log("SQL wrapper not loaded; trying to include now...");
		library.mysql = include("dependencies/sqlwrapper/mysql.lua");
	end;

	AddCSLuaFile();
end;

if (!SERVER) then
	return;
end;

--- Pluralize a string.
-- @string string
-- @treturn string
function library:Pluralize(string)
	return string .. "s"; -- poor man's pluralization
end;

--- Sets the prefix used when creating tables. An underscore is appended to the end of the given prefix. Default is "ar".
-- @string prefix
function library:SetPrefix(prefix)
	self.config.prefix = string.lower(prefix) .. "_";
end;

--[[
	Model schema
]]--
library.meta.schema.__index = library.meta.schema;

function library.meta.schema:ID(bUse)
	if (!bUse) then
		self.ID = nil;
	end;

	return self;
end;

function library.meta.schema:String(name)
	self[name] = "string";
	return self;
end;

function library.meta.schema:Text(name)
	self[name] = "text";
	return self;
end;

function library.meta.schema:Integer(name)
	self[name] = "number";
	return self;
end;

function library.meta.schema:Boolean(name)
	self[name] = "boolean";
	return self;
end;

--[[
	Object
]]--
library.meta.object.__index = library.meta.object;

function library.meta.object:Save()
	Log("saving object");
end;

function library.meta.object:__tostring()
	local result = string.format("<activerecord object of model %s>:", self.__model.__name);

	for k, v in pairs(self) do
		if (k == "__model") then
			continue;
		end;

		result = result .. string.format("\n\t%s\t= %s", k, v);
	end;

	return result;
end;

--[[
	Model
]]--
library.meta.model.__index = library.meta.model;

function library.meta.model:New()
	local object = setmetatable({
		__model = self
	}, library.meta.object);
	local schema = object.__model.__schema;

	if (schema.ID) then
		object.ID = #library.__buffer[self.__name] + 1;
	end;

	table.insert(library.__buffer[self.__name], object);
	return object;
end;

function library:SetupModel(name, setup)
	local schema = setmetatable({
		ID = -1
	}, self.meta.schema);
	local replication = setmetatable({}, self.meta.replication);
	local model = setmetatable({}, self.meta.model);

	setup(schema, replication); -- should be pcalled
	
	model.__name = name;
	model.__schema = schema;
	model.__replication = replication;

	self.model[name] = model;
	self.__buffer[name] = self.__buffer[name] or {};
end;

return library;