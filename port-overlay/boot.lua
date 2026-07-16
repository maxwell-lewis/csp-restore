-- boot.lua
-- Desktop-side bootstrap for Crimson Steam Pirates.
-- Run from the project root: moai boot.lua
-- This sets up the few globals the game expects to find pre-set, then
-- chdir's into Pirates/ and executes main.lua exactly as the iOS host would.

print ( "[boot] Crimson Steam Pirates desktop launcher" )

------------------------------------------------------------------
-- API compatibility shims
------------------------------------------------------------------
-- MOAI 1.5 renamed and removed APIs that existed in the Dec 2011 build the
-- game was compiled against. We install thin Lua aliases here so the game's
-- code can run unmodified.

-- getTime: renamed to getDeviceTime in 1.5 (returns wall-clock seconds).
MOAISim.getTime = MOAISim.getDeviceTime

-- Disable the per-scene-switch leak report. The game enabled it on desktop
-- dev builds to dump every object still rooted in _G at scene-close time;
-- 95% of "leaks" are intentional caches (textures in resource buckets, dialog
-- history, persistent particle systems). The noise drowns out real errors.
if MOAISim.setLeakTrackingEnabled then
    MOAISim.setLeakTrackingEnabled ( false )
end
if MOAISim.reportLeaks then
    MOAISim.reportLeaks = function ( ... ) end
end
if MOAISim.reportHistogram then
    MOAISim.reportHistogram = function ( ... ) end
end

-- getSimTime: renamed to getElapsedTime in 1.5. Returns simulated time
-- (frame-driven, in seconds). Used by weaponManager.lua:1199 to stamp
-- projectile launch times for flight-time interpolation.
if not MOAISim.getSimTime then
    MOAISim.getSimTime = MOAISim.getElapsedTime
end

-- getDeviceIDString: iOS UDID accessor, removed in 1.5 (Apple deprecated UDID
-- in 2012). The game uses it to stamp Voyage Complete result records with a
-- per-device identifier for leaderboards/analytics. The 2011 source has no
-- offline fallback, so if this function is nil the whole victory transition
-- crashes mid-record and the scene never advances to voyage-end.
-- Return a stable string so the game treats us as one consistent "device".
if not MOAISim.getDeviceIDString then
    MOAISim.getDeviceIDString = function ()
        return "linux-desktop-port-csp-v1"
    end
end

-- crypto library: LuaCrypto API renames between the version Moai shipped with
-- in Dec 2011 and 1.5's bundled version.
--   crypto.evp.new(alg)  → crypto.digest.new(alg)
--   instance:digest()    → instance:final()
-- The 2011 game uses :digest() to finalize HMAC-SHA1 (utility.lua:706, the
-- signature in Voyage Complete records) and SHA1 of level data (utility.lua:
-- 657, for level integrity check). Both return a 40-char hex string in 1.5,
-- same as 2011's :digest() did. Module-level alias here; the per-instance
-- :digest() → :final() rename is done by direct edit in utility.lua because
-- userdata method dispatch can't be safely intercepted via Lua proxies.
if crypto and crypto.digest and not crypto.evp then
    crypto.evp = crypto.digest
end

-- MOAIHttpTask: we built MOAI without HTTP support (no curl in the host),
-- so MOAIHttpTask doesn't exist. The game uses asyncpost.lua to POST voyage
-- results, store visits, etc. to Bungie's analytics server
-- (aeroapptest.bungie.net), which has been offline for years anyway.
-- Stub the class with a dummy that pretends each request succeeded with an
-- empty response. The AsyncPostQueue's response validator (when present)
-- will reject empty bodies and mark the request for retry in 60s, but it
-- won't crash. Without this, every voyage win triggers a flood of errors.
if not MOAIHttpTask then
    MOAIHttpTask = setmetatable ( {}, { __index = function () return function () end end } )
    MOAIHttpTask.new = function ()
        local task = {}
        function task:setCallback ( cb ) self._cb = cb end
        function task:setHeader ( ... ) end
        function task:setBody ( ... ) end
        function task:setVerb ( ... ) end
        function task:setUrl ( ... ) end
        function task:setUserAgent ( ... ) end
        function task:setTimeout ( ... ) end
        function task:setVerbose ( ... ) end
        function task:setStream ( ... ) end
        function task:setFollowRedirects ( ... ) end
        function task:performAsync ( ... ) end
        function task:performSync ( ... ) end
        function task:httpGet ( ... )
            -- Pretend the request finished (with empty body) on the next
            -- frame so the AsyncPostQueue advances its state machine.
            if self._cb then
                local cb = self._cb
                local t = MOAITimer.new ()
                t:setSpan ( 0, 0.01 )
                t:setListener ( MOAITimer.EVENT_TIMER_END_SPAN, function ()
                    cb ( self )
                end )
                t:start ()
            end
        end
        function task:httpPost ( ... ) return task:httpGet () end
        function task:getString () return "" end
        function task:getSize () return 0 end
        function task:getResponseCode () return 0 end
        function task:getResponseHeader ( ... ) return nil end
        return task
    end
end

-- string.pack / string.unpack: Lua 5.3 builtins, not in 5.1 (which MOAI uses).
-- pathfinding.lua uses bpack/bunpack to encode (x,y) and (x,y,r) tuples into
-- string keys for grid cell lookups. The 2011 game had a native Crimson.packint
-- C++ binding that bypassed string.pack entirely; we don't have that, so we
-- provide a pure-Lua polyfill of "ii" and "iii" (signed 32-bit int sequences).
--
-- IMPORTANT: this matches lpack's calling convention, not Lua 5.3 stdlib:
--   string.pack ( fmt, val1, val2, ... ) → encoded
--   string.unpack ( s, fmt, [init] ) → next_pos, val1, val2, ...
-- The 2011 game was linked against lpack (or an lpack-compatible binding),
-- so it calls `bunpack(e, "ii")` (encoded string first, format second) and
-- `select(2, ...)` to skip the next_pos return. Calls in pathfinding.lua:
-- 38:  return bpack("ii", x, y)
-- 44:  return select(2, bunpack(e, "ii"))
if not string.pack then
    local function pack_i32 ( x )
        x = math.floor ( x )
        if x < 0 then x = x + 0x100000000 end
        return string.char (
            x % 256,
            math.floor ( x / 256 ) % 256,
            math.floor ( x / 65536 ) % 256,
            math.floor ( x / 16777216 ) % 256
        )
    end
    local function unpack_i32 ( s, pos )
        local a, b, c, d = string.byte ( s, pos, pos + 3 )
        local v = a + b * 256 + c * 65536 + d * 16777216
        if v >= 0x80000000 then v = v - 0x100000000 end
        return v, pos + 4
    end
    string.pack = function ( fmt, ... )
        local args = { ... }
        local out, ai = {}, 1
        for c in fmt:gmatch ( "." ) do
            if c == "i" then
                out [ #out + 1 ] = pack_i32 ( args [ ai ] )
                ai = ai + 1
            elseif c == "<" or c == ">" or c == "=" or c == "!" then
                -- endianness markers, ignored
            else
                error ( "string.pack polyfill: unsupported format '" .. c .. "'" )
            end
        end
        return table.concat ( out )
    end
    string.unpack = function ( s, fmt, init )
        init = init or 1
        local out = { 0 } -- placeholder for next_pos at index 1
        local pos = init
        for c in fmt:gmatch ( "." ) do
            if c == "i" then
                local v
                v, pos = unpack_i32 ( s, pos )
                out [ #out + 1 ] = v
            elseif c == "<" or c == ">" or c == "=" or c == "!" then
                -- endianness markers
            else
                error ( "string.unpack polyfill: unsupported format '" .. c .. "'" )
            end
        end
        out [ 1 ] = pos
        return unpack ( out )
    end
end

-- MOAI 1.5 replaces collectgarbage with a warning stub that returns nothing,
-- breaking common Lua patterns like `mem = collectgarbage("count")`. The game
-- uses this in FullGC/StepGC for diagnostics. The clobbering happens on the
-- first sim frame (MOAISim::UpdateLuaCallback), AFTER boot.lua runs — so we
-- can't just override here. Instead we install our shim AND save a reference
-- to the real Lua collectgarbage so we can re-install after MOAI clobbers it
-- on each frame (the heartbeat coroutine handles re-asserting).
local _real_collectgarbage = collectgarbage
local function _make_gc_shim ()
    local _setpause = 200
    local _setstepmul = 200
    return function ( what, arg )
        what = what or "collect"
        if what == "count" then
            local info = MOAISim.getMemoryUsage ()
            return ( info and info.lua or 0 ) / 1024
        elseif what == "collect" then
            MOAISim.forceGC ()
            return 0
        elseif what == "stop" then
            MOAISim.setGCActive ( false )
            return 0
        elseif what == "restart" then
            MOAISim.setGCActive ( true )
            return 0
        elseif what == "step" then
            MOAISim.setGCStep ( arg or 1 )
            return 0
        elseif what == "setpause" then
            local old = _setpause; _setpause = arg; return old
        elseif what == "setstepmul" then
            local old = _setstepmul; _setstepmul = arg; return old
        end
        return 0
    end
end
_G._gc_shim = _make_gc_shim ()
collectgarbage = _G._gc_shim

-- Audio: the 2011 game's iOS path used MOAISim.loadNativeSound / playNativeSound
-- (iOS hardware AAC/IMA4 decoder). 1.5 removed those entirely. On the desktop,
-- the supported path is MOAIUntz, which uses OpenAL/libsndfile under the hood
-- and handles OGG/WAV/MP3/FLAC. It does NOT handle Apple IMA4-compressed AIFC,
-- which is what the IPA shipped.
--
-- Workaround: SFX files were converted .aif → .ogg offline (libvorbis q4 at
-- the original 22050 Hz mono). Music files were already .ogg in the IPA.
-- This shim:
--   1. Initializes MOAIUntzSystem on boot
--   2. Reroutes loadNativeSound to MOAIUntzSound.new() + load(), with .aif
--      stripped to .ogg
--   3. Reroutes playNativeSound / playNativeSoundLooping / stopNativeSound
--      to the corresponding MOAIUntzSound instance methods
-- If MOAIUntzSystem.initialize fails (no audio device in the host
-- environment), we silently fall back to silent stubs so the game still runs.
local _native_sounds = {}     -- id → MOAIUntzSound
local _audio_enabled = false
local _audio_play_count = 0
do
    -- Initialize Untz with explicit params:
    --   sampleRate=44100    matches modern Linux audio defaults; libsndfile
    --                       resamples our 22050 Hz source files on-the-fly
    --   numFrames=2048      smaller buffer than the 8192 default reduces
    --                       latency (≈46 ms vs ≈185 ms) and underrun risk
    --                       in Untz's busy-wait SDL audio thread
    -- After init, master volume drops to 0.7 so the mixer's linear sum across
    -- music + ambient + several concurrent SFX has headroom and doesn't
    -- clip into hard-distortion ("crumpling") on peaks.
    local ok, err = pcall ( function ()
        MOAIUntzSystem.initialize ( 44100, 2048 )
        _audio_enabled = true
    end )
    if ok then
        print ( "[audio] MOAIUntzSystem.initialize OK; audio enabled" )
        pcall ( function () MOAIUntzSystem.setVolume ( 0.7 ) end )
    else
        print ( "[audio] MOAIUntzSystem.initialize FAILED: " .. tostring(err) .. "; running silent" )
    end
end

MOAISim.loadNativeSound = function ( filepath, id, volume )
    if not _audio_enabled then return end
    -- The game asks for .aif but we have .ogg on disk (offline-converted).
    -- Anything else, leave alone (music is already .ogg).
    local actual = filepath:gsub ( "%.aif$", ".ogg" )
    local snd = MOAIUntzSound.new ()
    -- pcall the load: a missing file shouldn't take down the whole shim,
    -- just leave that slot silent.
    local ok, err = pcall ( function () snd:load ( actual ) end )
    if ok then
        -- Honor the per-sound volume the game passed in (music typically
        -- 0.4, ambient loops around 0.5-0.6, hard SFX 1.0). Default to
        -- 1.0 if not specified.
        snd:setVolume ( volume or 1 )
        _native_sounds [ id ] = snd
    else
        print ( "[audio] load FAIL id=" .. tostring(id) .. " path=" .. tostring(actual) .. ": " .. tostring(err) )
    end
end

MOAISim.playNativeSound = function ( id )
    local snd = _native_sounds [ id ]
    if snd then
        -- Restart from the beginning so re-triggers work (cannon fire etc.)
        snd:setPosition ( 0 )
        snd:setLooping ( false )
        snd:play ()
    end
end

MOAISim.stopNativeSound = function ( id )
    local snd = _native_sounds [ id ]
    if snd then snd:stop () end
end

-- Stop every registered native sound. Called from gameplay scene close
-- to make sure no weapon/ambient loops survive the transition back to
-- the chapter-select menu. Music on the main menu is a separately-loaded
-- sound (mainmenuMusic at id=1) which gets re-played by main menu init,
-- so stopping it here is fine — it'll restart on menu enter.
MOAISim.stopAllNativeSounds = function ()
    for _, snd in pairs ( _native_sounds ) do
        pcall ( function () snd:stop () end )
    end
end

MOAISim.playNativeSoundLooping = function ( id, iterations )
    local snd = _native_sounds [ id ]
    if snd then
        snd:setPosition ( 0 )
        -- Match iOS+FMOD semantics from Library/sound.lua:139-143:
        -- positive iterations = play that many times then stop
        -- iterations == nil or <= 0 = loop forever (used for music, ambient)
        -- The native Untz API only has setLooping(bool), so we can express
        -- exactly two cases: play-once (false) and infinite-loop (true).
        -- N>1 finite repeats fall back to play-once - acceptable for SFX
        -- where the game uses iterations=1 to mean "one-shot fire-and-forget"
        -- (cannon shots, lightning, mine drops). Music and ambient use -1.
        if iterations == nil or iterations < 1 then
            snd:setLooping ( true )
        else
            snd:setLooping ( false )
        end
        snd:play ()
    end
end

-- MOAILayer2D:setCamera in 1.5 strictly requires a MOAICamera (or 2D variant),
-- whereas in the 2011 build any MOAITransform was accepted. The game uses
-- MOAITransform.new() everywhere it wants a "camera anchor" (see screen.lua).
-- MOAICamera2D's API is a strict superset of MOAITransform's (verified by
-- probing both metatables) so we can substitute the constructor wholesale:
-- the camera projection it adds is harmless when it's used as a plain
-- transform, and required when it's used as a layer camera.
local _MOAITransform_new = MOAITransform.new
MOAITransform.new = function ( ... )
    return MOAICamera2D.new ( ... )
end

-- MOAIVertexFormat:declareCoord/declareUV/etc. in 1.5 take an extra leading
-- "attribute index" argument (1-based slot in the vertex). In the 2011 API
-- the index was inferred from call order. Detect the old calling convention
-- and forward with a per-instance auto-incrementing index. We patch by
-- replacing entries in the class's shared interface table.
do
    local iface = MOAIVertexFormat.getInterfaceTable ()
    local function wrap ( method_name )
        local real = iface [ method_name ]
        if not real then return end
        iface [ method_name ] = function ( self, a, b, c )
            -- Old API: (self, type, count). c is nil.
            -- New API: (self, index, type, count). c is the count number.
            if c == nil then
                self._next_attr_idx = ( self._next_attr_idx or 0 ) + 1
                return real ( self, self._next_attr_idx, a, b )
            else
                return real ( self, a, b, c )
            end
        end
    end
    wrap ( "declareCoord" )
    wrap ( "declareUV" )
    wrap ( "declareColor" )
    wrap ( "declareAttribute" )
end

-- MOAISimpleShader was removed in 1.5; it was a tint shader, used like:
--   local s = MOAISimpleShader.new()
--   s:setColor(r, g, b, a)
--   prop:setShader(s)
-- and shared across multiple props for batched color updates.
-- In 1.5, MOAIColor is a node with the same setColor/seekColor API. Props
-- support a color "parent" via setAttrLink, so we can install a shim that
-- wraps MOAIColor and intercepts the prop's setShader call to instead
-- create attribute links on each color channel.
do
    MOAISimpleShader = {}
    local _color_attrs = {
        MOAIColor.ATTR_R_COL,
        MOAIColor.ATTR_G_COL,
        MOAIColor.ATTR_B_COL,
        MOAIColor.ATTR_A_COL,
    }
    function MOAISimpleShader.new ()
        local self = {}
        self._color = MOAIColor.new ()
        self._color:setColor ( 1, 1, 1, 1 )
        function self:setColor ( r, g, b, a )
            self._color:setColor ( r, g, b, a or 1 )
        end
        function self:seekColor ( r, g, b, a, t, mode )
            -- gameplay.lua:4227 calls seekColor(0,0,0,1) with no time arg.
            -- MOAIColor.seekColor requires position-6 (t) to be a number;
            -- a nil there crashes "Param type mismatch at position 6".
            -- Default to 0 = instant set.
            return self._color:seekColor ( r, g, b, a or 1, t or 0, mode )
        end
        function self:moveColor ( r, g, b, a, t, mode )
            return self._color:moveColor ( r, g, b, a or 1, t or 0, mode )
        end
        function self:getColor ()
            return self._color:getColor ()
        end
        return self
    end
    -- Patch prop / textbox setShader to detect our shim and route to color links
    -- instead. We need to do this for every class that exposes setShader and is
    -- in the call sites: MOAIProp2D / MOAITextBox at minimum.
    local function patch_setShader ( cls )
        if not cls then return end
        local iface = cls.getInterfaceTable ()
        if not iface then return end
        local real_setShader = iface.setShader
        if not real_setShader then return end
        iface.setShader = function ( self, shader )
            if type ( shader ) == "table" and shader._color then
                -- Apply current color as a snapshot AND wire attribute links
                -- so future shader:setColor calls propagate to this prop.
                local r, g, b, a = shader._color:getColor ()
                self:setColor ( r, g, b, a )
                for _, attr in ipairs ( _color_attrs ) do
                    self:setAttrLink ( attr, shader._color, attr )
                end
            else
                return real_setShader ( self, shader )
            end
        end
    end
    patch_setShader ( MOAIProp2D )
    patch_setShader ( MOAIProp )
    patch_setShader ( MOAITextBox )
end

-- MOAITimer event semantics changed between Dec 2011 and 1.5. In 2011,
-- EVENT_TIMER_LOOP fired whenever the timer reached the end of its span,
-- regardless of MODE. In 1.5 it fires only on loop iterations (MODE = LOOP);
-- one-shot timers fire EVENT_TIMER_END_SPAN instead.
--
-- The game wires EVENT_TIMER_LOOP listeners on MODE = NORMAL timers and
-- expects them to fire after the span elapses. Shim setListener so that
-- registering an EVENT_TIMER_LOOP listener also registers it for
-- EVENT_TIMER_END_SPAN. The 1.5 docs confirm both events deliver the same
-- argument shape (self), so the same callback works for both.
do
    local _trace_id = 0
    local function patch_timer_class ( cls )
        if not cls then return end
        local iface = cls.getInterfaceTable ()
        if not iface or not iface.setListener then return end
        local real = iface.setListener
        iface.setListener = function ( self, event, cb )
            if cb and event == MOAITimer.EVENT_TIMER_LOOP then
                _trace_id = _trace_id + 1
                local id = _trace_id
                local wrapped = function ( ... )
                    print ( "[timer] LOOP listener #" .. id .. " firing" )
                    local ok, err = xpcall ( cb, debug.traceback, ... )
                    if not ok then
                        print ( "[timer] LOOP listener #" .. id .. " ERROR: " .. tostring(err) )
                    end
                end
                real ( self, event, wrapped )
                real ( self, MOAITimer.EVENT_TIMER_END_SPAN, wrapped )
            else
                real ( self, event, cb )
            end
        end
    end
    -- Classes that are MOAITimer or inherit from it
    patch_timer_class ( MOAITimer )
    patch_timer_class ( MOAIAnim )
    patch_timer_class ( MOAIEaseDriver )
end

-- MOAITimer:setLength(t) (2011) was renamed to setSpan(t) in 1.5. Single-arg
-- setSpan is the equivalent: it sets the span 0→t. Used by hudHandler.lua's
-- boarding action code to insert delays between attack animations
-- (`d = MOAIEaseDriver.new(); d:setLength(0.6); d:start();
--   MOAIThread.blockOnAction(d)` → a 0.6s sleep). May also be used elsewhere
-- in animations. Add an alias to MOAITimer's interface table so it cascades
-- to all subclasses (Anim, EaseDriver, Timer itself).
do
    local function alias_setLength ( cls )
        if not cls then return end
        local iface = cls.getInterfaceTable ()
        if iface and iface.setSpan and not iface.setLength then
            iface.setLength = iface.setSpan
        end
    end
    alias_setLength ( MOAITimer )
    alias_setLength ( MOAIAnim )
    alias_setLength ( MOAIEaseDriver )
end

-- MOAIParticleEmitter was split in 1.5 into MOAIParticleTimedEmitter (emits
-- continuously at a frequency/emission rate) and MOAIParticleDistanceEmitter
-- (emits based on movement). The game's emitters use setFrequency/setEmission
-- on what was MOAIParticleEmitter -- that's the TimedEmitter case. Alias it.
if not MOAIParticleEmitter then
    MOAIParticleEmitter = MOAIParticleTimedEmitter
end

-- MOAIVertexBuffer:setPenWidth(w) (2011) configured the line/point thickness
-- for any GL_LINES/GL_POINTS primitives drawn from this VBO. In 1.5 the pen
-- width moved to MOAIGfxDevice.setPenWidth() as a global GL state.
-- The game uses setPenWidth(1) cosmetically on triangle VBOs (no effect) and
-- setPenWidth(3) on some HUD line VBOs (hull gauge, engine line, armory
-- dividers — those will render at 1px instead of 3px). Stub it as a no-op
-- on the VBO for now; nothing crashes.
do
    local iface = MOAIVertexBuffer.getInterfaceTable ()
    if not iface.setPenWidth then
        iface.setPenWidth = function ( self, w ) end
    end
end

-- MOAIVertexBuffer:setPrimType and the GL_* primitive constants (2011) moved
-- to MOAIMesh in 1.5. The game writes vertices into a VBO, calls
-- vbo:setPrimType(...), then wraps it in a MOAIMesh via mesh:setVertexBuffer.
-- Forward the stashed prim type onto the mesh when the VBO is attached.
do
    -- Copy GL_* constants from MOAIMesh onto MOAIVertexBuffer so the game's
    -- references like MOAIVertexBuffer.GL_TRIANGLE_FAN resolve correctly.
    for k, v in pairs ( MOAIMesh ) do
        if type ( k ) == "string" and k:sub ( 1, 3 ) == "GL_"
                and MOAIVertexBuffer [ k ] == nil then
            MOAIVertexBuffer [ k ] = v
        end
    end
    local vbo_iface = MOAIVertexBuffer.getInterfaceTable ()
    local mesh_iface = MOAIMesh.getInterfaceTable ()
    if not vbo_iface.setPrimType then
        vbo_iface.setPrimType = function ( self, prim )
            self._primType = prim
        end
    end
    -- Patch MOAIMesh:setVertexBuffer to inherit the VBO's stashed prim type.
    local real_setVertexBuffer = mesh_iface.setVertexBuffer
    mesh_iface.setVertexBuffer = function ( self, vbo, ... )
        local result = real_setVertexBuffer ( self, vbo, ... )
        if vbo and vbo._primType and mesh_iface.setPrimType then
            mesh_iface.setPrimType ( self, vbo._primType )
        end
        return result
    end
end

-- MOAIBox2DWorld.decomposePolygon(list) (2011) split a possibly-concave
-- polygon (flat {x1,y1,x2,y2,...} list) into an array of convex polygons,
-- each represented as a flat list. Used by collision.lua to register island
-- and ship hulls as Box2D fixtures (which only accept convex polys of ≤8
-- verts). In 1.5 this helper was removed -- the engine expects the game to
-- pre-triangulate. We provide a Lua-side ear-clipping implementation: every
-- output polygon is a triangle (3 verts, well under 8), and the caller's
-- loop "for i, poly in ipairs(polyList) do body:addPolygon(poly) end"
-- still works without modification.
if MOAIBox2DWorld and not MOAIBox2DWorld.decomposePolygon then
    -- (helper functions and shim below)
    local function signed_area ( pts )
        local n = #pts / 2
        local a = 0
        for i = 1, n do
            local j = ( i % n ) + 1
            local xi, yi = pts [ i*2-1 ], pts [ i*2 ]
            local xj, yj = pts [ j*2-1 ], pts [ j*2 ]
            a = a + xi * yj - xj * yi
        end
        return a / 2
    end
    local function point_in_triangle ( px, py, ax, ay, bx, by, cx, cy )
        local d1 = ( px - bx ) * ( ay - by ) - ( ax - bx ) * ( py - by )
        local d2 = ( px - cx ) * ( by - cy ) - ( bx - cx ) * ( py - cy )
        local d3 = ( px - ax ) * ( cy - ay ) - ( cx - ax ) * ( py - ay )
        local has_neg = ( d1 < 0 ) or ( d2 < 0 ) or ( d3 < 0 )
        local has_pos = ( d1 > 0 ) or ( d2 > 0 ) or ( d3 > 0 )
        return not ( has_neg and has_pos )
    end
    MOAIBox2DWorld.decomposePolygon = function ( flat )
        -- Build (x, y) vertex list, ensuring CCW order.
        local n = #flat / 2
        if n < 3 then return {} end
        local verts = {}
        if signed_area ( flat ) < 0 then
            -- CW: reverse to CCW
            for i = n, 1, -1 do
                verts [ #verts + 1 ] = { x = flat [ i*2-1 ], y = flat [ i*2 ] }
            end
        else
            for i = 1, n do
                verts [ #verts + 1 ] = { x = flat [ i*2-1 ], y = flat [ i*2 ] }
            end
        end
        local triangles = {}
        local guard = 0
        while #verts >= 3 and guard < 10000 do
            guard = guard + 1
            local nv = #verts
            local found_ear = false
            for i = 1, nv do
                local prev_i = ( ( i - 2 ) % nv ) + 1
                local next_i = ( i % nv ) + 1
                local a, b, c = verts [ prev_i ], verts [ i ], verts [ next_i ]
                -- Convex (CCW) check: cross product of (b-a) x (c-b) > 0
                local cross = ( b.x - a.x ) * ( c.y - a.y ) - ( b.y - a.y ) * ( c.x - a.x )
                if cross > 0 then
                    -- Check no other vertex is inside this triangle
                    local clean = true
                    for j = 1, nv do
                        if j ~= prev_i and j ~= i and j ~= next_i then
                            if point_in_triangle ( verts[j].x, verts[j].y,
                                                   a.x, a.y, b.x, b.y, c.x, c.y ) then
                                clean = false
                                break
                            end
                        end
                    end
                    if clean then
                        triangles [ #triangles + 1 ] = { a.x, a.y, b.x, b.y, c.x, c.y }
                        table.remove ( verts, i )
                        found_ear = true
                        break
                    end
                end
            end
            if not found_ear then break end -- bail on degenerate / collinear polys
        end
        return triangles
    end
    -- Smoke test: confirm shim works on a concave L-shape
    do
        local L = { 0,0, 4,0, 4,2, 2,2, 2,4, 0,4 }
        local tris = MOAIBox2DWorld.decomposePolygon ( L )
        print ( string.format ( "[boot] decomposePolygon test: L-shape → %d triangles (expected 4)", #tris ) )
    end
end

-- MOAIParticleScript renamed the atan2rot op (compute the angle of a
-- velocity vector in degrees) to vecAngle in 1.5. The original took
-- (dst, dy, dx) following atan2 convention; vecAngle takes (dst, x, y).
do
    local iface = MOAIParticleScript.getInterfaceTable ()
    if not iface.atan2rot and iface.vecAngle then
        iface.atan2rot = function ( self, dst, dy, dx )
            return iface.vecAngle ( self, dst, dx, dy )
        end
    end
end

-- MOAIProp2D:setRepeat(bool) (2011) configured the prop's grid to wrap texture
-- coords beyond the grid's extents. In 1.5 it moved to MOAIGrid:setRepeat.
-- The game's gameplay.lua does:
--   bgprop:setDeck(...); bgprop:setGrid(bg); bgprop:setRepeat(true)
-- so we install a shim that delegates to the prop's current grid.
do
    local prop_iface = MOAIProp2D.getInterfaceTable ()
    local grid_iface = MOAIGrid.getInterfaceTable ()
    if not prop_iface.setRepeat and grid_iface.setRepeat then
        local real_setGrid = prop_iface.setGrid
        prop_iface.setGrid = function ( self, grid )
            self._grid = grid
            return real_setGrid ( self, grid )
        end
        prop_iface.setRepeat = function ( self, x, y )
            if self._grid and grid_iface.setRepeat then
                if y == nil then y = x end
                return grid_iface.setRepeat ( self._grid, x, y )
            end
        end
    end
end

-- Layer:removeProp(nil) was tolerated in 2011 (silent no-op); in 1.5 it
-- raises "expected userdata". The game's scene-close code routinely calls
-- removeProp on optional UI elements that may never have been created
-- (especially anything tied to Facebook/Game Center, which are stubbed on
-- desktop). Same is true for insertProp -- some level-setup paths try to
-- insert AI-target indicators before the AI target ship is created.
-- Make both nil-tolerant.
do
    local function patch_layer_method ( cls, method )
        if not cls then return end
        local iface = cls.getInterfaceTable ()
        if not iface or not iface [ method ] then return end
        local real = iface [ method ]
        iface [ method ] = function ( self, prop )
            if prop == nil then return end
            -- In 1.5, removeProp/insertProp strictly type-check the prop as
            -- a MOAIProp. The 2011 game has some cleanup paths that pass
            -- MOAITransform or MOAICamera by mistake (decompiler artifacts,
            -- or just bugs that iOS-MOAI tolerated). pcall catches the
            -- error so the game continues. The C call also writes a "Bad
            -- cast at position 2" line to stderr before returning, which
            -- is cosmetic noise — non-blocking, but visible in the log
            -- during ship creation. We tried a metatable-walk type-check
            -- to suppress the stderr, but MOAI's class hierarchy isn't
            -- exposed in a way Lua can walk reliably (subclasses like
            -- MOAITextBox don't show MOAIProp2D in their metatable chain),
            -- so the type-check would reject legitimate props. Living
            -- with the noise for now.
            local ok = pcall ( real, self, prop )
            if not ok then return end
        end
    end
    for _, cls in ipairs ( { MOAILayer2D, MOAILayer, MOAIPartition } ) do
        patch_layer_method ( cls, "removeProp" )
        patch_layer_method ( cls, "insertProp" )
    end
end

-- MOAIFont in 2011 stored a default scale/pointsize internally, accessed via
-- getScale()/setScale(). In 1.5 the size is per-textbox via setTextSize();
-- the font's per-load size is set in setDefaultSize() but not readable back.
-- The game does `font:loadFromTTF(file, chars, pointsize, dpi)` then later
-- `font:getScale()` to recover the pointsize. We intercept loadFromTTF to
-- remember the size, and expose it via getScale().
--
-- Additional upscale work: when DESKTOP_UPSCALE_FACTOR > 1, the OpenGL
-- viewport stretches everything 3x (or whatever the factor is) including
-- text textures. By default the game bakes glyphs at DPI=163 (iPhone
-- Retina). After 3x viewport upscale, each glyph pixel covers a 3x3 block
-- onscreen → blocky text. We multiply the bake DPI by the upscale factor
-- so each glyph is baked 3x more detailed in the texture atlas; the
-- per-textbox setTextSize stays at the same logical size, so the glyphs
-- get downsampled cleanly at draw time. Net result: text is rendered at
-- roughly the same physical pixel density as the desktop window.
do
    local font_iface = MOAIFont.getInterfaceTable ()
    local real_loadFromTTF = font_iface.loadFromTTF
    if real_loadFromTTF and not font_iface.getScale then
        font_iface.loadFromTTF = function ( self, file, chars, pointsize, dpi )
            self._scale = pointsize
            local upscale = DESKTOP_UPSCALE_FACTOR or 1
            if upscale > 1 then
                return real_loadFromTTF ( self, file, chars, pointsize, ( dpi or 72 ) * upscale )
            end
            return real_loadFromTTF ( self, file, chars, pointsize, dpi )
        end
        font_iface.getScale = function ( self )
            return self._scale or 12
        end
        font_iface.setScale = function ( self, s )
            self._scale = s
            if font_iface.setDefaultSize then
                font_iface.setDefaultSize ( self, s )
            end
        end
    end
end

-- Text scaling for desktop upscale. The game's text sizes were tuned for a
-- 3.5-inch iPhone held close to the face. On a 1440x960 desktop window
-- (3x upscale) viewed from desk distance, those same logical text sizes
-- come out physically larger but feel smaller relative to viewing distance.
-- More importantly, MOAI rasterizes glyphs at the textbox's *current* size,
-- not the font's bake-time DPI; that means we can't get sharper text by
-- baking the font at higher DPI alone. We have to ask the textbox for
-- bigger physical glyphs.
--
-- We intercept MOAITextBox:setTextSize and multiply by a tunable factor.
-- Default 1.0 (no change). Set DESKTOP_TEXT_SCALE in boot.lua to enable.
--
-- WARNING: text upscaling can overflow boxes laid out for the smaller
-- size (button labels, HUD elements). 1.3-1.5x is usually safe; >1.5 may
-- clip in tight UI elements. Dialog boxes (210x70 logical) have plenty
-- of room.
do
    local tbox_iface = MOAITextBox.getInterfaceTable ()
    local real_setTextSize = tbox_iface.setTextSize
    if real_setTextSize then
        tbox_iface.setTextSize = function ( self, size, ... )
            local scale = DESKTOP_TEXT_SCALE or 1
            return real_setTextSize ( self, size * scale, ... )
        end
    end
end

-- Trace every require/dofile so we can see exactly where execution stops.
do
    local _require = require
    require = function ( name )
        io.write ( "[boot] require '" .. tostring(name) .. "' ... " ) io.flush ()
        local ok, mod = pcall ( _require, name )
        if ok then
            io.write ( "ok\n" ) io.flush ()
            -- IAP unlock hook: when 'store' loads, wrap Store.init so that
            -- after it completes, every chapter is marked purchased. The
            -- game's gating condition (store.lua:210) only sets purchased=true
            -- if a real Apple StoreKit transaction was recorded — which can
            -- never happen now that Bungie's aero servers are offline and
            -- the app is delisted from the App Store. The level scripts
            -- themselves are all shipped in the IPA; only this flag stops
            -- chapter 3 from being playable.
            if name == "store" and _G.Store and _G.Store.init and not _G.Store._unlocked_hooked then
                _G.Store._unlocked_hooked = true
                local _real_init = _G.Store.init
                _G.Store.init = function ( callback )
                    -- Pre-populate settings.purchased with every chapter key
                    -- so Store.hasBoughtProduct(...) returns true everywhere.
                    -- (Just setting chapter.purchased=true isn't enough — the
                    -- main menu calls Store.hasBoughtChapter which checks
                    -- settings.purchased[key].)
                    if _G.settings then
                        _G.settings.purchased = _G.settings.purchased or {}
                        if _G.levelList and _G.levelList.sagas then
                            for s, saga in ipairs ( _G.levelList.sagas ) do
                                for c, chapter in ipairs ( saga.chapters ) do
                                    local key = _G.Store.getChapterProductKey ( s, c )
                                    _G.settings.purchased [ key ] = true
                                end
                            end
                        end
                    end
                    _real_init ( callback )
                    -- After init, also defensively force every chapter to
                    -- purchased=true in the live levelList table.
                    if _G.levelList and _G.levelList.sagas then
                        for s, saga in ipairs ( _G.levelList.sagas ) do
                            for c, chapter in ipairs ( saga.chapters ) do
                                chapter.purchased = true
                            end
                        end
                        print ( "[boot] IAP unlock: all chapters marked as purchased" )
                    end
                end
            end
            return mod
        else
            io.write ( "FAILED: " .. tostring(mod) .. "\n" ) io.flush ()
            error ( mod )
        end
    end
    local _dofile = dofile
    dofile = function ( path )
        io.write ( "[boot] dofile '" .. tostring(path) .. "' ... " ) io.flush ()
        -- Capture ALL return values, not just the first. Several game files
        -- return multiple values (e.g. img_iphone/fxlist.lua returns
        -- (fxList, particleList) — the second was being silently dropped,
        -- making particleList nil and causing ship-death-explosion triggers
        -- to error every frame, which kept the death-explosion timer
        -- looping forever).
        --
        -- pcall returns (ok, v1, v2, ...); we forward v1..vN by capturing
        -- count via select('#') so trailing nils survive.
        local function capture ( ok, ... )
            return ok, select ( '#', ... ), { ... }
        end
        local ok, n, vals = capture ( pcall ( _dofile, path ) )
        if ok then
            io.write ( "ok\n" ) io.flush ()
            return unpack ( vals, 1, n )
        else
            local err = vals [ 1 ]
            io.write ( "FAILED: " .. tostring(err) .. "\n" ) io.flush ()
            error ( err )
        end
    end
end

-- Force iPhone UI mode. The IPA only ships iPhone-resolution assets
-- (Pirates/img_iphone/, Pirates/particles_iphone/), so we MUST simulate
-- a 480x320 screen even on a larger monitor. screen.lua honors
-- SIMULATE_SCREEN_SIZE if set before it runs.
SIMULATE_SCREEN_SIZE = { 480, 320 }

-- Display upscale for desktop. The game's logical resolution stays at the
-- iPhone-native 480x320 (so all UI positioning, hit-testing, and asset
-- selection still work), but the OpenGL viewport upscales to the desktop
-- window dimensions. screen.lua reads this and computes DISPLAY_WIDTH =
-- SCREEN_WIDTH * factor before the viewport setSize call and openWindow.
--
-- Factor choices (480x320 has 1.5:1 aspect):
--   2  →  960x640   (original iPhone 4 Retina pixel count, small window)
--   3  → 1440x960   (pixel-perfect, fits in 1080p with letterbox top/bottom)
--   4  → 1920x1280  (taller than 1080p, requires a 1440p+ monitor)
-- Set to nil or 1 to skip upscale.
DESKTOP_UPSCALE_FACTOR = 3

-- Multiply all text sizes by this. The original game's text was tuned for a
-- 3.5" iPhone screen held close; on a 1440x960 desktop window viewed at
-- normal monitor distance, the dialog text feels small. 1.3-1.5 is the
-- sweet spot: noticeably larger without overflowing box layouts. Above 1.5
-- some UI text (HUD ship-detail labels, button captions in tight panels)
-- may clip. Set to 1 to disable.
DESKTOP_TEXT_SCALE = 1.4

-- Box2D-thrust calibration override. The original game's 5.5x multiplier
-- in collision.lua (turn-start thrust calculation) was tuned for 2011-era
-- Box2D 2.1. The 1.5 build uses Box2D 2.3, which integrates linear damping
-- differently and produces a consistent 0.49x distance ratio with the
-- original multiplier. Doubling to 11.0 brings ships to their intended
-- per-turn arc length. If empirical measurement shows the ratio drifting
-- from 1.0 (in either direction), adjust this multiplier by the inverse
-- of the observed ratio (e.g. if ratio is 0.95, bump to 11.0 / 0.95).
DESKTOP_THRUST_MULTIPLIER = 11.0

-- The game's bytecode strings included "GetDataPath" before main.lua
-- defines it; the function is defined in main.lua. We do NOT need to
-- pre-define it.

-- main.lua references MOAIInputMgr.configuration as a property. The
-- desktop host already sets it to "AKUGlut" via AKUSetInputConfigurationName.
-- screen.lua's classifier doesn't match "akuglut" against iOS/Android
-- patterns, so both iOS and ANDROID flags will be false — exactly what
-- we want.

-- chdir into Pirates/ and execute main.lua. This matches the iOS host
-- which sets the working directory to the .app bundle root and then
-- runs Pirates/main.lua, which in turn sets package.path to find both
-- ./?.lua (Pirates) and ../Library/?.lua.
MOAIFileSystem.setWorkingDirectory ( "Pirates" )

-- Save persistence: GetDataPath() returns "data" on non-iOS/non-Android
-- (utility.lua:913-919), relative to the current working dir. The directory
-- doesn't exist on a fresh checkout, so PersistentTable's load fails silently
-- and settings/profile/scores reset on every launch. Create it now.
if MOAIFileSystem.affirmPath then
    MOAIFileSystem.affirmPath ( "data" )
else
    os.execute ( "mkdir -p data" )
end
-- Heartbeat: launch a coroutine that prints elapsed time every second so
-- we can see whether the sim is actually stepping.
local heartbeat = MOAICoroutine.new ()
heartbeat:run ( function ()
    -- On first tick, re-install the collectgarbage shim if MOAI clobbered
    -- it. We check on every frame for the first few frames to be safe.
    local last = 0
    while true do
        if collectgarbage ~= _G._gc_shim then
            collectgarbage = _G._gc_shim
        end
        local t = MOAISim.getElapsedTime ()
        if t - last >= 1.0 then
            print ( string.format ( "[heartbeat] elapsed=%.2fs frames=%d nextScene=%s currentScene=%s",
                t, MOAISim.getElapsedFrames (),
                tostring(_G.nextScene), tostring(_G.currentScene) ) )
            last = t
        end
        coroutine.yield ()
    end
end )
dofile ( "main.lua" )
