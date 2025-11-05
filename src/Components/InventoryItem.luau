--!strict
local InventoryItem = { Prototype = {} }

---> dependencies
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Packages = ReplicatedStorage:WaitForChild("Packages")

local Loader = require(Packages.Loader)
local Packets = require(script.Parent.Packets)
local Utility = require(script.Parent.Utility)

---> types
type Metadata = {
	[string]: any,
}

export type OnChangeData = {
	action: string, -- "added", "removed", "metadataChanged"
	itemId: string,
	itemsType: string,
}

export type InventoryItemRoot = {
	Name: string,
	Rarity: string,
	Metadata: Metadata?,
	Stackable: boolean?,
}

export type InventoryItem = typeof(setmetatable(
	{} :: {
		Name: string,
		Rarity: string,
		_player: Player,
		_inventory_object: {},
		_type: string,
		_id: string,
	},
	{ __index = InventoryItem.Prototype }
))

export type InventoryRoot = { [string]: InventoryItemRoot }

---> constants
local IS_SERVER = RunService:IsServer()
local ITEM_DATA_MAP = require(script.Parent.ItemsMap)

---> private helpers
local function getSharedData(self: InventoryItem)
	local itemTypeSharedData = ITEM_DATA_MAP[self._type]
	if itemTypeSharedData then
		return itemTypeSharedData[self.Name]
	end
	return nil
end

---> private
local function serverGetPlayerInventoryItems(player: Player, itemType: string): InventoryRoot
	local _, playerData = Loader.Services.DataService:GetDataAsync(player):await()
	return playerData.Inventory.Items[itemType]
end

---> methods

function InventoryItem.Prototype._getSharedData(self: InventoryItem)
	local sharedData = getSharedData(self)
	rawset(self, "SharedData", sharedData)
	return sharedData
end

local ItemMetatable = {
	__index = function(tbl: InventoryItem, key: string)
		if key == "SharedData" then
			return InventoryItem.Prototype._getSharedData(tbl)
		elseif key == "Metadata" then
			local metadata = InventoryItem.Prototype._getMetadataTable(tbl)
			if metadata then
				rawset(tbl, "Metadata", metadata)
			end
			return metadata
		end
		return InventoryItem.Prototype[key]
	end,
}

-- Dispatches an inventory change event to the client (server-side only).
-- @param data: table - A dictionary containing the change type, itemId, and item category.
function InventoryItem.Prototype._serverDispatchOnChange(self: InventoryItem, data: {})
	self._inventory_object:_serverDispatchOnChange(self._player, data)
end

-- Removes the item from the player's inventory.
-- If executed on the server, the item is removed from persistent storage.
-- If executed on the client, a request is sent to the server to remove the item.
function InventoryItem.Prototype.Remove(self: InventoryItem): ()
	if IS_SERVER then
		local _, playerData = Loader.Services.DataService:GetDataAsync(self._player):await()
		playerData:SetValue({ "Inventory", "Items", self._type, self._id }, nil)
		self:_serverDispatchOnChange({
			action = "removed",
			itemId = self._id,
			itemsType = self._type,
		})
	else
		Packets.removeItems.send({
			itemsType = self._type,
			items = { self._id },
		})
	end
end

-- Determines whether the item is currently equipped.
-- @return boolean - True if the item is equipped; false otherwise.
function InventoryItem.Prototype.IsEquipped(self: InventoryItem): boolean
	return self:GetMetadata("Equipped")
end

-- Toggles the equipped state of the item
-- @return void
function InventoryItem.Prototype.ToggleEquipped(self: InventoryItem): ()
	if self:IsEquipped() then
		self:Unequip()
	else
		self:Equip()
	end
end

function InventoryItem.Prototype.Use(self: InventoryItem): ()
	if IS_SERVER then
		Loader.Services.BoostService:UseItem(self._player, self):andThen(function()
			self:Remove()
		end)

	else
		Packets.useBoost.send(self._id)
	end
end

-- Equips the item.
-- On the server, equips the item; if this action would cause equipped limits
-- to be exceeded for this type, the first equipped item will be unequipped
-- On the client, sends a request to the server to equip the item.
-- @return void
function InventoryItem.Prototype.Equip(self: InventoryItem): ()
	if self:IsEquipped() then
		warn(`[InventoryItem]: {self.Name} is already equipped`)
		return
	end

	if IS_SERVER then
		local equippedItems, numberOfEquippedItems = self._inventory_object:Filter(function(_item: InventoryItem)
			return _item:IsEquipped()
		end)

		if numberOfEquippedItems >= Utility.GetInventoryLimit("Equipped", self._type) then
			local _, toUnequip: InventoryItem = next(equippedItems, nil)
			toUnequip:Unequip()
		end

		self:UpsertMetadata({ Equipped = true })
	else
		Packets.setItemEquipped.send({
			itemId = self._id,
			itemType = self._type,
			equipped = true,
		})
	end
end

-- Unequips the item.
-- On the server, updates the metadata to reflect the unequipped state.
-- On the client, sends a request to the server to unequip the item.
function InventoryItem.Prototype.Unequip(self: InventoryItem): ()
	if not self:IsEquipped() then
		warn(`[InventoryItem]: {self.Name} is not equipped`)
		return
	end

	if IS_SERVER then
		self:UpsertMetadata({ Equipped = false })
	else
		Packets.setItemEquipped.send({
			itemId = self._id,
			itemType = self._type,
			equipped = false,
		})
	end
end

function InventoryItem.Prototype.GetMetadata(self: InventoryItem, key: string): any | nil
	local rawData = self._inventory_object.Metadata._raw_data
	if rawData and rawData[self._id] and rawData[self._id].Metadata then
		return rawData[self._id].Metadata[key]
	end
	return nil
end

function InventoryItem.Prototype._getMetadataTable(self: InventoryItem): Metadata?
	local rawData = self._inventory_object.Metadata._raw_data
	if rawData and rawData[self._id] then
		return rawData[self._id].Metadata
	end
	return nil
end

-- Updates or inserts metadata for the inventory item (server-side only).
-- Accepts either a metadata table or a function that receives current metadata and returns a new table.
-- Stackable items do not support unique metadata updates.
-- @param metadataOrPredicate: table | (Metadata) -> Metadata - The metadata to apply or a function to generate it dynamically.
---> server-only
if IS_SERVER then
	function InventoryItem.Prototype.UpsertMetadata(
		self: InventoryItem,
		metadataOrPredicate: { [string]: any } | (current: Metadata) -> Metadata
	): ()

		local _, playerData = Loader.Services.DataService:GetDataAsync(self._player):await()
		local function setValue(key: string, value: any)
			playerData:SetValue({ "Inventory", "Items", self._type, self._id, "Metadata", key }, value)
		end

		local playerInventoryRoot = serverGetPlayerInventoryItems(self._player, self._type)
		if not playerInventoryRoot[self._id].Metadata then
			playerInventoryRoot[self._id].Metadata = {}
		end

		local rawData = self._inventory_object.Metadata._raw_data
		if rawData and not rawData[self._id].Metadata then
			rawData[self._id].Metadata = {}
		end

		local metadata = {}
		if typeof(metadataOrPredicate) == "function" then
			metadata = metadataOrPredicate(playerInventoryRoot[self._id].Metadata)
		else
			metadata = metadataOrPredicate
		end

		if metadata and next(metadata) then
			for key, value in metadata do
				setValue(key, value)
				if rawData and rawData[self._id] then
					if not rawData[self._id].Metadata then
						rawData[self._id].Metadata = {}
					end
					rawData[self._id].Metadata[key] = value
				end
			end
		end

		self:_serverDispatchOnChange({
			action = "metadataChanged",
			itemId = self._id,
			itemsType = self._type,
		})
	end
end

---> constructor
-- Constructs a new InventoryItem instance.
-- Performs validation before initializing internal references and metadata.
-- @param player: Player - The player who owns the item.
-- @param itemId: string - The unique identifier of the item.
-- @param itemType: string - The category of the item (e.g., "Fruits", "Weapons").
-- @param itemData: InventoryItemRoot - The raw data associated with the item.
-- @param inventoryRef: InventoryRoot - A reference to the player's full inventory.
-- @return InventoryItem - The newly constructed inventory item instance.

return function(
	player: Player,
	itemId: string,
	itemType: string,
	itemData: InventoryItemRoot,
	inventoryObject: {}
): InventoryItem
	local success, result = Utility.IsValidItem(itemId, itemType, itemData)
	if not success then
		warn("[InventoryItem]: Failed to add item because", result)
		return
	end

	local self = {
		Name = itemData.Name,
		Rarity = itemData.Rarity,
		_player = player,
		_id = itemId,
		_type = itemType,
		_inventory_object = inventoryObject,
	}

	return setmetatable(self, ItemMetatable)
end
