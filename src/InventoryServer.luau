--!strict
---> module declaration
local InventoryServer = { Prototype = {} }

---> services
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

---> dependencies
local Server = ServerScriptService:WaitForChild("Server")
local Packages = ReplicatedStorage:WaitForChild("Packages")
local Components = script.Parent.Components

local DataService = require(Server.Runtime.DataService)
local GoodSignal = require(Packages.GoodSignal)
local Janitor = require(Packages.Janitor)
local Promise = require(Packages.Promise)

---> constructors
local Utility = require(Components.Utility)
local Packets = require(Components.Packets)
local ItemsMap = require(Components.ItemsMap)
local InventoryItem = require(Components.InventoryItem)

---> types
export type InventoryItem = InventoryItem.InventoryItem
export type InventoryRoot = { [string]: InventoryItem.InventoryRoot }
export type InventoryItemRoot = InventoryItem.InventoryItemRoot
type predicateFn = (itemData: InventoryItem.InventoryItem) -> boolean

export type RemoveItemsDataResponse = {
	itemsType: string,
	items: { string },
}

export type SetItemEquippedResponse = {
	itemId: string,
	equipped: boolean,
}

export type PlayerInventory = typeof(setmetatable(
	{} :: {
		Inventory: { [string]: InventoryItem },
		Metadata: {
			_player: Player,
			_changed: RBXScriptSignal,
			_type: string,
		},
	},
	{ __index = InventoryServer.Prototype }
))

---> globals
local OnChangeSignals: {} = {}

---> private

if RunService:IsRunning() then
	Players.PlayerAdded:Connect(function(player)
		OnChangeSignals[player.UserId] = GoodSignal.new()
	end)
	Players.PlayerRemoving:Connect(function(player)
		if OnChangeSignals[player.UserId] then
			OnChangeSignals[player.UserId]:DisconnectAll()
			OnChangeSignals[player.UserId] = nil
		end
	end)

	Packets.useBoost.listen(function(id: string, player: Player)
		InventoryServer:GetPlayerInventoryAsync(player, "Boost"):andThen(function(playerInventory: PlayerInventory)
			local boostItem = playerInventory:GetItemFromId(id)
			if boostItem then
				boostItem:Use()
			else
				warn("[InventoryServer]: Boost item not found in inventory for useBoost", id)
			end
		end)
	end)

	Packets.removeItems.listen(function(data: RemoveItemsDataResponse, player: Player)
		local itemsType = data.itemsType
		local itemIds = data.items

		if not itemsType or not itemIds then
			warn("[InventoryServer]: Invalid packet data received for removeItems", itemsType, itemIds)
			return
		end

		for _, id in itemIds do
			if typeof(id) ~= "string" then
				warn("[InventoryServer]: Invalid item ID received in removeItems array", id)
				return
			end
		end

		InventoryServer:GetPlayerInventoryAsync(player, itemsType):andThen(function(playerInventory: PlayerInventory)
			playerInventory:RemoveItems(itemIds)
		end)
	end)

	Packets.setItemEquipped.listen(function(data: SetItemEquippedResponse, player: Player)
		local itemId = data.itemId
		local itemType = data.itemType
		local equipped = data.equipped

		if not itemId or typeof(itemId) ~= "string" then
			warn("[InventoryServer]: Invalid packet data received for setItemEquipped", itemId)
			return
		end

		InventoryServer:GetPlayerInventoryAsync(player, itemType):andThen(function(playerInventory: PlayerInventory)
			local item = playerInventory:GetItemFromId(itemId)
			if not item then
				warn("[InventoryServer]: Item not found in inventory for setItemEquipped", itemId)
				return
			end

			if item:IsEquipped() == equipped then
				warn(`[InventoryServer]: Item {itemId} is already in the desired equipped state`)
				return
			end

			if equipped then
				item:Equip()
			else
				item:Unequip()
			end
		end)
	end)
end

local function getPlayerInventoryItems(player: Player, itemType: string): InventoryRoot
	local _, playerData = DataService:GetDataAsync(player):await()
	return playerData.Inventory.Items[itemType]
end

---> methods

-- Dispatches inventory change packets to the client
-- @param player: Player - Target player
-- @param data: {} - Change data (includes action, itemId, itemsType)
function InventoryServer.Prototype:_serverDispatchOnChange(player: Player, data: {})
	Packets.onChange.sendTo(data, player)
	if OnChangeSignals[player.UserId] then
		OnChangeSignals[player.UserId]:Fire(data)
	end
end

-- Returns a filtered subset of the inventory based on a predicate function
-- @param predicate: (InventoryItem) -> boolean - The condition used to filter items
-- @return { [string]: InventoryItem } - A dictionary of items that match the predicate
-- @return number- Number of items that matched the predicate
function InventoryServer.Prototype:Filter(predicate: predicateFn): { string: InventoryItem }
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
function InventoryServer.Prototype:GetItems(itemIds: { string }?, predicate: predicateFn?): { string: InventoryItem }
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
function InventoryServer.Prototype:GetItemFromId(itemId: string): InventoryItem
	return self:GetItems({ itemId })[itemId]
end

-- Returns the first equipped item of this type; useful for item types where only 1 item can be equipped at a time
-- @return InventoryItem - The inventory item with the specified ID
function InventoryServer.Prototype:GetFirstEquippedItem(): InventoryItem | nil
	local equippedItems, _ = self:Filter(function(item)
		return item:IsEquipped()
	end)
	local _, firstEquippedItem = next(equippedItems, nil)
	return firstEquippedItem
end

-- Removes inventory items by their IDs
-- @param itemIds: { string } - A list of item IDs to remove from the inventory
function InventoryServer.Prototype:RemoveItems(itemIds: { string })
	for k, id in itemIds do
		if typeof(k) == "string" then
			id = k
		end
		local item: InventoryItem? = self.Inventory[id]
		if item then
			item:Remove()
			self.Inventory[id] = nil
		end
	end
end

function InventoryServer.Prototype:ListenToChange(callbackFn: InventoryItem.OnChangeData): RBXScriptConnection
	return self.Metadata._changed:Connect(callbackFn)
end

function InventoryServer.Prototype:Destroy(): ()
	table.clear(self)
	self = nil
end

-- Equivelant to using :Filter with a predicate function returning
-- if the item is equipped
-- @return see InventoryServer.Prototype:Filter
function InventoryServer.Prototype:GetEquippedItems()
	return self:Filter(function(item)
		return item:IsEquipped()
	end)
end

function InventoryServer.Prototype.Insert(
	self: PlayerInventory,
	itemRootData: InventoryItemRoot,
	isStackable: boolean?
): ()
	local itemSharedData = self.Metadata._item_type_shared_data[itemRootData.Name]
	if not itemSharedData then
		warn("[InventoryServer]: Failed to insert item because", itemRootData.Name, "is not a valid item type")
		return
	end

	local success, result = Utility.IsValidItem(itemRootData.Name, self.Metadata._type, itemRootData)
	if not success then
		warn("[InventoryItem]: Failed to insert item because", result)
		return
	end

	local playerInventoryData = getPlayerInventoryItems(self.Metadata._player, self.Metadata._type)
	local _, playerData = DataService:GetDataAsync(self.Metadata._player):await()

	local itemId = string.format("%s-%s", itemRootData.Name:lower(), HttpService:GenerateGUID(false))
	playerData:SetValue({ "Inventory", "Items", self.Metadata._type, itemId }, {
		Name = itemRootData.Name,
		Rarity = itemRootData.Rarity,
		Metadata = itemRootData.Metadata or {},
		Stackable = isStackable or nil,
	})

	if self.Metadata._raw_data then
		self.Metadata._raw_data[itemId] = playerInventoryData[itemId]
	end

	self.Inventory[itemId] =
		InventoryItem(self.Metadata._player, itemId, self.Metadata._type, playerInventoryData[itemId], self)
	self:_serverDispatchOnChange(self.Metadata._player, {
		action = "added",
		itemId = itemId,
		itemsType = self.Metadata._type,
	})
end

---> public

-- Fetches the player's inventory asynchronously and wraps each item in its InventoryItem class
-- @param player: Player - The player whose inventory should be fetched
-- @param itemTypeToReturn: string? - The specific item type category to retrieve (e.g. "Fruits")
-- @return Promise<PlayerInventory> - Resolves to the player's inventory wrapped with item instances
function InventoryServer:GetPlayerInventoryAsync(player: Player, itemTypeToReturn: string?)
	return Promise.new(function(resolve, reject)
		DataService:GetDataAsync(player)
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
					OnChange = OnChangeSignals[player.UserId],
					Inventory = playerInventoryWrapped,
					Metadata = {
						_player = player,
						_type = itemTypeToReturn,
						_janitor = Janitor.new(),
						_item_type_shared_data = ItemsMap[itemTypeToReturn],
						_raw_data = playerInventoryRoot[itemTypeToReturn],
					},
				}, {
					__index = InventoryServer.Prototype,
				})

				for itemId, itemData in playerInventoryRoot[itemTypeToReturn] do
					playerInventoryWrapped[itemId] = InventoryItem(player, itemId, itemTypeToReturn, itemData, _self)
				end
				resolve(_self)
			end)
			:catch(reject)
	end):catch(function(...)
		warn("[InventoryServer]: Failed to retrieve player inventory because", ...)
	end)
end

return InventoryServer
