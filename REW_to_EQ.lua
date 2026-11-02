--[[
  REW -> Reaper EQ  (ReaEQ / FabFilter Pro-Q 3 / FabFilter Pro-Q 4)
  ------------------------------------------------------------------
  Copyright (c) 2026 Guillaume Couturier - MIT License (see LICENSE)

  Pulls the EQ filters of a REW measurement through REW's local HTTP API
  and writes them into an EQ plugin instance in Reaper.

  REQUIREMENTS
    * REW 5.40+ with the API running (Preferences > API > Start, or launch REW with -api).
    * In REW, set the measurement's Equaliser to "Generic" (or "Equalizer APO")
      so filters are plain PK / shelf / HP / LP types.
    * curl (built into macOS and Windows 10/11). Nothing else to install.

  INSTALL
    Actions > Show action list > New action > Load ReaScript... > pick this file.
    Assign a shortcut or toolbar button if you like.

  WINDOW (all choices remembered between runs)
    Track             : selected track, master, or any track from the list
                        (stored by name when unique, so reordering tracks doesn't break it).
    EQ plugin         : first ReaEQ / Pro-Q on the track, any FX from the track's chain,
                        or "Type a name..." (part of the FX name; rename instances in the
                        FX chain, e.g. "EQ Left", to target them reliably).
    If no EQ found    : don't insert, or insert ReaEQ / Pro-Q 3 / Pro-Q 4.
    REW measurement   : the one selected in REW, or pick one from REW's list.
    REW address       : IP and port of the computer running REW. Default 127.0.0.1 (this
                        computer) : 4735. For REW on another computer, see "REW ON ANOTHER
                        COMPUTER" below.
    Disable unused bands : switch off EQ bands not used by the REW filters.
    Dry run           : only list in the console what REW returned and what would be done.
    Apply (or Enter) writes the filters; the window stays open so you can re-apply
    after changing the EQ in REW. Close (or Esc) closes it.

  REW ON ANOTHER COMPUTER
    Start REW with:  -api -host 0.0.0.0   (by default REW's API only answers its own computer),
    allow incoming TCP 4735 in that computer's firewall, and enter its IP in "REW address".
    REW's API has no password: anyone on that network can then control REW.

  ONE-CLICK VARIANTS
    Copy this file, set ASK_EACH_TIME = false and fill PRESET below, e.g. one copy per speaker.
--]]

-------------------------------------------------------------------------------
-- User settings
-------------------------------------------------------------------------------
local ASK_EACH_TIME = true   -- false = no window, run straight away with PRESET below

local PRESET = {           -- used when ASK_EACH_TIME = false (and as first-run defaults)
  track       = "",        -- "" = selected track
  fx          = "",        -- "" = first EQ found
  insert      = "no",      -- no | ReaEQ | ProQ3 | ProQ4
  measurement = "",        -- "" = selected in REW
  clear       = "y",
  dryrun      = "n",
  host        = "127.0.0.1", -- IP of the computer running REW (127.0.0.1 = this computer)
  port        = "4735",
}

local REW_HOST = "127.0.0.1"
local CURL_TIMEOUT_S = 5

-- Q conventions
-- REW's API returns Q in RBJ convention (bandwidth between half-gain points = fc / Q),
-- whatever Q format is shown in REW's EQ window.
-- FabFilter Pro-Q scales Q by sqrt(2) relative to RBJ (Butterworth = 1.0 in Pro-Q, not 0.707).
-- Verified by measurement against REW's predicted response.
local PROQ_Q_SCALE = math.sqrt(2)

-------------------------------------------------------------------------------
-- Small utilities
-------------------------------------------------------------------------------
local LOG = {}
local function log(fmt, ...) LOG[#LOG + 1] = string.format(fmt, ...) end
local WARN = {}
local function warn(fmt, ...) WARN[#WARN + 1] = string.format(fmt, ...) end

local function trim(s) return (s or ""):match("^%s*(.-)%s*$") end
local function yes(s) s = trim(s):lower(); return s == "y" or s == "yes" or s == "1" or s == "true" end

-------------------------------------------------------------------------------
-- Minimal JSON decoder (no dependency)
-------------------------------------------------------------------------------
local function json_decode(str)
  local pos = 1
  local function err(msg) error(("JSON error at char %d: %s"):format(pos, msg), 0) end
  local function skip() pos = str:find("[^ \t\r\n]", pos) or (#str + 1) end
  local parse_value

  local esc = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
  local function parse_string()
    pos = pos + 1
    local out = {}
    while true do
      local s = str:find('["\\]', pos)
      if not s then err("unterminated string") end
      out[#out + 1] = str:sub(pos, s - 1)
      if str:sub(s, s) == '"' then pos = s + 1; break end
      local e = str:sub(s + 1, s + 1)
      if esc[e] then out[#out + 1] = esc[e]; pos = s + 2
      elseif e == "u" then
        local cp = tonumber(str:sub(s + 2, s + 5), 16) or 63
        out[#out + 1] = (utf8 and utf8.char(cp)) or (cp < 128 and string.char(cp) or "?")
        pos = s + 6
      else err("bad escape") end
    end
    return table.concat(out)
  end

  local function parse_number()
    local s, e = str:find("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
    if not s then err("bad number") end
    local v = tonumber(str:sub(s, e)); pos = e + 1
    return v
  end

  function parse_value()
    skip()
    local c = str:sub(pos, pos)
    if c == "{" then
      pos = pos + 1; local obj = {}
      skip()
      if str:sub(pos, pos) == "}" then pos = pos + 1; return obj end
      while true do
        skip()
        if str:sub(pos, pos) ~= '"' then err("expected key") end
        local k = parse_string(); skip()
        if str:sub(pos, pos) ~= ":" then err("expected ':'") end
        pos = pos + 1
        obj[k] = parse_value(); skip()
        local d = str:sub(pos, pos); pos = pos + 1
        if d == "}" then return obj elseif d ~= "," then err("expected ',' or '}'") end
      end
    elseif c == "[" then
      pos = pos + 1; local arr = {}
      skip()
      if str:sub(pos, pos) == "]" then pos = pos + 1; return arr end
      while true do
        arr[#arr + 1] = parse_value(); skip()
        local d = str:sub(pos, pos); pos = pos + 1
        if d == "]" then return arr elseif d ~= "," then err("expected ',' or ']'") end
      end
    elseif c == '"' then return parse_string()
    elseif str:sub(pos, pos + 3) == "true" then pos = pos + 4; return true
    elseif str:sub(pos, pos + 4) == "false" then pos = pos + 5; return false
    elseif str:sub(pos, pos + 3) == "null" then pos = pos + 4; return nil
    else return parse_number() end
  end

  local ok, res = pcall(parse_value)
  if not ok then return nil, res end
  return res
end

-------------------------------------------------------------------------------
-- REW API access (via curl)
-------------------------------------------------------------------------------
local IS_WIN = reaper.GetOS():find("Win") ~= nil
local CURL = IS_WIN and "curl" or "/usr/bin/curl"
local PORT = "4735"

local function http_get(path)
  local url = ("http://%s:%s%s"):format(REW_HOST, PORT, path)
  local cmd = ('%s -s -f -m %d "%s"'):format(CURL, CURL_TIMEOUT_S, url)
  local out = reaper.ExecProcess(cmd, (CURL_TIMEOUT_S + 2) * 1000)
  if not out then return nil, "could not run curl", -1 end
  local code, body = out:match("^(%-?%d+)\r?\n(.*)$")
  code = tonumber(code)
  if code ~= 0 then return nil, ("curl exit code %s for %s"):format(tostring(code), url), code end
  return body
end

local function get_json(path)
  local body, e, code = http_get(path)
  if not body then return nil, e, code end
  local t = trim(body)
  if t == "" then return nil, "empty response from " .. path end
  local first = t:sub(1, 1)
  if first ~= "{" and first ~= "[" and first ~= '"' and not t:match("^[-%d]") then
    return t -- plain text (e.g. a bare UUID)
  end
  local v, je = json_decode(t)
  if v == nil and je then return nil, je .. " in " .. path end
  return v
end

local function measurement_label(m)
  if type(m) ~= "table" then return tostring(m) end
  return tostring(m.title or m.name or m.uuid or "?")
end

-- Check REW before doing anything else, so each problem gets its own message.
-- Returns "ok", list | "unreachable" | "error", msg | "empty"
-- curl exit 22 = REW answered with an HTTP error; any other non-zero code = no connection.
local function rew_status()
  local list, e, code = get_json("/measurements")
  if list == nil then
    if code == 22 then return "error", e end
    return "unreachable", e
  end
  if type(list) ~= "table" or next(list) == nil then return "empty" end
  return "ok", list
end

local function rew_unreachable_msg()
  local remote = REW_HOST ~= "127.0.0.1" and REW_HOST ~= "localhost"
  local t = { ("REW's API is not reachable at %s:%s."):format(REW_HOST, PORT), "",
    "Make sure REW is running with its API started:",
    "  - REW: Preferences > API > Start (or launch REW with -api)" }
  if remote then
    t[#t + 1] = "  - REW is on another computer: launch it with  -api -host 0.0.0.0"
    t[#t + 1] = "    (macOS: open -a REW.app --args -api -host 0.0.0.0)"
    t[#t + 1] = ("  - allow incoming TCP connections on port %s in that computer's firewall"):format(PORT)
  end
  t[#t + 1] = "  - check the REW address and port in this script's window"
  return table.concat(t, "\n")
end

local REW_EMPTY_MSG = "REW is running, but it has no measurements.\n\n" ..
  "Make a measurement or load an .mdat file in REW, set up its EQ filters in REW's EQ window, then apply again."

local function resolve_measurement(spec)
  -- Explicit index from the user
  if spec ~= "" then
    local m = get_json("/measurements/" .. spec)
    if type(m) == "table" then return (m.uuid or spec), measurement_label(m) end
    return spec, "#" .. spec
  end
  -- Selected measurement in REW
  for _, p in ipairs({ "/measurements/selected-uuid", "/measurements/selected" }) do
    local v = get_json(p)
    if type(v) == "string" and v ~= "" then
      local m = get_json("/measurements/" .. v)
      return v, (type(m) == "table" and measurement_label(m)) or v
    elseif type(v) == "table" and v.uuid then
      return v.uuid, measurement_label(v)
    end
  end
  -- Fallback: only one measurement loaded
  local list, e = get_json("/measurements")
  if type(list) ~= "table" then return nil, e or "cannot list measurements" end
  local keys, names = {}, {}
  for k, m in pairs(list) do keys[#keys + 1] = k; names[#names + 1] = ("  %s: %s"):format(k, measurement_label(m)) end
  if #keys == 1 then
    local m = list[keys[1]]
    return (type(m) == "table" and m.uuid) or keys[1], measurement_label(m)
  end
  table.sort(names)
  return nil, "Could not read REW's selected measurement. Enter a measurement index:\n" .. table.concat(names, "\n")
end

local function fetch_filters(mid)
  local tries = { "/measurements/%s/filters", "/measurements/%s/eq/filters" }
  local lastErr
  for _, t in ipairs(tries) do
    local v, e = get_json(t:format(mid))
    if type(v) == "table" then
      if v.filters then v = v.filters end
      return v
    end
    lastErr = e
  end
  return nil, lastErr
end

-------------------------------------------------------------------------------
-- Normalise REW filters into a neutral description
--   kind: bell | lowshelf | highshelf | highpass | lowpass | notch | bandpass | allpass
--   order: 1 or 2 (for shelves / cuts)
-------------------------------------------------------------------------------
local BUTTERWORTH_Q = 0.7071

local function field(f, ...)
  for _, k in ipairs({ ... }) do if f[k] ~= nil then return f[k] end end
  return nil
end

local function classify(t)
  local s = (t or ""):upper()
  local has = function(p) return s:find(p, 1, true) ~= nil end
  -- Q-adjustable variants: any "Q" in the name ("HPQ", "HP Q", "High pass Q", "HP (Q)"...)
  local qvar = s:gsub("[^%w]", ""):find("Q", 2, true) ~= nil
  if s == "" or s == "NONE" or s == "OFF" then return nil end
  if s == "PK" or has("PEAK") or has("MODAL") or has("BELL") or has("PARAMETRIC") then return { kind = "bell" } end
  if s:match("^LS") or has("LOW SHELF") or has("LOWSHELF") then
    if has("6") then return { kind = "lowshelf", order = 1, corner = true } end
    if has("12") then return { kind = "lowshelf", order = 2, corner = true } end
    if qvar or s:match("^LSC") then return { kind = "lowshelf", order = 2, useQ = true } end
    return { kind = "lowshelf", order = 2 }
  end
  if s:match("^HS") or has("HIGH SHELF") or has("HIGHSHELF") then
    if has("6") then return { kind = "highshelf", order = 1, corner = true } end
    if has("12") then return { kind = "highshelf", order = 2, corner = true } end
    if qvar or s:match("^HSC") then return { kind = "highshelf", order = 2, useQ = true } end
    return { kind = "highshelf", order = 2 }
  end
  if s:match("^HP") or has("HIGH PASS") or has("HIGHPASS") or has("LOW CUT") then
    if s:match("^HP1") or has("6DB") or has("6 DB") or has("1ST") then return { kind = "highpass", order = 1 } end
    if qvar then return { kind = "highpass", order = 2, useQ = true } end
    return { kind = "highpass", order = 2 }
  end
  if s:match("^LP") or has("LOW PASS") or has("LOWPASS") or has("HIGH CUT") then
    if s:match("^LP1") or has("6DB") or has("6 DB") or has("1ST") then return { kind = "lowpass", order = 1 } end
    if qvar then return { kind = "lowpass", order = 2, useQ = true } end
    return { kind = "lowpass", order = 2 }
  end
  if s == "NO" or has("NOTCH") then return { kind = "notch" } end
  if s == "BP" or has("BAND PASS") or has("BANDPASS") then return { kind = "bandpass" } end
  if s == "AP" or has("ALL PASS") or has("ALLPASS") then return { kind = "allpass" } end
  return { kind = "unknown", raw = t }
end

local function normalise_filters(raw)
  local list = {}
  -- raw may be an array or an object keyed by index
  local items = {}
  if raw[1] ~= nil then items = raw else for _, v in pairs(raw) do items[#items + 1] = v end end
  table.sort(items, function(a, b) return (tonumber(a.index) or 0) < (tonumber(b.index) or 0) end)

  for _, f in ipairs(items) do
    local typ = field(f, "type", "filterType", "Type")
    local enabled = field(f, "enabled", "Enabled")
    local c = classify(typ)
    if c and enabled ~= false then
      c.raw = typ
      c.freq = tonumber(field(f, "frequency", "freq", "fc", "Frequency"))
      c.gain = tonumber(field(f, "gaindB", "gainDB", "gain", "Gain")) or 0
      c.q    = tonumber(field(f, "q", "Q"))
      if c.kind == "unknown" then
        warn("Skipped REW filter type '%s' (not recognised)", tostring(typ))
      elseif not c.freq then
        warn("Skipped REW filter '%s' (no frequency)", tostring(typ))
      else
        if not c.q or c.q <= 0 then c.q = BUTTERWORTH_Q end
        local fixedQ = (c.kind == "highpass" or c.kind == "lowpass" or c.kind == "lowshelf" or c.kind == "highshelf")
                       and not c.useQ and not c.corner
        if fixedQ then
          -- Plain HP/LP/LS/HS are Q 0.7071 in REW. If REW reports a different Q, trust REW
          -- (it may be a Q-adjustable type under a name this script doesn't know).
          if math.abs(c.q - BUTTERWORTH_Q) > 0.01 then
            warn("REW type '%s' at %.1f Hz reports Q %.3f; used that Q (expected 0.707 for a plain %s)",
                 tostring(typ), c.freq, c.q, c.kind)
          else
            c.q = BUTTERWORTH_Q
          end
        end
        list[#list + 1] = c
      end
    end
  end
  return list
end

-------------------------------------------------------------------------------
-- Generic plugin-parameter helpers
-- Values are found from the plugin's own display strings, so the script does
-- not depend on hard-coded normalisation curves.
-------------------------------------------------------------------------------
local function parse_num(s)
  if not s then return nil end
  local l = s:lower()
  if l:find("inf", 1, true) then return l:find("-", 1, true) and -1e9 or 1e9 end
  local a, b = s:find("[-+]?%d*%.?%d+")
  if not a then return nil end
  local v = tonumber(s:sub(a, b))
  if not v then return nil end
  local rest = s:sub(b + 1):lower()
  if rest:match("^%s*k") then v = v * 1000 end
  return v
end

local function fmt_at(tr, fx, p, x)
  local ok, s = reaper.TrackFX_FormatParamValueNormalized(tr, fx, p, x, "")
  if ok and s and s ~= "" then return s end
  -- Plugin cannot format arbitrary values: set, read, restore
  local old = reaper.TrackFX_GetParamNormalized(tr, fx, p)
  reaper.TrackFX_SetParamNormalized(tr, fx, p, x)
  local _, s2 = reaper.TrackFX_GetFormattedParamValue(tr, fx, p, "")
  reaper.TrackFX_SetParamNormalized(tr, fx, p, old)
  return s2
end

-- Find the normalised value that displays as `target`.
local function solve_norm(tr, fx, p, target)
  local val = function(x) return parse_num(fmt_at(tr, fx, p, x)) end
  local v0, v1 = val(0), val(1)
  if not v0 or not v1 or v0 == v1 then return nil end
  local inc = v1 > v0
  local lo, hi = math.min(v0, v1), math.max(v0, v1)
  if target <= lo then return inc and 0 or 1 end
  if target >= hi then return inc and 1 or 0 end

  local tol = math.max(math.abs(target) * 0.006, 0.006)
  -- Try an exact log or linear fit first (full precision, not limited by display rounding)
  local vm = val(0.5)
  if vm then
    local guess
    if v0 > 0 and v1 > 0 and math.abs(vm - math.sqrt(v0 * v1)) <= 0.01 * math.sqrt(v0 * v1) then
      guess = (math.log(target) - math.log(v0)) / (math.log(v1) - math.log(v0))
    elseif math.abs(vm - (v0 + v1) / 2) <= 0.005 * math.abs(v1 - v0) then
      guess = (target - v0) / (v1 - v0)
    end
    if guess then
      local check = val(guess)
      if check and math.abs(check - target) <= tol then return guess end
    end
  end
  -- Bisection on the display value
  local a, b = 0, 1
  for _ = 1, 40 do
    local m = (a + b) / 2
    local vmv = val(m)
    if not vmv then break end
    if (vmv < target) == inc then a = m else b = m end
  end
  -- pick whichever end of the final bracket displays closest to the target
  local va, vb = val(a), val(b)
  if va and vb then return (math.abs(va - target) <= math.abs(vb - target)) and a or b end
  return (a + b) / 2
end

local function set_value(tr, fx, p, target, what)
  local x = solve_norm(tr, fx, p, target)
  if not x then warn("Could not set %s (unreadable parameter range)", what); return false end
  reaper.TrackFX_SetParamNormalized(tr, fx, p, x)
  return true
end

-- Find the normalised position of an enum label (e.g. "Bell", "12 dB/oct").
local function find_enum(tr, fx, p, matcher)
  local first, last
  for i = 0, 400 do
    local x = i / 400
    local s = trim(fmt_at(tr, fx, p, x)):lower()
    if matcher(s) then
      first = first or x; last = x
    elseif first then break end
  end
  if first then return (first + last) / 2 end
end

local function q_to_bw(q) -- octaves
  local v = 1 / (2 * q)
  return (2 / math.log(2)) * math.log(v + math.sqrt(v * v + 1))
end

-------------------------------------------------------------------------------
-- FabFilter Pro-Q 3 / Pro-Q 4
-------------------------------------------------------------------------------
local PROQ_SHAPE = {
  bell      = function(s) return s == "bell" end,
  lowshelf  = function(s) return s == "low shelf" end,
  highshelf = function(s) return s == "high shelf" end,
  highpass  = function(s) return s == "low cut" end,
  lowpass   = function(s) return s == "high cut" end,
  notch     = function(s) return s == "notch" end,
  bandpass  = function(s) return s == "band pass" or s == "bandpass" end,
  allpass   = function(s) return s == "all pass" or s == "allpass" end,
}

local function proq_map(tr, fx)
  local bands = {}
  for p = 0, reaper.TrackFX_GetNumParams(tr, fx) - 1 do
    local _, name = reaper.TrackFX_GetParamName(tr, fx, p, "")
    local b, what = name:match("^Band%s+(%d+)%s+(.+)$")
    if b then
      b = tonumber(b)
      bands[b] = bands[b] or {}
      what = what:lower()
      if what == "freq" then what = "frequency" end
      bands[b][what] = p
    end
  end
  return bands
end

local function apply_proq(tr, fx, filters, clear)
  local bands = proq_map(tr, fx)
  local nb = #bands
  if nb == 0 then return false, "No 'Band N ...' parameters found on this Pro-Q instance." end

  if #filters > nb then
    warn("REW has %d filters but Pro-Q has %d bands; extra filters ignored", #filters, nb)
  end

  local shapeCache, slopeCache = {}, {}
  for i, f in ipairs(filters) do
    if i > nb then break end
    local B = bands[i]
    if not (B.used and B.frequency and B.shape) then
      warn("Pro-Q band %d is missing expected parameters; skipped", i)
    else
      reaper.TrackFX_SetParamNormalized(tr, fx, B.used, 1)
      if B.enabled then reaper.TrackFX_SetParamNormalized(tr, fx, B.enabled, 1) end

      local shapeX = shapeCache[f.kind]
      if shapeX == nil then
        shapeX = find_enum(tr, fx, B.shape, PROQ_SHAPE[f.kind]) or false
        shapeCache[f.kind] = shapeX
      end
      if not shapeX then
        warn("Pro-Q has no '%s' shape; band %d left unused", f.kind, i)
        reaper.TrackFX_SetParamNormalized(tr, fx, B.used, 0)
      else
        reaper.TrackFX_SetParamNormalized(tr, fx, B.shape, shapeX)

        local order = f.order or ((f.kind == "bell") and 2 or nil)
        if B.slope and order then
          local want = (order == 1) and "6" or "12"
          local slopeX = slopeCache[want]
          if slopeX == nil then
            slopeX = find_enum(tr, fx, B.slope, function(s) return s:match("^%s*" .. want .. "%s*db") ~= nil end) or false
            slopeCache[want] = slopeX
          end
          if slopeX then reaper.TrackFX_SetParamNormalized(tr, fx, B.slope, slopeX) end
        end

        set_value(tr, fx, B.frequency, f.freq, ("band %d frequency"):format(i))
        if B.gain and (f.kind == "bell" or f.kind == "lowshelf" or f.kind == "highshelf") then
          set_value(tr, fx, B.gain, f.gain, ("band %d gain"):format(i))
        end
        local pq = f.q * PROQ_Q_SCALE
        if B.q and not (f.order == 1 and (f.kind == "highpass" or f.kind == "lowpass")) then
          set_value(tr, fx, B.q, pq, ("band %d Q"):format(i))
        end
        log("  Band %2d  %-10s %8.1f Hz  %+6.2f dB  RBJ Q %.3f -> Pro-Q Q %.3f",
            i, f.kind, f.freq, f.gain, f.q, pq)
      end
    end
  end

  if clear then
    for i = #filters + 1, nb do
      if bands[i] and bands[i].used then reaper.TrackFX_SetParamNormalized(tr, fx, bands[i].used, 0) end
    end
  end
  return true
end

-------------------------------------------------------------------------------
-- ReaEQ
-- Uses REAPER's EQ API (TrackFX_GetEQParam) to find band parameters and
-- named config params BANDTYPEx / BANDENABLEDx to set band type and state.
-------------------------------------------------------------------------------
local function reaeq_scan(tr, fx)
  local bands = {}
  for p = 0, reaper.TrackFX_GetNumParams(tr, fx) - 1 do
    local ok, bt, _, pt = reaper.TrackFX_GetEQParam(tr, fx, p)
    if ok and bt >= 0 then
      local k = p // 3
      bands[k + 1] = bands[k + 1] or { idx = k, bt = bt }
      if pt == 0 then bands[k + 1].freq = p elseif pt == 1 then bands[k + 1].gain = p elseif pt == 2 then bands[k + 1].q = p end
    end
  end
  return bands
end

local function cfg_get(tr, fx, key)
  local ok, v = reaper.TrackFX_GetNamedConfigParm(tr, fx, key)
  if ok then return v end
end
local function cfg_set(tr, fx, key, v) return reaper.TrackFX_SetNamedConfigParm(tr, fx, key, tostring(v)) end

-- ReaEQ BANDTYPE codes = position in ReaEQ's "Type" menu:
-- 0 Low Shelf, 1 High Shelf, 2 Band (deprecated), 3 Low Pass, 4 High Pass,
-- 5 All Pass, 6 Notch, 7 Band Pass, 8 Band, 9 Band (alt), 10 Parallel Band Pass
local REAEQ_CODE = { lowshelf = 0, highshelf = 1, lowpass = 3, highpass = 4,
                     notch = 6, bandpass = 7, bell = 8 }

-- ReaEQ shelves are exact RBJ shelves (midpoint frequency) whose "BW" is the RBJ
-- shelf slope S with S = 1/BW^2 (measured, max error 0.001 dB).
-- ReaEQ clamps S at 1.2 (BW ~0.913): any lower BW gives the same curve.
-- RBJ: 1/Q^2 = (A + 1/A)(1/S - 1) + 2, A = 10^(gain/40)  =>  BW = sqrt(1/S)
local REAEQ_SHELF_SMAX = 1.2
local function reaeq_shelf_bw(q, gain)
  local A = 10 ^ (gain / 40)
  local invS = (1 / (q * q) - 2) / (A + 1 / A) + 1
  local clamped = invS < 1 / REAEQ_SHELF_SMAX
  if clamped then invS = 1 / REAEQ_SHELF_SMAX end
  return math.sqrt(invS), clamped
end

local function reaeq_q_is_bw(tr, fx, p)
  local _, name = reaper.TrackFX_GetParamName(tr, fx, p, "")
  local _, disp = reaper.TrackFX_GetFormattedParamValue(tr, fx, p, "")
  name, disp = (name or ""):lower(), (disp or ""):lower()
  if disp:find("oct", 1, true) or name:find("bw", 1, true) or name:find("bandwidth", 1, true) then return true end
  if name:match("^q") or name:find(" q", 1, true) then return false end
  return true -- ReaEQ shows bandwidth in octaves by default
end

local function apply_reaeq(tr, fx, filters, clear)
  local usable = {}
  for _, f in ipairs(filters) do
    if f.kind == "allpass" then
      warn("ReaEQ: all-pass filter at %.1f Hz skipped (not supported by this script for ReaEQ)", f.freq)
    elseif (f.kind == "highpass" or f.kind == "lowpass") and f.order == 1 then
      warn("ReaEQ: 1st-order %s at %.1f Hz skipped (ReaEQ HP/LP are 2nd order)", f.kind, f.freq)
    else
      if (f.kind == "lowshelf" or f.kind == "highshelf") and f.order == 1 then
        warn("ReaEQ: 6 dB/oct shelf at %.1f Hz approximated by a 2nd-order shelf (Q 0.5)", f.freq)
        f.q = 0.5
      end
      usable[#usable + 1] = f
    end
  end

  local bands = reaeq_scan(tr, fx)
  if #bands == 0 then return false, "No ReaEQ bands found via REAPER's EQ API." end
  if not cfg_get(tr, fx, "BANDTYPE0") then
    return false, "This REAPER version does not expose ReaEQ band types to scripts (BANDTYPEx). Please update REAPER."
  end

  -- Add bands if needed
  if #usable > #bands then
    for k = #bands, #usable - 1 do cfg_set(tr, fx, "BANDTYPE" .. k, cfg_get(tr, fx, "BANDTYPE0")) end
    bands = reaeq_scan(tr, fx)
    if #usable > #bands then
      return false, ("REW has %d filters but this ReaEQ has %d bands, and the script could not add bands.\n" ..
        "Click 'Add band' in ReaEQ until it has %d bands, then run again."):format(#usable, #bands, #usable)
    end
  end

  local qIsBw = nil

  for i, f in ipairs(usable) do
    local b = bands[i]
    local code = REAEQ_CODE[f.kind]
    if not code then
      warn("ReaEQ: no band type for '%s'; band %d skipped", f.kind, i)
    else
      cfg_set(tr, fx, "BANDTYPE" .. b.idx, code)
      cfg_set(tr, fx, "BANDENABLED" .. b.idx, 1)
      local got = tonumber(cfg_get(tr, fx, "BANDTYPE" .. b.idx))
      if got ~= code then
        warn("ReaEQ band %d: asked for type %d (%s) but ReaEQ reports %s", i, code, f.kind, tostring(got))
      end
      set_value(tr, fx, b.freq, f.freq, ("band %d frequency"):format(i))
      if b.gain and (f.kind == "bell" or f.kind == "lowshelf" or f.kind == "highshelf") then
        set_value(tr, fx, b.gain, f.gain, ("band %d gain"):format(i))
      end
      if b.q then
        if qIsBw == nil then qIsBw = reaeq_q_is_bw(tr, fx, b.q) end
        local v = qIsBw and q_to_bw(f.q) or f.q
        if qIsBw and (f.kind == "lowshelf" or f.kind == "highshelf") then
          local clamped
          v, clamped = reaeq_shelf_bw(f.q, f.gain)
          if clamped then
            warn("ReaEQ band %d: shelf Q %.3f is steeper than ReaEQ's steepest shelf (BW 0.913); " ..
                 "set to BW 0.913, so it will be gentler than REW predicts. Use Pro-Q for this one.", i, f.q)
          end
        end
        set_value(tr, fx, b.q, v, ("band %d bandwidth"):format(i))
        log("  Band %2d  %-10s %8.1f Hz  %+6.2f dB  Q %.3f%s", i, f.kind, f.freq, f.gain, f.q,
            qIsBw and (" (BW %.3f oct)"):format(v) or "")
      end
    end
  end

  if clear then
    for i = #usable + 1, #bands do cfg_set(tr, fx, "BANDENABLED" .. bands[i].idx, 0) end
  end
  return true
end

-------------------------------------------------------------------------------
-- Track / FX targeting
-------------------------------------------------------------------------------
local function fx_kind(name)
  local l = (name or ""):lower()
  if l:find("reaeq", 1, true) then return "reaeq" end
  if l:find("pro%-q%s*4") then return "proq" end
  if l:find("pro%-q%s*3") then return "proq" end
  return nil
end

local function find_track(spec)
  spec = trim(spec)
  if spec == "" then return reaper.GetSelectedTrack(0, 0), "selected track" end
  if spec:lower() == "master" then return reaper.GetMasterTrack(0), "master" end
  local n = tonumber(spec)
  if n then return reaper.GetTrack(0, n - 1), "track " .. n end
  local partial
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    local _, name = reaper.GetTrackName(tr)
    if name:lower() == spec:lower() then return tr, ("track %d '%s'"):format(i + 1, name) end
    if not partial and name:lower():find(spec:lower(), 1, true) then partial = { tr, ("track %d '%s'"):format(i + 1, name) } end
  end
  if partial then return partial[1], partial[2] end
end

local INSERT_NAMES = {
  reaeq = { "ReaEQ (Cockos)", "ReaEQ" },
  proq3 = { "FabFilter Pro-Q 3" },
  proq4 = { "FabFilter Pro-Q 4" },
}

local function find_fx(tr, spec, insert)
  spec = trim(spec)
  local count = reaper.TrackFX_GetCount(tr)
  local n = tonumber(spec)
  if n then
    if n < 1 or n > count then return nil, ("FX slot %d does not exist (track has %d FX)"):format(n, count) end
    return n - 1
  end
  for i = 0, count - 1 do
    local _, name = reaper.TrackFX_GetFXName(tr, i, "")
    if spec == "" then
      if fx_kind(name) then return i end
    elseif name:lower():find(spec:lower(), 1, true) then
      return i
    end
  end
  insert = trim(insert):lower():gsub("[%s%-]", "")
  if INSERT_NAMES[insert] then
    for _, nm in ipairs(INSERT_NAMES[insert]) do
      local idx = reaper.TrackFX_AddByName(tr, nm, false, -1)
      if idx >= 0 then log("Inserted %s in slot %d", nm, idx + 1); return idx end
    end
    return nil, "Could not insert " .. insert .. " (plugin not found by name)"
  end
  return nil, (spec == "" and "No ReaEQ / Pro-Q 3 / Pro-Q 4 on this track" or ("No FX matching '" .. spec .. "'"))
end


-------------------------------------------------------------------------------
-- Settings (remembered between runs)
-------------------------------------------------------------------------------
local FIELDS = { "track", "fx", "insert", "measurement", "clear", "dryrun", "host", "port" }
local EXT = "REW_to_EQ"

local function load_settings()
  local s = {}
  for k, v in pairs(PRESET) do s[k] = v end
  if ASK_EACH_TIME then
    for _, k in ipairs(FIELDS) do
      if reaper.HasExtState(EXT, k) then s[k] = reaper.GetExtState(EXT, k) end
    end
  end
  return s
end

local function save_settings(s)
  for _, k in ipairs(FIELDS) do reaper.SetExtState(EXT, k, tostring(s[k] or ""), true) end
end

-------------------------------------------------------------------------------
-- Run: pull filters from REW and write them into the target plugin
-- Returns ok (bool), short status text
-------------------------------------------------------------------------------
local function fail(msg)
  reaper.ShowMessageBox(msg, "REW -> EQ", 0)
  return false, (msg:match("^[^\n]*"))
end

local function run(S)
  for k in pairs(LOG) do LOG[k] = nil end
  for k in pairs(WARN) do WARN[k] = nil end
  PORT = (S.port ~= "" and S.port) or "4735"
  REW_HOST = (trim(S.host or "") ~= "" and trim(S.host)) or "127.0.0.1"

  local tr, trLabel = find_track(S.track)
  if not tr then return fail("Track not found: '" .. S.track .. "' (no track selected?)") end

  local fx, ferr = find_fx(tr, S.fx, S.insert)
  if not fx then return fail(ferr) end
  local _, fxName = reaper.TrackFX_GetFXName(tr, fx, "")
  local kind = fx_kind(fxName)
  if not kind then
    -- renamed instance: fall back to the original plugin name
    local ok, orig = reaper.TrackFX_GetNamedConfigParm(tr, fx, "fx_name")
    if ok then kind = fx_kind(orig) end
  end
  if not kind then return fail("FX '" .. fxName .. "' is not ReaEQ, Pro-Q 3 or Pro-Q 4.") end

  -- REW
  local st, info = rew_status()
  if st == "unreachable" then return fail(rew_unreachable_msg()) end
  if st == "empty" then return fail(REW_EMPTY_MSG) end
  if st == "error" then
    return fail("REW answered, but with an error when listing measurements.\n\n" .. tostring(info) ..
      "\n\nThis script needs REW 5.40 or later.")
  end
  local spec = trim(S.measurement)
  if spec ~= "" and info[spec] == nil and info[tonumber(spec)] == nil then
    local names, keys = {}, {}
    for k in pairs(info) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return (tonumber(a) or 0) < (tonumber(b) or 0) end)
    for _, k in ipairs(keys) do names[#names + 1] = ("  %s: %s"):format(k, measurement_label(info[k])) end
    return fail(("REW has no measurement %s. It currently has:\n%s\n\nPick one in the REW measurement menu.")
      :format(spec, table.concat(names, "\n")))
  end

  local mid, mlabel = resolve_measurement(spec)
  if not mid then
    -- REW is reachable and has measurements, but none is selected
    return fail(tostring(mlabel):gsub("Enter a measurement index:",
      "Select one in REW, or pick one in this script's REW measurement menu. REW has:"), nil)
  end
  local raw, rerr = fetch_filters(mid)
  if not raw then return fail("Could not read filters for measurement '" .. tostring(mlabel) .. "':\n" .. tostring(rerr)) end
  local filters = normalise_filters(raw)

  log("REW measurement: %s", mlabel)
  log("Target: %s, FX %d '%s'", trLabel, fx + 1, fxName)
  log("%d active filter(s) from REW", #filters)

  if yes(S.dryrun) then
    reaper.ClearConsole()
    reaper.ShowConsoleMsg("=== DRY RUN ===\n" .. table.concat(LOG, "\n") .. "\n\nREW filters:\n")
    for i, f in ipairs(filters) do
      reaper.ShowConsoleMsg(("  %2d  %-8s -> %-10s %8.1f Hz  %+6.2f dB  Q %.3f\n"):format(
        i, tostring(f.raw), f.kind, f.freq, f.gain, f.q))
    end
    reaper.ShowConsoleMsg("\nPlugin parameters:\n")
    for p = 0, math.min(reaper.TrackFX_GetNumParams(tr, fx) - 1, 199) do
      local _, n = reaper.TrackFX_GetParamName(tr, fx, p, "")
      local _, v = reaper.TrackFX_GetFormattedParamValue(tr, fx, p, "")
      reaper.ShowConsoleMsg(("  %3d  %-32s %s\n"):format(p, n, v))
    end
    if #WARN > 0 then reaper.ShowConsoleMsg("\nNotes:\n  " .. table.concat(WARN, "\n  ") .. "\n") end
    return true, ("Dry run: %d filter(s) listed in the console"):format(#filters)
  end

  if #filters == 0 then return fail("REW returned no active filters for '" .. tostring(mlabel) .. "'.") end

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)
  local ok, err
  if kind == "reaeq" then ok, err = apply_reaeq(tr, fx, filters, yes(S.clear))
  else ok, err = apply_proq(tr, fx, filters, yes(S.clear)) end
  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock("REW filters -> " .. fxName, -1)

  if not ok then return fail(err) end
  reaper.ShowConsoleMsg(table.concat(LOG, "\n") .. "\n" ..
    (#WARN > 0 and ("Notes:\n  " .. table.concat(WARN, "\n  ") .. "\n") or "") .. "Done.\n\n")
  local short = fxName:gsub("^%w+%d?i?:%s*", "")
  return true, ("%d filter(s) written to %s%s"):format(#filters, short,
    #WARN > 0 and (" - %d note(s) in console"):format(#WARN) or "")
end

-------------------------------------------------------------------------------
-- Window (REAPER's built-in gfx; no extension needed)
-------------------------------------------------------------------------------
local function menu_item(s)
  s = tostring(s):gsub("|", "/"):gsub("&", "&&")
  if s:match("^[#!<>]") then s = " " .. s end
  return s
end

local function short_fx_name(n) return (n:gsub("^%w+%d?i?:%s*", "")) end

-- Menus -------------------------------------------------------------------
local function track_menu(S)
  local items, specs = { "Selected track", "Master track" }, { "", "master" }
  local names = {}
  for i = 0, reaper.CountTracks(0) - 1 do
    local _, n = reaper.GetTrackName(reaper.GetTrack(0, i))
    names[n] = (names[n] or 0) + 1
  end
  for i = 0, reaper.CountTracks(0) - 1 do
    local _, n = reaper.GetTrackName(reaper.GetTrack(0, i))
    items[#items + 1] = ("%d: %s"):format(i + 1, n)
    -- store by name when unique (survives track reordering), else by number
    specs[#specs + 1] = (names[n] == 1 and not tonumber(n) and n:lower() ~= "master") and n or tostring(i + 1)
  end
  return items, specs
end

local function fx_menu(S)
  local items, specs = { "First ReaEQ / Pro-Q on the track" }, { "" }
  local tr = find_track(S.track)
  if tr then
    local count = reaper.TrackFX_GetCount(tr)
    local names = {}
    for i = 0, count - 1 do
      local _, n = reaper.TrackFX_GetFXName(tr, i, "")
      names[n] = (names[n] or 0) + 1
    end
    for i = 0, count - 1 do
      local _, n = reaper.TrackFX_GetFXName(tr, i, "")
      items[#items + 1] = ("%d: %s"):format(i + 1, short_fx_name(n))
      specs[#specs + 1] = (names[n] == 1 and not tonumber(n)) and n or tostring(i + 1)
    end
  end
  items[#items + 1] = "Type a name..."
  specs[#specs + 1] = false
  return items, specs
end

local INSERT_CHOICES = { { "no", "No" }, { "ReaEQ", "ReaEQ" }, { "ProQ3", "Pro-Q 3" }, { "ProQ4", "Pro-Q 4" } }

local MEAS_TITLES = {}
local function measurement_menu(S)
  PORT = (S.port ~= "" and S.port) or "4735"
  REW_HOST = (trim(S.host or "") ~= "" and trim(S.host)) or "127.0.0.1"
  local items, specs = { "Selected in REW" }, { "" }
  local st, list = rew_status()
  if st == "ok" then
    local keys = {}
    for k, m in pairs(list) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return (tonumber(a) or 0) < (tonumber(b) or 0) end)
    for _, k in ipairs(keys) do
      local title = measurement_label(list[k])
      MEAS_TITLES[tostring(k)] = title
      items[#items + 1] = ("%s: %s"):format(k, title)
      specs[#specs + 1] = tostring(k)
    end
  else
    items[#items + 1] = (st == "empty") and "(REW has no measurements)"
      or ("(REW not reachable at " .. REW_HOST .. ":" .. PORT .. ")")
    specs[#specs + 1] = nil
  end
  return items, specs
end

-- Display text for current values ------------------------------------------------
local function track_text(S)
  if S.track == "" then
    local tr = reaper.GetSelectedTrack(0, 0)
    if tr then local _, n = reaper.GetTrackName(tr); return "Selected track (" .. n .. ")" end
    return "Selected track (none selected)"
  end
  if S.track:lower() == "master" then return "Master track" end
  local tr, label = find_track(S.track)
  if not tr then return S.track .. "  (not found)" end
  local _, n = reaper.GetTrackName(tr)
  return (label:match("track (%d+)") or "?") .. ": " .. n
end

local function fx_text(S)
  if S.fx == "" then return "First ReaEQ / Pro-Q on the track" end
  local n = tonumber(S.fx)
  local tr = find_track(S.track)
  if n and tr then
    local ok, name = reaper.TrackFX_GetFXName(tr, n - 1, "")
    if ok then return n .. ": " .. short_fx_name(name) end
  end
  return short_fx_name(S.fx)
end

local function insert_text(S)
  for _, c in ipairs(INSERT_CHOICES) do
    if c[1]:lower() == trim(S.insert):lower():gsub("[%s%-]", "") then return c[2] end
  end
  return "No"
end

local function measurement_text(S)
  if S.measurement == "" then return "Selected in REW" end
  local t = MEAS_TITLES[S.measurement]
  return S.measurement .. (t and (": " .. t) or "")
end

-- Drawing helpers --------------------------------------------------------------
local SC = 1
local COL = {
  bg = { 0.17, 0.17, 0.18 }, ctl = { 0.24, 0.24, 0.26 }, hover = { 0.30, 0.30, 0.33 },
  border = { 0.38, 0.38, 0.42 }, text = { 0.90, 0.90, 0.92 }, dim = { 0.60, 0.60, 0.64 },
  accent = { 0.20, 0.47, 0.70 }, accentHover = { 0.25, 0.55, 0.80 },
  ok = { 0.45, 0.80, 0.50 }, err = { 0.95, 0.45, 0.40 },
}
local function setc(c) gfx.set(c[1], c[2], c[3], 1) end
local function px(v) return math.floor(v * SC + 0.5) end

local function inside(x, y, w, h)
  return gfx.mouse_x >= x and gfx.mouse_x < x + w and gfx.mouse_y >= y and gfx.mouse_y < y + h
end

local function fit_text(s, maxw)
  if gfx.measurestr(s) <= maxw then return s end
  while #s > 1 and gfx.measurestr(s .. "...") > maxw do s = s:sub(1, -2) end
  return s .. "..."
end

local function draw_text(s, x, y, h, col)
  setc(col or COL.text)
  local _, th = gfx.measurestr("Ag")
  gfx.x, gfx.y = x, y + math.floor((h - th) / 2)
  gfx.drawstr(s)
end

local function box(x, y, w, h, fill, border)
  setc(fill); gfx.rect(x, y, w, h, 1)
  setc(border or COL.border); gfx.rect(x, y, w, h, 0)
end

-- Main window ----------------------------------------------------------------------
local function gui()
  local S = load_settings()
  local status, statusOk = "Ready.", true
  local W, H = 470, 320

  gfx.ext_retina = 1
  local dx = tonumber(reaper.GetExtState(EXT, "win_x"))
  local dy = tonumber(reaper.GetExtState(EXT, "win_y"))
  gfx.init("REW -> EQ", W, H, 0, dx or 200, dy or 200)
  SC = gfx.ext_retina > 0 and gfx.ext_retina or 1
  gfx.setfont(1, "Arial", px(14))

  local lastDown = false

  local function save_window()
    local _, x, y = gfx.dock(-1, 0, 0, 0, 0)
    reaper.SetExtState(EXT, "win_x", tostring(x), true)
    reaper.SetExtState(EXT, "win_y", tostring(y), true)
  end

  local function popup(items, x, y)
    local t = {}
    for i, it in ipairs(items) do t[i] = menu_item(it) end
    gfx.x, gfx.y = x, y
    return gfx.showmenu(table.concat(t, "|"))
  end

  local function apply()
    save_settings(S)
    local ok, msg = run(S)
    status, statusOk = msg or "", ok
  end

  local function loop()
    local ch = gfx.getchar()
    if ch < 0 or ch == 27 then save_window(); gfx.quit(); return end
    if ch == 13 then apply() end

    local down = (gfx.mouse_cap & 1) == 1
    local click = down and not lastDown
    lastDown = down

    setc(COL.bg); gfx.rect(0, 0, gfx.w, gfx.h, 1)

    local m = px(16)
    local labelW = px(150)
    local cx = m + labelW
    local cw = gfx.w - cx - m
    local rh, ch_ = px(32), px(24)
    local y = m

    -- dropdown row
    local function dropdown(label, text, onclick)
      draw_text(label, m, y, ch_, COL.dim)
      local hov = inside(cx, y, cw, ch_)
      box(cx, y, cw, ch_, hov and COL.hover or COL.ctl)
      draw_text(fit_text(text, cw - px(30)), cx + px(8), y, ch_)
      -- arrow
      setc(COL.dim)
      local ax, ay = cx + cw - px(16), y + math.floor(ch_ / 2) - px(2)
      gfx.triangle(ax - px(4), ay, ax + px(4), ay, ax, ay + px(5))
      if click and hov then onclick(cx, y + ch_) end
      y = y + rh
    end

    -- checkbox row
    local function checkbox(label, key)
      local on = yes(S[key])
      local bs = px(16)
      local by = y + math.floor((ch_ - bs) / 2)
      local hov = inside(m, y, cx + cw - m, ch_)
      box(m, by, bs, bs, hov and COL.hover or COL.ctl)
      if on then
        setc(COL.text)
        gfx.line(m + px(3), by + px(8), m + px(7), by + px(12))
        gfx.line(m + px(7), by + px(12), m + px(13), by + px(4))
        gfx.line(m + px(3), by + px(9), m + px(7), by + px(13))
        gfx.line(m + px(7), by + px(13), m + px(13), by + px(5))
      end
      draw_text(label, m + bs + px(10), y, ch_)
      if click and hov then S[key] = on and "n" or "y"; save_settings(S) end
      y = y + rh
    end

    dropdown("Track", track_text(S), function(x, yy)
      local items, specs = track_menu(S)
      local i = popup(items, x, yy)
      if i > 0 and specs[i] ~= nil then S.track = specs[i]; S.fx = ""; save_settings(S) end
    end)

    dropdown("EQ plugin", fx_text(S), function(x, yy)
      local items, specs = fx_menu(S)
      local i = popup(items, x, yy)
      if i > 0 then
        if specs[i] == false then
          local ok, v = reaper.GetUserInputs("REW -> EQ", 1, "FX name (or part of it),extrawidth=150", S.fx)
          if ok then S.fx = trim(v) end
        else
          S.fx = specs[i]
        end
        save_settings(S)
      end
    end)

    dropdown("If no EQ found", "Insert: " .. insert_text(S), function(x, yy)
      local items = {}
      for k, c in ipairs(INSERT_CHOICES) do items[k] = (k == 1) and "Don't insert anything" or ("Insert " .. c[2]) end
      local i = popup(items, x, yy)
      if i > 0 then S.insert = INSERT_CHOICES[i][1]; save_settings(S) end
    end)

    dropdown("REW measurement", measurement_text(S), function(x, yy)
      local items, specs = measurement_menu(S)
      local i = popup(items, x, yy)
      if i > 0 and specs[i] ~= nil then S.measurement = specs[i]; save_settings(S) end
    end)

    local host = trim(S.host or "") ~= "" and trim(S.host) or "127.0.0.1"
    local hostText = (host == "127.0.0.1" or host == "localhost") and ("This computer : " .. S.port)
                     or (host .. " : " .. S.port)
    dropdown("REW address", hostText, function()
      local ok, v = reaper.GetUserInputs("REW -> EQ", 2,
        "REW computer IP (127.0.0.1 = this one),API port,extrawidth=60", host .. "," .. S.port)
      if ok then
        local h, p = v:match("^([^,]*),([^,]*)$")
        h, p = trim(h or ""), trim(p or "")
        if h ~= "" then S.host = h end
        if tonumber(p) then S.port = p end
        MEAS_TITLES = {}
        save_settings(S)
      end
    end)

    y = y + px(4)
    checkbox("Disable unused bands in the EQ", "clear")
    checkbox("Dry run (only list what would be done)", "dryrun")

    -- buttons
    y = y + px(6)
    local bw, bh = px(110), px(28)
    local function button(text, x, primary, onclick)
      local hov = inside(x, y, bw, bh)
      local fill = primary and (hov and COL.accentHover or COL.accent) or (hov and COL.hover or COL.ctl)
      box(x, y, bw, bh, fill, primary and fill or COL.border)
      setc(COL.text)
      local tw, th = gfx.measurestr(text)
      gfx.x, gfx.y = x + math.floor((bw - tw) / 2), y + math.floor((bh - th) / 2)
      gfx.drawstr(text)
      if click and hov then onclick() end
    end
    local closing = false
    button(yes(S.dryrun) and "Dry run" or "Apply", gfx.w - m - bw * 2 - px(10), true, apply)
    button("Close", gfx.w - m - bw, false, function() closing = true end)
    y = y + bh + px(12)

    -- status
    draw_text(fit_text(status, gfx.w - 2 * m), m, y, px(20), statusOk and COL.ok or COL.err)

    gfx.update()
    if closing then save_window(); gfx.quit(); return end
    reaper.defer(loop)
  end

  loop()
end

-------------------------------------------------------------------------------
-- Entry point
-------------------------------------------------------------------------------
if ASK_EACH_TIME then
  gui()
else
  run(load_settings())
end
