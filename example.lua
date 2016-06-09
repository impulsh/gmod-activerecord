
local ar = include("activerecord.lua");

--[[
	This should be set to something short and unique to your project.
	Default is "ar".
]]--
ar:SetPrefix("test");

--[[
	Here we set up the model for our object. In this case, the object
	represents a generic user.
]]--
ar:SetupModel("User"), function(schema)
	--[[
		Here we describe the properties of the model and how they're stored.
		You call various functions on the schema object that's passed as part
		of the setup function to build your object's representation.
		Valid types include:
			Boolean
			Integer
			String
			Text

		Models are given an auto incremented ID by default, you can disable it
		by calling schema:ID(false). You can chain property descriptions
		together to make them look nicer if you'd like.

		In this example, we're making a string property for a player's name
		and Steam ID, and an integer property for the amount of imaginary
		boxes they've received.

		The preferred naming style of properties is UpperCamelCase.
	]]--
	schema
		:String("Name")
		:String("SteamID")
		:Integer("Boxes");
end);

--[[
	Now that we've set up our model, we can start using it to save objects to
	the database. Any models that you have created will be stored in the
	library's model table. The properties you've described can be accessed
	as regular lua variables.

	To commit the object and/or its changes to the database, simply call the
	Save method on the object. Query queuing is done automatically.
]]--
do
	local user = ar.model.User:New();
		user.Name = "`impulse";
		user.SteamID = "STEAM_1:2:3";
		user.Boxes = 9001;
	user:Save();
end;

--[[
	We can also find users quite easily. Here, we retrieve a list of all the
	users.
]]--
do
	local users = ar.model.User:All();

	for k, v in pairs(users) do
		print(string.format("User %i has name %s", v.ID, v.Name));
	end;
end;

--[[
	Using the First method returns the first created user (or user with the
	lowest ID if applicable).
]]--
do
	local user = ar.model.User:First();

	-- Always check to make sure you got a valid result!
	if (user) then
		print(string.format("User %i has name %s", user.ID, user.Name));
	end;
end;

--[[
	You can find a user by a specific condition. FindBy requires a property
	name and required value for that property. You can also set a different
	condition to match with by using the property name, followed by an
	operator with a question mark.

	You can have multiple conditions, simply by adding another property name/
	value pair. See the Where block below this one for an example.
]]--
do
	local user = ar.model.User:FindBy("ID", 1);
	local user = ar.model.User:FindBy("Boxes > ?", 100);

	if (user) then
		print(string.format("User %i has name %s", user.ID, user.Name));
	end;
end;

--[[
	Where works like FindBy, except it returns a table of all objects that
	fit the criteria.
]]--
do
	local users = ar.model.User:Where(
		"Boxes > ?", 9000,
		"Name", "`impulse"
	);

	for k, v in pairs(users) do
		print(string.format("User %i has name %s", v.ID, v.Name));
	end;
end;

--[[
	To delete an object from the database, simply call Destroy on the object.
	This means you can use any of the search methods to find the user you want
	to delete.
]]--
do
	local user = ar.model.User:FindBy("ID", 1);
	user:Destroy();
end;