-- Native file / folder pickers. Windows uses the Vista-style
-- IFileOpenDialog through COM via LuaJIT FFI; the call is modal and blocks
-- until the user picks or cancels (like Flutter's file_selector). Other
-- platforms fall back to zenity/kdialog when available.
local ffi = require("ffi")

local D = {}

local isWindows = ffi.os == "Windows"

if isWindows then
  ffi.cdef([[
    typedef long HRESULT;
    typedef struct { unsigned long Data1; unsigned short Data2, Data3; unsigned char Data4[8]; } GUID_CF;
    typedef struct { const unsigned short* pszName; const unsigned short* pszSpec; } COMDLG_FILTERSPEC_CF;
    HRESULT CoInitializeEx(void* reserved, unsigned long coinit);
    HRESULT CoCreateInstance(const GUID_CF* clsid, void* outer, unsigned long ctx, const GUID_CF* iid, void** out);
    void CoTaskMemFree(void* p);
    HRESULT SHCreateItemFromParsingName(const unsigned short* path, void* bc, const GUID_CF* iid, void** out);
    void* GetActiveWindow(void);
    int SetForegroundWindow(void* hwnd);
  ]])
end

local function guid(s)
  local g = ffi.new("GUID_CF")
  local p = { s:match("(%x+)-(%x+)-(%x+)-(%x%x)(%x%x)-(%x%x)(%x%x)(%x%x)(%x%x)(%x%x)(%x%x)") }
  g.Data1 = tonumber(p[1], 16)
  g.Data2 = tonumber(p[2], 16)
  g.Data3 = tonumber(p[3], 16)
  for i = 0, 7 do g.Data4[i] = tonumber(p[4 + i], 16) end
  return g
end

local CLSID_FileOpenDialog, IID_IFileOpenDialog, IID_IShellItem
local ole32, shell32
local fsImpl

local function init()
  if ole32 then return true end
  local ok = pcall(function()
    ole32 = ffi.load("ole32")
    shell32 = ffi.load("shell32")
  end)
  if not ok then return false end
  CLSID_FileOpenDialog = guid("DC1C5A9C-E88A-4dde-A5A1-60F82A20AEF7")
  IID_IFileOpenDialog = guid("d57c7288-d4ad-4768-be02-9d969532d960")
  IID_IShellItem = guid("43826d1e-e718-42ee-bc55-a1e261c37bfe")
  fsImpl = require("src.data.fs")._impl
  ole32.CoInitializeEx(nil, 2) -- COINIT_APARTMENTTHREADED (S_FALSE if already)
  return true
end

-- Calls vtable slot `index` of COM object `obj` with signature `sig`
-- (the argument list after `void* self`).
local sigCache = {}
local function com(obj, index, sig, ...)
  local ct = sigCache[sig]
  if not ct then
    ct = ffi.typeof("HRESULT(__stdcall*)(void*" .. (sig ~= "" and (", " .. sig) or "") .. ")")
    sigCache[sig] = ct
  end
  local vtbl = ffi.cast("void***", obj)[0]
  return ffi.cast(ct, vtbl[index])(obj, ...)
end

local function release(obj) if obj ~= nil then com(obj, 2, "") end end

-- "C:\..." / "\\server\share" on Windows, "/..." elsewhere.
function D.isAbsolute(path)
  if type(path) ~= "string" then return false end
  if isWindows then return path:match("^%a:[/\\]") ~= nil or path:match("^[/\\][/\\]") ~= nil end
  return path:sub(1, 1) == "/"
end

local FOS_PICKFOLDERS = 0x20
local FOS_FORCEFILESYSTEM = 0x40
local FOS_PATHMUSTEXIST = 0x800
local FOS_FILEMUSTEXIST = 0x1000
-- 0x80058000 doesn't fit a signed int; ffi.cast("int", ...) would clamp it
-- to 0x80000000 (and Windows then returns just the item's name), so wrap it
-- with bit.tobit to keep the bit pattern.
local SIGDN_FILESYSPATH = bit.tobit(0x80058000)

-- opts: title, folder (bool), filters { {name=, extensions={"png",...}} },
--       initialDir
local function showWindows(opts)
  if not init() then return nil end
  local pp = ffi.new("void*[1]")
  if ole32.CoCreateInstance(CLSID_FileOpenDialog, nil, 1, IID_IFileOpenDialog, pp) < 0 then return nil end
  local dlg = pp[0]
  local result
  local keep = {}
  local ok, err = pcall(function()
    local options = ffi.new("unsigned long[1]")
    com(dlg, 10, "unsigned long*", options)
    local flags = tonumber(options[0]) + FOS_FORCEFILESYSTEM + FOS_PATHMUSTEXIST
    if opts.folder then flags = flags + FOS_PICKFOLDERS else flags = flags + FOS_FILEMUSTEXIST end
    com(dlg, 9, "unsigned long", flags)
    if opts.title then
      local w = fsImpl.toWide(opts.title)
      keep[#keep + 1] = w
      com(dlg, 17, "const unsigned short*", w)
    end
    if not opts.folder and opts.filters and #opts.filters > 0 then
      local specs = ffi.new("COMDLG_FILTERSPEC_CF[?]", #opts.filters)
      for i, f in ipairs(opts.filters) do
        local pats = {}
        for _, e in ipairs(f.extensions) do pats[#pats + 1] = "*." .. e end
        local name = fsImpl.toWide(f.name)
        local spec = fsImpl.toWide(table.concat(pats, ";"))
        keep[#keep + 1] = name
        keep[#keep + 1] = spec
        specs[i - 1].pszName = name
        specs[i - 1].pszSpec = spec
      end
      keep[#keep + 1] = specs
      com(dlg, 4, "unsigned int, const COMDLG_FILTERSPEC_CF*", #opts.filters, specs)
    end
    if opts.initialDir then
      local ip = ffi.new("void*[1]")
      if shell32.SHCreateItemFromParsingName(fsImpl.toWide(opts.initialDir), nil, IID_IShellItem, ip) >= 0 then
        com(dlg, 12, "void*", ip[0])
        release(ip[0])
      end
    end
    local owner = ffi.C.GetActiveWindow()
    -- Show() is called from a Lua callback rather than directly inside a
    -- native input handler, so Windows' foreground-lock heuristic doesn't
    -- treat it as a direct response to the click that triggered it and
    -- refuses to raise the dialog automatically; it opens behind the owner
    -- until the user alt-tabs. Forcing foreground here fixes that.
    ffi.C.SetForegroundWindow(owner)
    local hr = com(dlg, 3, "void*", owner)
    if hr < 0 then return end -- cancelled (or failed)
    local itemp = ffi.new("void*[1]")
    if com(dlg, 20, "void**", itemp) < 0 then return end
    local namep = ffi.new("unsigned short*[1]")
    if com(itemp[0], 5, "int, unsigned short**", SIGDN_FILESYSPATH, namep) >= 0 then
      local path = fsImpl.fromWide(namep[0])
      ole32.CoTaskMemFree(namep[0])
      if D.isAbsolute(path) then
        result = path
      else
        print("file dialog returned a non-absolute path: " .. path)
      end
    end
    release(itemp[0])
  end)
  release(dlg)
  if not ok then print("file dialog error: " .. tostring(err)) end
  return result
end

local function showUnix(opts)
  local function run(cmd)
    local p = io.popen(cmd .. " 2>/dev/null")
    if not p then return nil end
    local out = p:read("*l")
    p:close()
    if out and out ~= "" then return out end
    return nil
  end
  local q = function(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end
  local title = q(opts.title or (opts.folder and "Choose a folder" or "Choose a file"))
  if opts.folder then
    return run("zenity --file-selection --directory --title=" .. title) or run("kdialog --getexistingdirectory .")
  end
  local filter = ""
  if opts.filters and opts.filters[1] then
    local pats = {}
    for _, e in ipairs(opts.filters[1].extensions) do pats[#pats + 1] = "*." .. e end
    filter = " --file-filter=" .. q(opts.filters[1].name .. " | " .. table.concat(pats, " "))
  end
  return run("zenity --file-selection --title=" .. title .. filter) or run("kdialog --getopenfilename .")
end

-- Round-trips a path through a shell item and back with the same
-- GetDisplayName call the dialogs use (lets tests check it headlessly).
function D._shellItemPath(path)
  if not isWindows or not init() then return nil end
  local ip = ffi.new("void*[1]")
  if shell32.SHCreateItemFromParsingName(fsImpl.toWide(path), nil, IID_IShellItem, ip) < 0 then return nil end
  local namep = ffi.new("unsigned short*[1]")
  local result
  if com(ip[0], 5, "int, unsigned short**", SIGDN_FILESYSPATH, namep) >= 0 then
    result = fsImpl.fromWide(namep[0])
    ole32.CoTaskMemFree(namep[0])
  end
  release(ip[0])
  return result
end

-- Returns an absolute path, or nil when cancelled/unavailable.
function D.openFile(opts)
  opts = opts or {}
  opts.folder = false
  if isWindows then return showWindows(opts) end
  return showUnix(opts)
end

function D.pickFolder(opts)
  opts = opts or {}
  opts.folder = true
  if isWindows then return showWindows(opts) end
  return showUnix(opts)
end

D.imageFilters = { { name = "Image", extensions = { "jpg", "jpeg", "png", "webp" } } }
D.jsonFilters = { { name = "JSON", extensions = { "json" } } }

return D
