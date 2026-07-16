-- mock/MOAIApp.lua
-- Stub for iOS-only MOAIApp, used on desktop where the real binding doesn't exist.
-- Provides no-op versions of the methods the game calls; constants are set to
-- distinct numbers so the game's switch statements still work even if no
-- transaction ever actually fires.

MOAIApp = {}

-- Listener event constants (the values don't really matter — the game uses
-- them only to register callbacks, and we never invoke those callbacks)
MOAIApp.ASYNC_NAME_RESOLVE              = 1
MOAIApp.PAYMENT_QUEUE_ERROR             = 2
MOAIApp.PAYMENT_QUEUE_NOTIFICATION      = 3
MOAIApp.PAYMENT_QUEUE_TRANSACTION       = 4
MOAIApp.PRODUCT_REQUEST_RESPONSE        = 5

-- Transaction states
MOAIApp.TRANSACTION_STATE_PURCHASED     = 0
MOAIApp.TRANSACTION_STATE_FAILED        = 1
MOAIApp.TRANSACTION_STATE_RESTORED      = 2
MOAIApp.TRANSACTION_STATE_CANCELLED     = 3

-- Domain constants for getDirectoryInDomain
MOAIApp.DOMAIN_APP_SUPPORT              = "app-support"
MOAIApp.DOMAIN_DOCUMENTS                = "documents"
MOAIApp.DOMAIN_CACHES                   = "caches"

-- Listener registration is a no-op
MOAIApp._listeners = {}
function MOAIApp.setListener ( event, callback )
    MOAIApp._listeners [ event ] = callback
end

-- Show a popup. On desktop, just print and call the callback (if any) with 0
-- (= first button, typically "OK").
function MOAIApp.alert ( title, body, callback, ... )
    local buttons = { ... }
    print ( string.format ( "[ALERT] %s: %s", tostring(title), tostring(body) ) )
    if #buttons > 0 then
        print ( "  buttons: " .. table.concat ( buttons, ", " ) )
    end
    if callback then
        -- Defer the callback so it doesn't run inside the alert call site;
        -- the iOS version is async, and some game code assumes that.
        local timer = MOAITimer.new ()
        timer:setSpan ( 0.01 )
        timer:setListener ( MOAITimer.EVENT_TIMER_END_SPAN, function ()
            callback ( 0 )
        end )
        timer:start ()
    end
end

-- DNS resolution — we just pretend success after a frame.
function MOAIApp.asyncNameResolve ( hostname )
    print ( "[mock MOAIApp] asyncNameResolve: " .. tostring(hostname) )
    local cb = MOAIApp._listeners [ MOAIApp.ASYNC_NAME_RESOLVE ]
    if cb then
        local timer = MOAITimer.new ()
        timer:setSpan ( 0.01 )
        timer:setListener ( MOAITimer.EVENT_TIMER_END_SPAN, function ()
            cb ( hostname, "127.0.0.1" )
        end )
        timer:start ()
    end
end

-- In-app purchases are not available on desktop.
function MOAIApp.canMakePayments ()
    return false
end

function MOAIApp.requestProductIdentifiers ( ... )
    print ( "[mock MOAIApp] requestProductIdentifiers (no-op)" )
end

function MOAIApp.requestPaymentForProduct ( productId )
    print ( "[mock MOAIApp] requestPaymentForProduct: " .. tostring(productId) )
end

function MOAIApp.restoreCompletedTransactions ()
    print ( "[mock MOAIApp] restoreCompletedTransactions (no-op)" )
end

-- Used by GetDataPath to pick a writable directory.
function MOAIApp.getDirectoryInDomain ( domain )
    -- Return cwd so save files land next to the game.
    return "."
end

-- Open a URL in the user's browser (Linux: xdg-open).
function MOAIApp.openURL ( url )
    print ( "[mock MOAIApp] openURL: " .. tostring(url) )
    os.execute ( string.format ( "xdg-open '%s' >/dev/null 2>&1 &", url ) )
end
