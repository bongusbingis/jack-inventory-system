--!strict

---> dependencies
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Packages = ReplicatedStorage:WaitForChild("Packages")

local ByteNet = require(Packages.ByteNet)

return ByteNet.defineNamespace("Inventory", function()
    return {
        removeItems = ByteNet.definePacket({
            value = ByteNet.struct({
                itemsType = ByteNet.string,
                items = ByteNet.array(ByteNet.string),
            }),
        }),
        setItemEquipped = ByteNet.definePacket({
            value = ByteNet.struct({
                itemId = ByteNet.string,
                itemType = ByteNet.string,
                equipped = ByteNet.bool,
            }),
        }),
        useBoost = ByteNet.definePacket({
            value = ByteNet.string,
        }),
        onChange = ByteNet.definePacket({
            value = ByteNet.struct({
                action = ByteNet.string, -- "add", "remove", "setEquipState"
                itemId = ByteNet.string,
                itemsType = ByteNet.string,
            })
        }),
    }
end)