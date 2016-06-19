
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
	REQUEST = 3,
	UPDATE = 4,
	SYNC = 5
};

local function Log(text)
	if (!library.config.suppress) then
		print(string.format("[activerecord] %s", text));
	end;
end;

local function SearchMethod(name, bRequiresKey, bSingleResult)
	library.searchMethods[name] = {
		bRequiresKey = bRequiresKey,
		bSingleResult = bSingleResult
	};
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

	assert(callback and type(callback) == "function", "Expected function type for asynchronous request, got \"" .. type(callback) .. "\"");
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

function library:IsObject(var)
	return getmetatable(var) == self.meta.object;
end;

function library:StartNetMessage(type)
	net.Start(self:GetName() .. ".message");
	net.WriteUInt(type, 8);
end;

function library:WriteNetTable(data)
	local data, length = self:PackTable(data);

	net.WriteUInt(length, 32);
	net.WriteData(data, length);
end;

function library:ReadNetTable()
	return self:UnpackTable(net.ReadData(net.ReadUInt(32)));
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
		self[name] = "INTEGER";
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

		if (self.__model.__schema.__bSync and self.__model.__replication.bEnabled) then
			library:NetworkObject(self);
		end;
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

	function library:NetworkObject(object)
		local model = object.__model;
		local players = self:FilterPlayers(model.__replication.condition);

		if (#players < 1) then
			return;
		end;

		self:StartNetMessage(MESSAGE.UPDATE);
			net.WriteString(model.__name)
			self:WriteNetTable(self:GetObjectTable(object));
		net.Send(players[1]); -- TODO: why only the first player?
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
			local arguments = {...};
			local query = library.mysql:Select(library:GetTableName(self.__name));
				query:Callback(function(result)
					local callback = library:GetCallbackArgument(unpack(arguments));
					callback(library:BuildObjectsFromSQL(self, result));
				end);
			query:Execute();
		end;
	end;

	SearchMethod("First", false, true);
	function library.meta.model:First(...)
		if (self.__schema.__bSync) then
			return library.__buffer[self.__name][1];
		else
			local arguments = {...};
			local query = library.mysql:Select(library:GetTableName(self.__name));
				query:OrderByAsc("ID"); -- TODO: account for no ID
				query:Limit(1);
				query:Callback(function(result)
					local callback = library:GetCallbackArgument(unpack(arguments));
					callback(library:BuildObjectsFromSQL(self, result, true));
				end);
			query:Execute();
		end;
	end;

	SearchMethod("FindBy", true, true);
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
			local arguments = {...};
			local query = library.mysql:Select(library:GetTableName(self.__name));
				query:Where(key, value);
				query:Limit(1);
				query:Callback(function(result)
					local callback = library:GetCallbackArgument(unpack(arguments));
					callback(library:BuildObjectsFromSQL(self, result, true));
				end);
			query:Execute();
		end;
	end;

	function library:BuildObjectsFromSQL(model, result, bSingleResult)
		if (!result or type(result) != "table" or #result < 1) then
			return {};
		end;

		local objects = {};

		for id, row in pairs(result) do
			local object = model:New();

			for k, v in pairs(row) do
				if (!model.__schema[k] or v == "NULL") then
					continue;
				end;

				object[k] = v;
			end;

			object.__bSaved = true;
			table.insert(objects, object);
		end;

		if (bSingleResult) then -- TODO: should avoid building the results table here
			return objects[1];
		end;

		return objects;
	end;

	function library:GetObjectTable(object)
		local result = {};

		for k, v in pairs(object) do
			if (string.sub(k, 1, 2) == "__" or !object.__model.__schema[k]) then
				continue;
			end;

			result[k] = v;
		end;

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

			data[k] = true;
		end;

		self:StartNetMessage(MESSAGE.SCHEMA);
			net.WriteString(model.__name)
			self:WriteNetTable(data);
		net.Send(players[1]); -- TODO: why only the first player?
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
			query:Callback(function(result)
				local objects = self:BuildObjectsFromSQL(model, result);

				for k, v in pairs(objects) do -- TODO: don't send a message for each object
					self:NetworkObject(v);
				end;

				if (model.__schema.__onSync) then
					model.__schema.__onSync(); -- TODO: pcall this
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
					query:Create("ID", "INTEGER NOT NULL AUTO_INCREMENT");
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
			for modelName, model in pairs(library.model) do
				if (model.__replication.bEnabled) then
					self:NetworkModel(model);

					if (model.__schema.__bSync) then
						for k, v in pairs(library.__buffer[modelName]) do
							self:NetworkObject(v);
						end;
					end;
				end;
			end;
		end);

		net.Receive(self:GetName() .. ".message", function(length, player)
			local message = net.ReadUInt(8);

			if (message == MESSAGE.REQUEST) then
				local modelName = net.ReadString();

				if (self:CheckObjectRequestCondition(modelName, player)) then
					local model = self.model[modelName];
					local schema = model.__schema;

					local requestID = net.ReadString();
					local criteria = self:ReadNetTable();

					local method = criteria[1];
					local key = tostring(criteria[2]); -- TODO: check for different operators (e.g > ?)
					local value = criteria[3];

					-- TODO: check if replication config is allowed to pull from database
					local searchMethod = self.searchMethods[method];

					if (searchMethod and
						(searchMethod.bRequiresKey and string.sub(key, 1, 2) != "__" and schema[key]) or
						(!searchMethod.bRequiresKey)) then
						if (schema.__bSync) then
							local result = model[method](model, key, value);

							self:StartNetMessage(MESSAGE.REQUEST);
								net.WriteString(requestID);
								net.WriteString(modelName);

								net.WriteBool(searchMethod.bSingleResult);

								local objects = {};

								if (searchMethod.bSingleResult) then
									table.insert(objects, self:GetObjectTable(result));
								else
									for k, v in pairs(result) do
										table.insert(objects, self:GetObjectTable(v));
									end;
								end;

								self:WriteNetTable(objects);
							net.Send(player);
						else
							local arguments = {model};

							if (searchMethod.bRequiresKey) then
								table.insert(arguments, key);
								table.insert(arguments, value);
							end;

							table.insert(arguments, function(result) -- TODO: WHAT
								if (!IsValid(player) or !player:IsPlayer()) then
									return;
								end;

								self:StartNetMessage(MESSAGE.REQUEST);
									net.WriteString(requestID);
									net.WriteString(modelName);

									net.WriteBool(searchMethod.bSingleResult);

									local objects = {};

									if (searchMethod.bSingleResult) then
										table.insert(objects, self:GetObjectTable(result[1]));
									else
										for k, v in pairs(result) do
											table.insert(objects, self:GetObjectTable(v));
										end;
									end;

									self:WriteNetTable(objects);
								net.Send(player);
							end);

							model[method](unpack(arguments));
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

		self:StartNetMessage(MESSAGE.REQUEST);
			net.WriteString(name);
			net.WriteString(id);
			
			self:WriteNetTable(criteria);
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

	function library.meta.model:New(bAddToBuffer)
		local object = setmetatable({
			__model = self
		}, library.meta.object);

		if (bAddToBuffer) then
			table.insert(library.__buffer[self.__name], object);
		end;

		return object;
	end;

	function library.meta.model:All(...)
		library:RequestObject(self.__name, {
			"All"
		}, library:GetCallbackArgument(...));
	end;

	function library.meta.model:First(...)
		library:RequestObject(self.__name, {
			"First"
		}, library:GetCallbackArgument(...));
	end;

	function library.meta.model:FindBy(key, value, ...)
		library:RequestObject(self.__name, {
			"FindBy", key, value
		}, library:GetCallbackArgument(...));
	end;

	function library:BuildObjectsFromMessage(model, result)
		local objects = {};

		for id, data in pairs(result) do
			local object = model:New();

			for k, v in pairs(data) do
				object[k] = v;
			end;

			table.insert(objects, object);
		end;

		return objects;
	end;

	function library:SetupModel(name, schema)
		local model = setmetatable({
			__schema = schema,
			__name = name
		}, self.meta.model);

		self.model[name] = model;
		self.__buffer[name] = {};
	end;

	--[[
		Networking events
	]]--
	function library:OnPrefixSet()
		net.Receive(self:GetName() .. ".message", function(length)
			local message = net.ReadUInt(8);

			if (message == MESSAGE.REQUEST) then
				local id = net.ReadString();
				local modelName = net.ReadString();
				local bSingleResult = net.ReadBool();
				local model = self.model[modelName];

				if (!model) then
					ErrorNoHalt("Received request networking message for invalid model \"" .. modelName .. "\"!\n");
					return;
				end;

				if (self.queue.pull[id] and type(self.queue.pull[id]) == "function") then
					local result = self:ReadNetTable();
					result = self:BuildObjectsFromMessage(model, result);

					if (bSingleResult) then
						result = result[1];
					end;

					self.queue.pull[id](result); -- TODO: pcall this
					self.queue.pull[id] = nil;
				end;
			elseif (message == MESSAGE.SCHEMA) then
				local name = net.ReadString();
				local schema = self:ReadNetTable();

				self:SetupModel(name, schema);
			elseif (message == MESSAGE.UPDATE) then
				local modelName = net.ReadString();
				local model = self.model[modelName];

				if (!model) then
					ErrorNoHalt("Received update networking message for invalid model \"" .. modelName .. "\"!\n");
					return;
				end;

				local data = self:ReadNetTable(data);

				local found = false;

				for id, object in pairs(self.__buffer[modelName]) do
					if (object.ID == data.ID) then
						for k, v in pairs(data) do
							object[k] = v;
						end;

						print("found object")
						found = true;
						break;
					end;
				end;

				if (!found) then
					print("not found, creating new object")
					local object = model:New(true);

					for k, v in pairs(data) do
						object[k] = v;
					end;
				end;
			end;
		end);
	end;
end;

return library;