-- mock/MOAISocialConnect.lua
-- Stub for iOS-only MOAISocialConnect (Facebook integration).
-- We expose just enough surface area to let the game's social.lua run
-- without ever actually logging anyone in.

MOAISocialConnect = {}
MOAISocialConnect.__index = MOAISocialConnect

MOAISocialConnect.EVENT_LOGIN_STATUS   = 1
MOAISocialConnect.EVENT_REQUEST_STATUS = 2

function MOAISocialConnect.new ()
    local self = setmetatable ( {}, MOAISocialConnect )
    self._listeners = {}
    return self
end

function MOAISocialConnect:setListener ( event, callback )
    self._listeners [ event ] = callback
end

function MOAISocialConnect:init ( ... )
    print ( "[mock MOAISocialConnect] init (no-op)" )
end

function MOAISocialConnect:login ( ... )
    -- Pretend the login failed (user cancelled), so the game doesn't sit
    -- waiting for the network forever.
    print ( "[mock MOAISocialConnect] login -> declining" )
    local cb = self._listeners [ MOAISocialConnect.EVENT_LOGIN_STATUS ]
    if cb then cb ( self, false, "cancelled" ) end
end

function MOAISocialConnect:logout ( ... )
    print ( "[mock MOAISocialConnect] logout (no-op)" )
end

function MOAISocialConnect:request ( endpoint, ... )
    print ( "[mock MOAISocialConnect] request: " .. tostring(endpoint) .. " (no-op)" )
end

function MOAISocialConnect:isLoggedIn ()
    return false
end
