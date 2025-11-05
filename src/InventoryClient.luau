--!strict
---> module declaration
local InventoryClient = { Prototype = {} }

---> services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

---> dependencies
local Packages = ReplicatedStorage:WaitForChild("Packages")
local Components = script.Parent.Components

local Loader = require(Packages.Loader)
local Promise = require(Packages.Promise)
local GoodSignal = require(Packages.GoodSignal)

---> constructors
local Janitor = require(Packages.Janitor)
local Packets = require(Components.Packets)
local ItemsMap = require(Components.ItemsMap)
local InventoryItem = require(Components.InventoryItem)

---> types
export type InventoryItem = InventoryItem.InventoryItem
export type InventoryRoot = { [string]: InventoryItem.InventoryRoot }
export type InventoryItemRoot = InventoryItem.InventoryItemRoot
type predicateFn = (itemData: InventoryItem.InventoryItem) -> boolean

export type PlayerInventory = typeof(setmetatable(
	{} :: {
		OnChange: RBXScriptSignal,
		Inventory: { [string]: InventoryItem },
		Metadata: {
			_type: string,
		},
		_janitor: { any }, ---> no available import to check against
	},
	{ __index = InventoryClient.Prototype }
))

export type OnChangeData = {
	action: string, -- "added", "removed", "metadataChanged"
	itemId: string,
	itemsType: string,
}

---> private

---> methods

-- Returns a filtered subset of the inventory based on a predicate function
-- @param predicate: (InventoryItem) -> boolean - The condition used to filter items
-- @return { [string]: InventoryItem } - A dictionary of items that match the predicate
-- @return number- Number of items that matched the predicate
function InventoryClient.Prototype:Filter(predicate: predicateFn): { string: InventoryItem }
	local result = {}
	local num = 0
	for id, item in self.Inventory do
		if predicate(item) then
			result[id] = item
			num += 1
		end
	end
	return result, num
end

-- Returns the items that match the provided item IDs and optional predicate; if no itemIds are
-- provided, all items in the current inventory will be returned
-- @param itemIds: { string }? - A list of item IDs to retrieve
-- @param predicate: ((InventoryItem) -> boolean)? - An optional filter function for each item
-- @return { [string]: InventoryItem } - A dictionary of matched inventory items
function InventoryClient.Prototype:GetItems(itemIds: { string }?, predicate: predicateFn?): { string: InventoryItem }
	if not itemIds and not predicate then
		return self.Inventory
	end

	local result = {}
	for _, id in itemIds do
		local itemData: InventoryItem = self.Inventory[id]
		if predicate and not predicate(itemData) then
			continue
		end
		result[id] = self.Inventory[id]
	end
	return result
end

-- Returns a single inventory item by its ID
-- @param itemId: string - The ID of the item to retrieve
-- @return InventoryItem - The inventory item with the specified ID
function InventoryClient.Prototype:GetItemFromId(itemId: string): InventoryItem?
	return self:GetItems({ itemId })[itemId]
end

-- Returns the first equipped item of this type; useful for item types where only 1 item can be equipped at a time
-- @return InventoryItem - The inventory item with the specified ID
function InventoryClient.Prototype:GetFirstEquippedItem(): InventoryItem?
	local equippedItems, _ = self:Filter(function(item)
		return item:IsEquipped()
	end)
	local _, firstEquippedItem = next(equippedItems, nil)
	return firstEquippedItem
end

-- Returns the index of the equipped item of this type;
-- @return InventoryItem - The inventory item with the specified index
function InventoryClient.Prototype:GetEquippedIndex(itemId : string): InventoryItem?
	local equippedItems, _ = self:Filter(function(item)
		return item:IsEquipped()
	end)

	local Index = 0

	for Id, _ in equippedItems do
		Index += 1
		if Id == itemId then return Index end
	end

	return Index
end

-- Returns the total items equipped
function InventoryClient.Prototype:TotalItemsEquipped(): InventoryItem?
	local equippedItems, _ = self:Filter(function(item)
		return item:IsEquipped()
	end)

	local Count = 0

	for _, _ in equippedItems do
		Count += 1
	end

	return Count
end

-- Removes inventory items by their IDs
-- @param itemIds: { string } - A list of item IDs to remove from the inventory
function InventoryClient.Prototype:RemoveItems(itemIds: { string }): ()
	local toRemove: { string } = {}
	for k, id in itemIds do
		if typeof(k) == "string" then
			id = k
		end
        table.insert(toRemove, id)
		self.Inventory[id] = nil
	end
	Packets.removeItems.send({
		itemsType = self.Metadata._type,
		items = toRemove,
	})
end

function InventoryClient.Prototype:Destroy(): ()
	self._janitor:Destroy()
	self.OnChange:DisconnectAll()
	table.clear(self)
	self = nil
end

---> public

-- Fetches the player's inventory asynchronously and wraps each item in its InventoryItem class
-- @param player: Player - The player whose inventory should be fetched
-- @param itemTypeToReturn: string? - The specific item type category to retrieve (e.g. "Fruits")
-- @return Promise<PlayerInventory> - Resolves to the player's inventory wrapped with item instances
function InventoryClient:GetPlayerInventoryAsync(itemTypeToReturn: string?)
	return Promise.new(function(resolve, reject)
		Loader.Controllers.DataController:GetDataAsync()
			:andThen(function(playerData: { [string] : any }) ---> loose type check for lack of full codebase
				local playerInventoryRoot: InventoryRoot = playerData.Inventory.Items
				if not playerInventoryRoot[itemTypeToReturn] then
					warn(
						`Invalid item type {itemTypeToReturn} provided; see ProfileTemplate for list of valid item types`
					)
					return
				end


				local playerInventoryWrapped = {}
				local _self = setmetatable({
					Inventory = playerInventoryWrapped,
					OnChange = GoodSignal.new(),
					Metadata = {
						_type = itemTypeToReturn,
						_item_type_shared_data = ItemsMap[itemTypeToReturn],
						_raw_data = playerInventoryRoot[itemTypeToReturn],
					},
					_janitor = Janitor.new(),
				}, {
					__index = InventoryClient.Prototype,
				})

				for itemId, itemData in playerInventoryRoot[itemTypeToReturn] do
					playerInventoryWrapped[itemId] =
						InventoryItem(game.Players.LocalPlayer, itemId, itemTypeToReturn, itemData, _self)
				end

				local connection = Packets.onChange.listen(function(data: OnChangeData)
					if data.action == "removed" then
						playerInventoryWrapped[data.itemId] = nil
					elseif data.action == "added" then
						if data.itemsType == itemTypeToReturn then
							local currentPlayerData = Loader.Controllers.DataController.LocalPlayerData
							if currentPlayerData and currentPlayerData.Inventory.Items[data.itemsType] then
								local newItem = currentPlayerData.Inventory.Items[data.itemsType][data.itemId]
								if newItem then
									if _self.Metadata._raw_data then
										_self.Metadata._raw_data[data.itemId] = newItem
									end
									playerInventoryWrapped[data.itemId] =
										InventoryItem(game.Players.LocalPlayer, data.itemId, data.itemsType, newItem, _self)
								end
							end
						end
					end
					_self.OnChange:Fire(data)
				end)

				_self._janitor:Add(function()
					Packets.onChange.disconnect(connection)
				end)

				resolve(_self)
			end)
			:catch(reject)
	end):catch(function(...)
		warn("[InventoryClient]: Failed to retrieve player inventory because", ...)
	end)
end

return InventoryClient
