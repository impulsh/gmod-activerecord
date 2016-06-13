
local library = {
	__buffer = {},
	queue = {
		push = {},
		pull = {}
	},
	searchMethods = {},

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
			condition = nil
		},
		model = {
			__schema = {},
			__replication = {}
		},
		object = {}
	},
	model = {}
};

local MESSAGE = {
	COMMIT = 1,
	SCHEMA = 2,
	REQUEST = 3
};

local function Log(text)
	if (!library.config.suppress) then
		print(string.format("[activerecord] %s", text));
	end;
end;

local function SearchMethod(name)
	library.searchMethods[name] = true;
end;

--- Pluralize a string.
-- @string string
-- @treturn string
function library:Pluralize(string)
	return string .. "s"; -- poor man's pluralization
end;

function library:GetCallbackArgument(...)
	local arguments = {...};
	local callback = arguments[1];

	assert(callback and type(callback) == "function", "Expected function type for asynchronous request");
	return callback;
end;

--- Sets the prefix used when creating tables. An underscore is appended to the end of the given prefix. Default is "ar".
-- @string prefix
function library:SetPrefix(prefix)
	self.config.prefix = string.lower(prefix) .. "_";
	self:OnPrefixSet();
end;

function library:GetName()
	return "activerecord_" .. self.config.prefix;
end;

function library:PackTable(table)
	local data = util.Compress(util.TableToJSON(table));
	return data, string.len(data);
end;

function library:UnpackTable(string)
	return util.JSONToTable(util.Decompress(string));
end;

if (SERVER) then
	AddCSLuaFile();

	function library:GetTableName(name)
		return self.config.prefix .. string.lower(self:Pluralize(name));
	end;

	function library:SetSQLWrapper(table)
		self.mysql = table;
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
		self[name] = "VARCHAR(255)";
		return self;
	end;

	function library.meta.schema:Text(name)
		self[name] = "TEXT";
		return self;
	end;

	function library.meta.schema:Integer(name)
		self[name] = "INT(11)";
		return self;
	end;

	function library.meta.schema:Boolean(name)
		self[name] = "TINYINT(1)";
		return self;
	end;

	function library.meta.schema:Sync(bValue)
		self.__bSync = tobool(bValue);
		return self;
	end;

	function library.meta.schema:OnSync(callback)
		self.__onSync = callback;
		return self;
	end;

	--[[
		Model replication
	]]--
	library.meta.replication.__index = library.meta.replication;

	function library.meta.replication:Enable(bValue)
		self.bEnabled = bValue;
		return self;
	end;

	function library.meta.replication:Condition(callback)
		self.condition = callback;
		return self;
	end;

	function library:CheckObjectRequestCondition(modelName, player)
		return (self.model[modelName] and
			self.model[modelName].__replication.bEnabled and
			self.model[modelName].__replication.condition(player));
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

	SearchMethod("All");
	function library.meta.model:All(...)
		if (self.__schema.__bSync) then
			return library.__buffer[self.__name];
		else
			local query = library.mysql:Select(library:GetTableName(self.__name));
				query:Callback(library:GetCallbackArgument(...));
			query:Execute();
		end;
	end;

	SearchMethod("First");
	function library.meta.model:First(...)
		if (self.__schema.__bSync) then
			return library.__buffer[self.__name][1];
		else
			local query = library.mysql:Select(library:GetTableName(self.__name));
				query:OrderByAsc("ID"); -- TODO: account for no ID
				query:Limit(1);
				query:Callback(library:GetCallbackArgument(...));
			query:Execute();
		end;
	end;

	SearchMethod("FindBy");
	function library.meta.model:FindBy(key, value, ...)
		if (self.__schema.__bSync) then
			local result;

			for k, v in pairs(library.__buffer[self.__name]) do
				if (v[key] and tostring(v[key]) == tostring(value)) then -- TODO: unhack this
					result = v;
					break;
				end;
			end

			return result;
		else
			local query = library.mysql:Select(library:GetTableName(self.__name));
				query:Where(key, value);
				query:Limit(1);
				query:Callback(library:GetCallbackArgument(...));
			query:Execute();
		end;
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

		if (replication.bEnabled) then
			assert(replication.condition and type(replication.condition) == "function", "Replicated models need to have a condition!");
			self:NetworkModel(model);
		end;

		self:QueuePush("schema", name);
	end;

	function library:FilterPlayers(func)
		local filter = {};

		for k, v in pairs(player.GetAll()) do
			if (func(v)) then
				table.insert(filter, v);
			end;
		end;

		return filter;
	end;

	function library:NetworkModel(model)
		local players = self:FilterPlayers(model.__replication.condition);

		if (#players < 1) then
			return;
		end;

		local data = {};

		for k, v in pairs(model.__schema) do
			if (string.sub(k, 1, 2) == "__") then
				continue;
			end;

			data[k] = true
		end;

		net.Start(self:GetName() .. ".message");
			net.WriteUInt(MESSAGE.SCHEMA, 8);

			net.WriteString(model.__name)

			local data, length = self:PackTable(data);
			net.WriteUInt(length, 32);
			net.WriteData(data, length);
		net.Send(players[1]);
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
					query:Create(k, v);
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
				query:Where("ID", data.ID); -- TODO: account for models without IDs
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

	function library:OnPrefixSet()
		util.AddNetworkString(self:GetName() .. ".message");

		if (!self.mysql) then
			Log("SQL wrapper not loaded; trying to include now...");
			self.mysql = include("dependencies/sqlwrapper/mysql.lua");
		end;

		--[[
			Network events
		]]--
		hook.Add("PlayerInitialSpawn", self:GetName() .. ":PlayerInitialSpawn", function(player)
			--
		end);

		net.Receive(self:GetName() .. ".message", function(length, player)
			local message = net.ReadUInt(8);

			if (message == MESSAGE.REQUEST) then
				local modelName = net.ReadString();

				if (self:CheckObjectRequestCondition(modelName, player)) then
					local model = self.model[modelName];
					local schema = model.__schema;

					local requestID = net.ReadString();
					local dataLength = net.ReadUInt(32);
					local criteria = self:UnpackTable(net.ReadData(dataLength));

					local method = criteria[1];
					local key = tostring(criteria[2]); -- TODO: check for different operators (e.g > ?)
					local value = criteria[3];

					-- TODO: check if replication config is allowed to pull from database
					if (self.searchMethods[method] and string.sub(key, 1, 2) != "__" and schema[key]) then
						if (schema.__bSync) then
							local result = model[method](model, key, value);

							net.Start(self:GetName() .. ".message");
								net.WriteUInt(MESSAGE.REQUEST, 8);
								net.WriteString(requestID);

								local data, length = self:PackTable({result}); -- TODO: send ONLY the objects
								net.WriteUInt(length, 32);
								net.WriteData(data, length);
							net.Send(player);
						else
							model[method](model, key, value, function(...)
								if (!IsValid(player) or !player:IsPlayer()) then
									return;
								end;

								net.Start(self:GetName() .. ".message");
									net.WriteUInt(MESSAGE.REQUEST, 8);
									net.WriteString(requestID);

									local data, length = self:PackTable({...});
									net.WriteUInt(length, 32);
									net.WriteData(data, length);
								net.Send(player);
							end);
						end;
					else
						Log("Invalid search method or key!");
					end;
				end;
			end;
		end);
	end;
end;

if (CLIENT) then
	function library:SetPrefix(prefix)
		self.config.prefix = string.lower(prefix) .. "_";
		self:OnPrefixSet();
	end;

	function library:GetName()
		return "activerecord_" .. self.config.prefix;
	end;

	function library:RequestObject(name, criteria, callback)
		local id = self.config.prefix .. CurTime() .. "-" .. math.random(100000, 999999);

		net.Start(self:GetName() .. ".message");
			net.WriteUInt(MESSAGE.REQUEST, 8);

			net.WriteString(name);
			net.WriteString(id);
			
			local data, length = self:PackTable(criteria);
			net.WriteUInt(length, 32);
			net.WriteData(data, length);
		net.SendToServer();

		self.queue.pull[id] = callback;

		return id;
	end;

	--[[
		Object
	]]--
	function library:CommitObject(object)
		--
	end;

	library.meta.object.__index = library.meta.object;

	function library.meta.object:Save()
		library:CommitObject(self);
	end;

	--[[
		Model
	]]--
	library.meta.model.__index = library.meta.model;

	function library.meta.model:New()
		local object = setmetatable({
			__model = self
		}, library.meta.object);

		return object;
	end;

	function library.meta.model:FindBy(key, value, ...)
		library:RequestObject(self.__name, {
			"FindBy", key, value
		}, library:GetCallbackArgument(...));
	end;

	function library:SetupModel(name, schema)
		local model = setmetatable({
			__schema = schema,
			__name = name
		}, self.meta.model);

		self.model[name] = model;
	end;

	--[[
		Networking events
	]]--
	function library:OnPrefixSet()
		net.Receive(self:GetName() .. ".message", function(length)
			local message = net.ReadUInt(8);

			if (message == MESSAGE.REQUEST) then
				local id = net.ReadString();

				if (self.queue.pull[id] and type(self.queue.pull[id]) == "function") then
					local result = self:UnpackTable(net.ReadData(net.ReadUInt(32)));

					self.queue.pull[id](result); -- TODO: pcall this
					self.queue.pull[id] = nil;
				end;
			elseif (message == MESSAGE.SCHEMA) then
				local name = net.ReadString();
				local data = net.ReadData(net.ReadUInt(32));
				local schema = self:UnpackTable(data);

				self:SetupModel(name, schema);
			end;
		end);
	end;
end;

return library;