-- Port of lib/services/discord/*: Rich Presence plus the friend-invite
-- flow (OAuth, friends list, activity invites, join callback) over the
-- Discord Social SDK (discord_partner_sdk.dll) via LuaJIT FFI.
--
-- Everything is best-effort: on any platform/DLL/SDK failure the module
-- stays disabled and every call is a no-op (or resolves to failure), since
-- this is decorative and must never crash or block a game.
--
-- Threading/re-entrancy: the SDK only invokes callbacks from inside
-- Discord_RunCallbacks(), pumped from D.update(). Callbacks just decode
-- their data (pointers are only valid during the call) into `events`;
-- continuations run after the pump returns.
--
-- ABI note: several SDK callbacks take Discord_String {ptr,size} BY VALUE.
-- LuaJIT callbacks can't receive structs by value, but on Win64 any struct
-- that isn't 1/2/4/8 bytes is passed as a pointer to a caller-made copy, so
-- those parameters are declared Discord_String* below -- ABI-identical.
local ffi = require("ffi")
local fs = require("src.data.fs")
local settings = require("src.data.settings")

local D = {}

local APPLICATION_ID = 1551391208423555102ULL
local PUMP_INTERVAL = 0.1
local READY_TIMEOUT = 15

-- Enum values (cdiscord.h), as named in the Dart bindings.
D.statusReady = 3              -- Discord_Client_Status_Ready
local ACTIVITY_PLAYING = 0     -- Discord_ActivityTypes_Playing
local RELATIONSHIP_FRIEND = 1  -- Discord_RelationshipType_Friend
local PARTY_PRIVATE = 0        -- Discord_ActivityPartyPrivacy_Private
local PLATFORM_DESKTOP = 1     -- Discord_ActivityGamePlatforms_Desktop
local TOKEN_BEARER = 1         -- Discord_AuthorizationTokenType_Bearer

-- Discord_StatusType -> label (Invisible friends are reported as Offline).
D.statusLabels = { [0] = "Online", [1] = "Offline", [3] = "Idle", [4] = "Do Not Disturb", [6] = "Streaming" }

local CDEF = [[
typedef struct { void* opaque; } Discord_Client;
typedef struct { void* opaque; } Discord_Activity;
typedef struct { void* opaque; } Discord_ClientResult;
typedef struct { void* opaque; } Discord_AuthorizationArgs;
typedef struct { void* opaque; } Discord_AuthorizationCodeVerifier;
typedef struct { void* opaque; } Discord_AuthorizationCodeChallenge;
typedef struct { void* opaque; } Discord_ActivityParty;
typedef struct { void* opaque; } Discord_ActivitySecrets;
typedef struct { void* opaque; } Discord_RelationshipHandle;
typedef struct { void* opaque; } Discord_UserHandle;
typedef struct { uint8_t* ptr; size_t size; } Discord_String;
typedef struct { Discord_RelationshipHandle* ptr; size_t size; } Discord_RelationshipHandleSpan;

typedef void (*cardtable_FreeFn)(void* userData);
typedef void (*cardtable_ResultCb)(Discord_ClientResult* result, void* userData);
typedef void (*cardtable_StatusCb)(int32_t status, int32_t error, int32_t errorDetail, void* userData);
typedef void (*cardtable_JoinCb)(Discord_String* joinSecret, void* userData);
typedef void (*cardtable_AuthorizeCb)(Discord_ClientResult* result, Discord_String* code, Discord_String* redirectUri, void* userData);
typedef void (*cardtable_TokenCb)(Discord_ClientResult* result, Discord_String* accessToken, Discord_String* refreshToken,
  int32_t tokenType, int32_t expiresIn, Discord_String* scopes, void* userData);

void Discord_Client_Init(Discord_Client* self);
void Discord_Client_Drop(Discord_Client* self);
void Discord_Client_SetApplicationId(Discord_Client* self, uint64_t applicationId);
void Discord_RunCallbacks(void);

void Discord_Activity_Init(Discord_Activity* self);
void Discord_Activity_Drop(Discord_Activity* self);
void Discord_Activity_SetType(Discord_Activity* self, int32_t value);
void Discord_Activity_SetState(Discord_Activity* self, Discord_String* value);
void Discord_Activity_SetDetails(Discord_Activity* self, Discord_String* value);
void Discord_Activity_SetParty(Discord_Activity* self, Discord_ActivityParty* value);
void Discord_Activity_SetSecrets(Discord_Activity* self, Discord_ActivitySecrets* value);
void Discord_Activity_SetSupportedPlatforms(Discord_Activity* self, int32_t value);
void Discord_Client_UpdateRichPresence(Discord_Client* self, Discord_Activity* activity, cardtable_ResultCb cb, cardtable_FreeFn free, void* userData);
void Discord_Client_ClearRichPresence(Discord_Client* self);

void Discord_ActivityParty_Init(Discord_ActivityParty* self);
void Discord_ActivityParty_Drop(Discord_ActivityParty* self);
void Discord_ActivityParty_SetId(Discord_ActivityParty* self, Discord_String value);
void Discord_ActivityParty_SetCurrentSize(Discord_ActivityParty* self, int32_t value);
void Discord_ActivityParty_SetMaxSize(Discord_ActivityParty* self, int32_t value);
void Discord_ActivityParty_SetPrivacy(Discord_ActivityParty* self, int32_t value);
void Discord_ActivitySecrets_Init(Discord_ActivitySecrets* self);
void Discord_ActivitySecrets_Drop(Discord_ActivitySecrets* self);
void Discord_ActivitySecrets_SetJoin(Discord_ActivitySecrets* self, Discord_String value);

void Discord_Client_GetDefaultPresenceScopes(Discord_String* returnValue);
void Discord_Client_GetDefaultCommunicationScopes(Discord_String* returnValue);
void Discord_Client_CreateAuthorizationCodeVerifier(Discord_Client* self, Discord_AuthorizationCodeVerifier* returnValue);
void Discord_AuthorizationCodeVerifier_Verifier(Discord_AuthorizationCodeVerifier* self, Discord_String* returnValue);
void Discord_AuthorizationCodeVerifier_Challenge(Discord_AuthorizationCodeVerifier* self, Discord_AuthorizationCodeChallenge* returnValue);
void Discord_AuthorizationCodeVerifier_Drop(Discord_AuthorizationCodeVerifier* self);
void Discord_AuthorizationCodeChallenge_Drop(Discord_AuthorizationCodeChallenge* self);
void Discord_AuthorizationArgs_Init(Discord_AuthorizationArgs* self);
void Discord_AuthorizationArgs_Drop(Discord_AuthorizationArgs* self);
void Discord_AuthorizationArgs_SetClientId(Discord_AuthorizationArgs* self, uint64_t value);
void Discord_AuthorizationArgs_SetScopes(Discord_AuthorizationArgs* self, Discord_String value);
void Discord_AuthorizationArgs_SetCodeChallenge(Discord_AuthorizationArgs* self, Discord_AuthorizationCodeChallenge* value);
void Discord_Client_Authorize(Discord_Client* self, Discord_AuthorizationArgs* args, cardtable_AuthorizeCb cb, cardtable_FreeFn free, void* userData);
void Discord_Client_GetToken(Discord_Client* self, uint64_t applicationId, Discord_String code, Discord_String codeVerifier,
  Discord_String redirectUri, cardtable_TokenCb cb, cardtable_FreeFn free, void* userData);
void Discord_Client_RefreshToken(Discord_Client* self, uint64_t applicationId, Discord_String refreshToken,
  cardtable_TokenCb cb, cardtable_FreeFn free, void* userData);
void Discord_Client_UpdateToken(Discord_Client* self, int32_t tokenType, Discord_String token, cardtable_ResultCb cb, cardtable_FreeFn free, void* userData);
void Discord_Client_Connect(Discord_Client* self);
int32_t Discord_Client_GetStatus(Discord_Client* self);
void Discord_Client_SetStatusChangedCallback(Discord_Client* self, cardtable_StatusCb cb, cardtable_FreeFn free, void* userData);

void Discord_Client_GetRelationships(Discord_Client* self, Discord_RelationshipHandleSpan* returnValue);
int32_t Discord_RelationshipHandle_DiscordRelationshipType(Discord_RelationshipHandle* self);
bool Discord_RelationshipHandle_User(Discord_RelationshipHandle* self, Discord_UserHandle* returnValue);
uint64_t Discord_UserHandle_Id(Discord_UserHandle* self);
void Discord_UserHandle_Username(Discord_UserHandle* self, Discord_String* returnValue);
void Discord_UserHandle_DisplayName(Discord_UserHandle* self, Discord_String* returnValue);
int32_t Discord_UserHandle_Status(Discord_UserHandle* self);
void Discord_UserHandle_Drop(Discord_UserHandle* self);

bool Discord_Client_RegisterLaunchCommand(Discord_Client* self, uint64_t applicationId, Discord_String command);
void Discord_Client_SendActivityInvite(Discord_Client* self, uint64_t userId, Discord_String content, cardtable_ResultCb cb, cardtable_FreeFn free, void* userData);
void Discord_Client_SetActivityJoinCallback(Discord_Client* self, cardtable_JoinCb cb, cardtable_FreeFn free, void* userData);

bool Discord_ClientResult_Successful(Discord_ClientResult* self);
void Discord_ClientResult_Error(Discord_ClientResult* self, Discord_String* returnValue);
int32_t Discord_ClientResult_ErrorCode(Discord_ClientResult* self);
]]

local lib, client
local enabled = false
D.status = -1

local function log(...) print("Discord:", ...) end

---------------------------------------------------------------------------
-- Strings
---------------------------------------------------------------------------

-- A Discord_String over a copy of `s`. Returns the struct and the buffer,
-- which the caller keeps referenced until the SDK call returns.
local function dstr(s)
  s = s or ""
  local buf = ffi.new("uint8_t[?]", #s + 1)
  ffi.copy(buf, s, #s)
  local str = ffi.new("Discord_String")
  str.ptr, str.size = buf, #s
  return str, buf
end

-- SDK-written out-strings are deliberately not freed: ownership isn't
-- documented and a wrong free crashes, while a leak here is tiny.
local function readStr(str)
  if str == nil or str.ptr == nil or str.size == 0 then return "" end
  return ffi.string(str.ptr, str.size)
end

---------------------------------------------------------------------------
-- Callback plumbing: one persistent C callback per signature, routed by an
-- integer id carried in userData.
---------------------------------------------------------------------------

local nextId = 1
local pending = {}  -- id -> { deadline, handler(payloadOrNil) }
local events = {}   -- { id, payload } recorded during RunCallbacks
local statusWaiters = {}
D.statusListeners = {}
D.onJoinSecret = nil -- function(secret), set by the app

local function newRequest(timeout, handler)
  local id = nextId
  nextId = nextId + 1
  pending[id] = { deadline = love.timer.getTime() + timeout, handler = handler }
  return id, ffi.cast("void*", id)
end

local function idOf(ud) return tonumber(ffi.cast("intptr_t", ud)) end

local function resultOk(label, result)
  if lib.Discord_ClientResult_Successful(result) then return true end
  local err = ffi.new("Discord_String[1]")
  lib.Discord_ClientResult_Error(result, err)
  log(label .. " failed (code=" .. tostring(lib.Discord_ClientResult_ErrorCode(result)) .. ', error="' .. readStr(err[0]) .. '")')
  return false
end

local cbs = {}

local function makeCallbacks()
  cbs.free = ffi.cast("cardtable_FreeFn", function() end)
  -- Also passed (with userData 0) where the result doesn't matter: the SDK
  -- invokes the callback without a null check, so it can't be NULL.
  cbs.result = ffi.cast("cardtable_ResultCb", function(result, ud)
    local id = idOf(ud)
    if id ~= 0 and pending[id] then
      events[#events + 1] = { id, { ok = resultOk(pending[id].label or "request", result) } }
    end
  end)
  cbs.status = ffi.cast("cardtable_StatusCb", function(status, err, detail)
    log("status -> " .. status .. " (error=" .. err .. ", detail=" .. detail .. ")")
    events[#events + 1] = { "status", status }
  end)
  cbs.join = ffi.cast("cardtable_JoinCb", function(secret)
    events[#events + 1] = { "join", readStr(secret[0]) }
  end)
  cbs.authorize = ffi.cast("cardtable_AuthorizeCb", function(result, code, redirect, ud)
    local id = idOf(ud)
    if pending[id] then
      local ok = resultOk("Authorize", result)
      events[#events + 1] = { id, ok and { code = readStr(code[0]), redirectUri = readStr(redirect[0]) } or false }
    end
  end)
  cbs.token = ffi.cast("cardtable_TokenCb", function(result, access, refresh, _, _, _, ud)
    local id = idOf(ud)
    if pending[id] then
      local ok = resultOk(pending[id].label or "token", result)
      events[#events + 1] = { id, ok and { accessToken = readStr(access[0]), refreshToken = readStr(refresh[0]) } or false }
    end
  end)
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

local function findDll()
  local okFused, fused = pcall(love.filesystem.isFused)
  local okDir, dir = pcall(okFused and fused and love.filesystem.getSourceBaseDirectory or love.filesystem.getSource)
  local candidates = {}
  if okDir and dir then candidates[1] = fs.join(fs.normalize(dir), "discord_partner_sdk.dll") end
  candidates[#candidates + 1] = "discord_partner_sdk"
  for _, c in ipairs(candidates) do
    local ok, l = pcall(ffi.load, c)
    if ok then return l end
  end
  return nil
end

function D.isEnabled() return enabled end
function D.isReady() return D.status == D.statusReady end

-- Loads the SDK and starts publishing presence. Never throws.
function D.init()
  if enabled or ffi.os ~= "Windows" or not ffi.abi("64bit") then return end
  local ok, err = pcall(function()
    pcall(ffi.cdef, CDEF)
    lib = findDll()
    if not lib then error("discord_partner_sdk.dll not found") end
    client = ffi.new("Discord_Client[1]")
    lib.Discord_Client_Init(client)
    lib.Discord_Client_SetApplicationId(client, APPLICATION_ID)
    makeCallbacks()
  end)
  if not ok then
    log("init failed, disabling (" .. tostring(err) .. ")")
    return
  end
  enabled = true
  D.pumpTimer = 0
  -- Launch registration and the join callback are live from startup: this
  -- user may be the one being invited.
  pcall(function()
    local cmd, _keep = dstr("")
    log("RegisterLaunchCommand -> " .. tostring(lib.Discord_Client_RegisterLaunchCommand(client, APPLICATION_ID, cmd)))
  end)
  pcall(lib.Discord_Client_SetStatusChangedCallback, client, cbs.status, cbs.free, nil)
  pcall(lib.Discord_Client_SetActivityJoinCallback, client, cbs.join, cbs.free, nil)
  D.setIdle()
end

local current, lastKey = nil, nil

local function republishAfterConnect()
  -- Presence set before Connect() is cleared once Connect succeeds.
  lastKey = nil
  if current then D.publish(current.details, current.state, current.party) end
end

local function dispatch(ev)
  local tag, payload = ev[1], ev[2]
  if tag == "status" then
    D.status = payload
    if payload == D.statusReady then republishAfterConnect() end
    for i = #statusWaiters, 1, -1 do
      if statusWaiters[i].status == payload then
        local w = table.remove(statusWaiters, i)
        w.handler(true)
      end
    end
    for _, l in ipairs(D.statusListeners) do l(payload) end
  elseif tag == "join" then
    log("activity join received (" .. payload .. ")")
    if payload ~= "" and D.onJoinSecret then D.onJoinSecret(payload) end
  else
    local p = pending[tag]
    if p then
      pending[tag] = nil
      p.handler(payload or nil)
    end
  end
end

local function pump()
  local ok, err = pcall(lib.Discord_RunCallbacks)
  if not ok then log("RunCallbacks failed (" .. tostring(err) .. ")") end
  local evs = events
  events = {}
  for _, ev in ipairs(evs) do
    local ok2, err2 = pcall(dispatch, ev)
    if not ok2 then log("callback handler failed (" .. tostring(err2) .. ")") end
  end
end

function D.update(dt)
  if not enabled then return end
  D.pumpTimer = D.pumpTimer + (dt or 0)
  if D.pumpTimer >= PUMP_INTERVAL then
    D.pumpTimer = 0
    pump()
  end
  local now = love.timer.getTime()
  for id, p in pairs(pending) do
    if now > p.deadline then
      pending[id] = nil
      if p.label then log(p.label .. " timed out") end
      p.handler(nil)
    end
  end
  for i = #statusWaiters, 1, -1 do
    local w = statusWaiters[i]
    if now > w.deadline then
      table.remove(statusWaiters, i)
      log("never reached status " .. w.status)
      w.handler(false)
    end
  end
end

-- Clears presence and drops the client (best effort; Discord clears
-- presence on its own when the process goes away).
function D.dispose()
  if not enabled then return end
  enabled = false
  pcall(lib.Discord_Client_ClearRichPresence, client)
  pcall(lib.Discord_Client_Drop, client)
end

---------------------------------------------------------------------------
-- Rich Presence
---------------------------------------------------------------------------

-- party (hosting only): { partyId, currentSize, maxSize, joinSecret }.
function D.publish(details, state, party)
  if not enabled then return end
  current = { details = details, state = state, party = party }
  local key = details .. "\0" .. tostring(state) .. "\0" .. (party
    and (party.partyId .. ":" .. party.currentSize .. ":" .. party.maxSize .. ":" .. party.joinSecret) or "")
  if key == lastKey then return end
  local ok, err = pcall(function()
    local activity = ffi.new("Discord_Activity[1]")
    lib.Discord_Activity_Init(activity)
    lib.Discord_Activity_SetType(activity, ACTIVITY_PLAYING)
    local det, _k1 = dstr(details)
    lib.Discord_Activity_SetDetails(activity, det)
    local st, _k2
    if state then
      st, _k2 = dstr(state)
      lib.Discord_Activity_SetState(activity, st)
    end
    local partyH, secrets
    if party then
      partyH = ffi.new("Discord_ActivityParty[1]")
      lib.Discord_ActivityParty_Init(partyH)
      local pid, _k3 = dstr(party.partyId)
      lib.Discord_ActivityParty_SetId(partyH, pid)
      lib.Discord_ActivityParty_SetCurrentSize(partyH, party.currentSize)
      lib.Discord_ActivityParty_SetMaxSize(partyH, party.maxSize)
      lib.Discord_ActivityParty_SetPrivacy(partyH, PARTY_PRIVATE)
      lib.Discord_Activity_SetParty(activity, partyH)
      secrets = ffi.new("Discord_ActivitySecrets[1]")
      lib.Discord_ActivitySecrets_Init(secrets)
      local js, _k4 = dstr(party.joinSecret)
      lib.Discord_ActivitySecrets_SetJoin(secrets, js)
      lib.Discord_Activity_SetSecrets(activity, secrets)
      -- Without this Discord shows the Join button disabled ("game not detected").
      lib.Discord_Activity_SetSupportedPlatforms(activity, PLATFORM_DESKTOP)
    end
    lib.Discord_Client_UpdateRichPresence(client, activity, cbs.result, cbs.free, nil)
    lib.Discord_Activity_Drop(activity)
    if partyH then lib.Discord_ActivityParty_Drop(partyH) end
    if secrets then lib.Discord_ActivitySecrets_Drop(secrets) end
  end)
  if ok then lastKey = key else log("failed to publish presence (" .. tostring(err) .. ")") end
end

-- "Playing <gameName>" / "<n>[/<max>] players".
function D.setPlaying(gameName, playerCount, maxPlayers, party)
  local state = maxPlayers and (playerCount .. "/" .. maxPlayers .. " players") or (playerCount .. " players")
  D.publish("Playing " .. gameName, state, party)
end

function D.setIdle() D.publish("In the menus", nil, nil) end

---------------------------------------------------------------------------
-- OAuth + connect
---------------------------------------------------------------------------

local function updateToken(accessToken, onDone)
  local id, ud = newRequest(10, function(r) onDone(r ~= nil and r.ok) end)
  pending[id].label = "UpdateToken"
  local tok, _keep = dstr(accessToken)
  lib.Discord_Client_UpdateToken(client, TOKEN_BEARER, tok, cbs.result, cbs.free, ud)
end

local function connectAndAwaitReady(onDone)
  if D.isReady() then return onDone(true) end
  statusWaiters[#statusWaiters + 1] = { status = D.statusReady, deadline = love.timer.getTime() + READY_TIMEOUT, handler = onDone }
  lib.Discord_Client_Connect(client)
end

local function refreshToken(token, onDone)
  local id, ud = newRequest(10, function(r)
    if not r then return onDone(false) end
    log("RefreshToken succeeded, saving new refresh token")
    settings.set(settings.keys.discordRefreshToken, r.refreshToken)
    updateToken(r.accessToken, onDone)
  end)
  pending[id].label = "RefreshToken"
  local s, _keep = dstr(token)
  lib.Discord_Client_RefreshToken(client, APPLICATION_ID, s, cbs.token, cbs.free, ud)
end

local function authorizeFromScratch(onDone)
  local verifier = ffi.new("Discord_AuthorizationCodeVerifier[1]")
  local challenge = ffi.new("Discord_AuthorizationCodeChallenge[1]")
  local args = ffi.new("Discord_AuthorizationArgs[1]")
  local function cleanup()
    pcall(lib.Discord_AuthorizationArgs_Drop, args)
    pcall(lib.Discord_AuthorizationCodeChallenge_Drop, challenge)
    pcall(lib.Discord_AuthorizationCodeVerifier_Drop, verifier)
  end
  lib.Discord_Client_CreateAuthorizationCodeVerifier(client, verifier)
  lib.Discord_AuthorizationCodeVerifier_Challenge(verifier, challenge)
  local out = ffi.new("Discord_String[1]")
  lib.Discord_AuthorizationCodeVerifier_Verifier(verifier, out)
  local codeVerifier = readStr(out[0])
  local p, c = ffi.new("Discord_String[1]"), ffi.new("Discord_String[1]")
  lib.Discord_Client_GetDefaultPresenceScopes(p)
  lib.Discord_Client_GetDefaultCommunicationScopes(c)
  local scopes = (readStr(p[0]) .. " " .. readStr(c[0])):gsub("^%s+", ""):gsub("%s+$", "")
  lib.Discord_AuthorizationArgs_Init(args)
  lib.Discord_AuthorizationArgs_SetClientId(args, APPLICATION_ID)
  local sc, _keep = dstr(scopes)
  lib.Discord_AuthorizationArgs_SetScopes(args, sc)
  lib.Discord_AuthorizationArgs_SetCodeChallenge(args, challenge)

  -- The user needs time on the consent screen.
  local id, ud = newRequest(300, function(auth)
    if not auth then
      cleanup()
      return onDone(false)
    end
    local tid, tud = newRequest(15, function(tok)
      cleanup()
      if not tok then return onDone(false) end
      log("GetToken succeeded, saving refresh token")
      settings.set(settings.keys.discordRefreshToken, tok.refreshToken)
      updateToken(tok.accessToken, onDone)
    end)
    pending[tid].label = "GetToken"
    local a, _k1 = dstr(auth.code)
    local b, _k2 = dstr(codeVerifier)
    local r, _k3 = dstr(auth.redirectUri)
    lib.Discord_Client_GetToken(client, APPLICATION_ID, a, b, r, cbs.token, cbs.free, tud)
  end)
  pending[id].label = "Authorize"
  lib.Discord_Client_Authorize(client, args, cbs.authorize, cbs.free, ud)
end

-- Lazy OAuth entry point (first time the host opens Invite mode): a saved
-- refresh token first (no consent screen), else a full Authorize.
-- onDone(ok) runs on the main thread; never throws.
function D.ensureAuthorizedAndConnected(onDone)
  if not enabled then return onDone(false) end
  if D.isReady() then return onDone(true) end
  local function guarded(fn)
    local ok, err = pcall(fn)
    if not ok then
      log("ensureAuthorizedAndConnected failed (" .. tostring(err) .. ")")
      onDone(false)
    end
  end
  local function afterToken(ok)
    if not ok then return onDone(false) end
    guarded(function() connectAndAwaitReady(onDone) end)
  end
  local saved = settings.get(settings.keys.discordRefreshToken)
  if type(saved) == "string" and saved ~= "" then
    guarded(function()
      refreshToken(saved, function(ok)
        if ok then return afterToken(true) end
        settings.remove(settings.keys.discordRefreshToken)
        guarded(function() authorizeFromScratch(afterToken) end)
      end)
    end)
  else
    guarded(function() authorizeFromScratch(afterToken) end)
  end
end

---------------------------------------------------------------------------
-- Friends + invites
---------------------------------------------------------------------------

-- Every real friend, whatever their status (an Invisible friend reads as
-- Offline, so filtering would hide reachable people). Entries:
-- { userId (uint64 cdata), username, displayName, status }.
function D.fetchInvitableFriends()
  if not enabled or not D.isReady() then return {} end
  local friends = {}
  local ok, err = pcall(function()
    local span = ffi.new("Discord_RelationshipHandleSpan[1]")
    lib.Discord_Client_GetRelationships(client, span)
    for i = 0, tonumber(span[0].size) - 1 do
      local rel = span[0].ptr + i
      if lib.Discord_RelationshipHandle_DiscordRelationshipType(rel) == RELATIONSHIP_FRIEND then
        local user = ffi.new("Discord_UserHandle[1]")
        if lib.Discord_RelationshipHandle_User(rel, user) then
          local u, dn = ffi.new("Discord_String[1]"), ffi.new("Discord_String[1]")
          lib.Discord_UserHandle_Username(user, u)
          lib.Discord_UserHandle_DisplayName(user, dn)
          local username, displayName = readStr(u[0]), readStr(dn[0])
          friends[#friends + 1] = {
            userId = lib.Discord_UserHandle_Id(user),
            username = username,
            displayName = displayName ~= "" and displayName or username,
            status = lib.Discord_UserHandle_Status(user),
          }
          lib.Discord_UserHandle_Drop(user)
        end
      end
    end
  end)
  if not ok then
    log("fetchInvitableFriends failed (" .. tostring(err) .. ")")
    return {}
  end
  return friends
end

-- Sends an activity invite carrying the host's current presence (whose
-- join secret is "ip:port"). onDone(sent) once Discord acknowledges.
function D.sendGameInvite(friendUserId, onDone)
  if not enabled or not D.isReady() then return onDone(false) end
  local id, ud = newRequest(10, function(r) onDone(r ~= nil and r.ok) end)
  pending[id].label = "SendActivityInvite"
  local ok, err = pcall(function()
    local content, _keep = dstr("Join my Cardflux game!")
    lib.Discord_Client_SendActivityInvite(client, friendUserId, content, cbs.result, cbs.free, ud)
  end)
  if not ok then
    log("sendGameInvite failed (" .. tostring(err) .. ")")
    pending[id] = nil
    onDone(false)
  end
end

-- "host:port" -> host, port (nil when malformed).
function D.parseJoinSecret(secret)
  local host, port = tostring(secret):match("^([^:]+):(%d+)$")
  if not host then return nil end
  return host, tonumber(port)
end

-- A C function that re-enters Lua through a callback must not be called
-- from a JIT-compiled trace; keep every SDK-calling function interpreted.
for _, fn in pairs(D) do
  if type(fn) == "function" then jit.off(fn, true) end
end
for _, fn in ipairs({ pump, updateToken, connectAndAwaitReady, refreshToken, authorizeFromScratch, dispatch }) do
  jit.off(fn, true)
end

return D
