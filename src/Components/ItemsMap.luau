local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Items = Shared:WaitForChild("Items")

return {
	["Fruits"] = require(Items.Fruit);
	["Weapons"] = require(Items.Weapon);
	["Boost"] = require(Items.Boost);
	["Pets"] = require(Items.Pet)
}