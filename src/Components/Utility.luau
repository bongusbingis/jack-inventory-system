local Utility = {}

---> services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

---> dependencies
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Enum = require(Shared.Utility.Enum)
local InventoryLimits = require(Shared.Data.InventoryLimits)

---> constants
local ITEM_DATA_MAP = require(script.Parent.ItemsMap)

---> types
export type InventoryRoot = { [string]: InventoryItemRoot }

type InventoryItemRoot = {
	Name: string,
	Rarity: string,
	Quantity: number?, -- if stackable
	Metadata: {}?,
}

---> private

---> public
function Utility.IsValidItem(itemId: string, itemType: string, itemData: InventoryItemRoot): (boolean, string?)
	assert(ITEM_DATA_MAP[itemType], "CRITICAL: Invalid itemType; must exist in shared -> Items")

	if typeof(itemId) ~= "string" then
		return false, `Expected string for itemId, got {itemId}`
	end

	if typeof(itemData.Name) ~= "string" then
		return false, `Expected string for itemData.Name, got {itemData.Name}`
	end

	-- if not itemData.Rarity or not Enum.Rarity[itemData.Rarity] then
	-- 	return false, `Expected valid rarity type for itemData.Rarity, got {itemData.Rarity}`
	-- end

	local itemSharedData = ITEM_DATA_MAP[itemType]
	if not itemSharedData then
		return false, `Invalid itemType {itemType}; must exist in shared -> Items`
	end

	local itemProps = itemSharedData[itemData.Name]
	if not itemProps then
		return false, `{itemData.Name} is not a valid item type existing in ITEM_DATA_MAP[{itemType}]`
	end

	return true
end

function Utility.GetInventoryLimit(limitType: "Equipped" | "Storage", itemType: string): number | nil
	local limitData = InventoryLimits[limitType]
	if not limitData then
		return warn(`Invalid limitType {limitType}; must exist in InventoryLimits`)
	end

	local itemLimitForThisType = limitData[itemType]
	if not itemLimitForThisType then
		return warn(`Invalid itemType {itemType}; must exist in InventoryLimits -> {limitType}`)
	end

	return itemLimitForThisType
end

return Utility