
local library = {
	mysql = mysql
	config = {
		prefix = "ar_"
	},

	model = {}
};

if (SERVER) then
	if (!library.mysql) then
		print("[activerecord] SQL wrapper not loaded; trying to include now...");
		library.mysql = include("dependencies/sqlwrapper/mysql.lua");
	end;

	AddCSLuaFile();
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

return library;