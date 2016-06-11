
local library = {
	__buffer = {},
	queue = {
		push = {}
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

function library:GetTableName(name)
	return self.config.prefix .. string.lower(self:Pluralize(name));
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

function library.meta.schema:Sync(bValue)
	self.__bSync = tobool(bValue);
end;

function library.meta.schema:OnSync(callback)
	self.__onSync = callback;
end;

--[[
	Object
]]--
library.meta.object.__index = library.meta.object;

function library.meta.object:Save()
	library:QueuePush("object", self);
end;

function library.meta.object:__tostring()
	local result = string.format("<activerecord object of model %s>:", self.__model.__name);

	for k, v in pairs(self) do
		if (string.sub(k, 1, 2) == "__") then
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
		__model = self,
		__bSaved = false,
	}, library.meta.object);

	if (object.__model.__schema.ID) then
		object.ID = #library.__buffer[self.__name] + 1;
	end;

	table.insert(library.__buffer[self.__name], object);
	return object;
end;

function library.meta.model:All()
	return library.__buffer[self.__name];
end;

function library.meta.model:First()
	return library.__buffer[self.__name][1];
end;

function library.meta.model:FindBy(key, value)
	if (!library.__buffer[self.__name]) then
		return;
	end;

	local result;

	for k, v in pairs(library.__buffer[self.__name]) do
		if (v[key] and tostring(v[key]) == tostring(value)) then -- TODO: unhack this
			result = v;
			break;
		end;
	end

	return result;
end;

function library:SetupModel(name, setup)
	local schema = setmetatable({
		__bSync = true,
		ID = -1
	}, self.meta.schema);
	local replication = setmetatable({}, self.meta.replication);
	local model = setmetatable({}, self.meta.model);

	setup(schema, replication); -- TODO: use pcall here
	
	model.__name = name;
	model.__schema = schema;
	model.__replication = replication;

	self.model[name] = model;
	self.__buffer[name] = self.__buffer[name] or {};

	self:QueuePush("schema", name);
end;

--[[
	Database
]]--
function library:QueuePush(type, data)
	table.insert(self.queue.push, {
		type = type,
		data = data
	});
end;

function library:PerformModelSync(model)
	local query = self.mysql:Select(self:GetTableName(model.__name));
		query:Callback(function(result, status, lastID)
			if (result) then
				for k, schema in pairs(result) do
					local object = model:New();

					for property, value in pairs(schema) do
						if (value == "NULL") then
							continue;
						end;

						object[property] = value;
						object.__bSaved = true;
					end;
				end;
			end;

			if (model.__schema.__onSync) then
				model.__schema.__onSync();
			end;
		end);
	query:Execute();
end;

function library:BuildQuery(type, data)
	if (type == "schema") then
		local model = self.model[data];
		local query = self.mysql:Create(self:GetTableName(data));

		for k, v in pairs(model.__schema) do
			if (string.sub(k, 1, 2) == "__") then
				continue;
			end;

			if (k == "ID") then
				query:Create("ID", "INT NOT NULL AUTO_INCREMENT");
				query:PrimaryKey("ID");
			else
				local dbType = "VARCHAR(255)";

				if (v == "text") then
					dbType = "TEXT";
				elseif (v == "number") then
					dbType = "INT";
				elseif (v == "boolean") then
					dbType = "TINYINT(1)";
				end;

				query:Create(k, dbType);
			end;
		end;

		if (model.__schema.__bSync) then
			query:Callback(function()
				self:PerformModelSync(model);
			end);
		end;

		return query;
	elseif (type == "object") then
		local model = data.__model;
		local query;
		local updateFunc = "Update";

		if (data.__bSaved) then
			query = self.mysql:Update(self:GetTableName(model.__name));
			query:Where("id", data.ID); -- TODO: account for models without IDs
		else
			query = self.mysql:Insert(self:GetTableName(model.__name));
			query:Callback(function(result, status, lastID)
				data.__bSaved = true;
			end);

			updateFunc = "Insert";
		end;

		for k, v in pairs(data) do
			if (string.sub(k, 1, 2) == "__" or k == "ID") then
				continue;
			end;

			query[updateFunc](query, k, v);
		end;

		return query;
	end;
end;

function library:Think()
	if (!self.mysql:IsConnected()) then
		return;
	end;

	if (#self.queue.push > 0) then
		local item = self.queue.push[1];

		if (item) then
			local query = self:BuildQuery(item.type, item.data);
			query:Execute();

			table.remove(self.queue.push, 1);
		end;
	end;
end;

do
	timer.Create("activerecord:Think", 1, 0, function()
		library:Think();
	end);
end;

return library;