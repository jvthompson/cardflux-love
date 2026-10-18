-- Absolute-path filesystem access outside LÖVE's sandbox.
-- File contents go through Lua's io library; directory operations use
-- LuaJIT FFI (Win32 wide-char APIs on Windows, libc elsewhere).
local ffi = require("ffi")

local fs = {}

local isWindows = ffi.os == "Windows"
fs.isWindows = isWindows
fs.sep = isWindows and "\\" or "/"

---------------------------------------------------------------------------
-- Path helpers (accept both separators on Windows)
---------------------------------------------------------------------------

function fs.normalize(p)
  if isWindows then return (p:gsub("/", "\\")) end
  return p
end

function fs.join(...)
  local parts = { ... }
  local out = ""
  for _, part in ipairs(parts) do
    if part ~= nil and part ~= "" then
      if out == "" then
        out = part
      else
        out = out:gsub("[/\\]+$", "") .. fs.sep .. part:gsub("^[/\\]+", "")
      end
    end
  end
  return fs.normalize(out)
end

function fs.basename(p)
  return p:match("([^/\\]+)[/\\]*$") or p
end

function fs.dirname(p)
  local d = p:match("^(.*)[/\\][^/\\]*$")
  if d == nil or d == "" then return p:match("^[/\\]") and fs.sep or "." end
  if d:match("^%a:$") then return d .. fs.sep end
  return d
end

-- Extension including the dot, lowercase ("" when none).
function fs.extension(p)
  local base = fs.basename(p)
  local ext = base:match("^.+(%.[^.]+)$")
  return ext and ext:lower() or ""
end

-- Strips from the last dot (like Dart's stripExtension).
function fs.stripExtension(name)
  local idx = name:match("^.*()%.")
  if idx and idx > 1 then return name:sub(1, idx - 1) end
  return name
end

---------------------------------------------------------------------------
-- File contents
---------------------------------------------------------------------------

-- Lua's io.open uses the ANSI codepage on Windows, so non-ASCII paths go
-- through the wide-char CRT instead (set up in the platform layer below).
local wideIO

function fs.readFile(path)
  if wideIO then return wideIO.read(path) end
  local f, err = io.open(path, "rb")
  if not f then return nil, err end
  local data = f:read("*a")
  f:close()
  return data
end

function fs.writeFile(path, data)
  if wideIO then return wideIO.write(path, data) end
  local f, err = io.open(path, "wb")
  if not f then return false, err end
  f:write(data)
  f:close()
  return true
end

---------------------------------------------------------------------------
-- Platform layer
---------------------------------------------------------------------------

local impl = {}

if isWindows then
  ffi.cdef([[
    typedef unsigned short WCHAR;
    typedef unsigned long DWORD;
    typedef int BOOL;
    typedef void* HANDLE;
    typedef struct { DWORD lo; DWORD hi; } FILETIME_CF;
    typedef struct {
      DWORD dwFileAttributes;
      FILETIME_CF ftCreationTime;
      FILETIME_CF ftLastAccessTime;
      FILETIME_CF ftLastWriteTime;
      DWORD nFileSizeHigh;
      DWORD nFileSizeLow;
      DWORD dwReserved0;
      DWORD dwReserved1;
      WCHAR cFileName[260];
      WCHAR cAlternateFileName[14];
    } WIN32_FIND_DATAW_CF;
    int MultiByteToWideChar(unsigned int cp, DWORD flags, const char* s, int n, WCHAR* out, int outn);
    int WideCharToMultiByte(unsigned int cp, DWORD flags, const WCHAR* s, int n, char* out, int outn,
                            const char* def, BOOL* used);
    HANDLE FindFirstFileW(const WCHAR* path, WIN32_FIND_DATAW_CF* data);
    BOOL FindNextFileW(HANDLE h, WIN32_FIND_DATAW_CF* data);
    BOOL FindClose(HANDLE h);
    DWORD GetFileAttributesW(const WCHAR* path);
    BOOL CreateDirectoryW(const WCHAR* path, void* sec);
    BOOL RemoveDirectoryW(const WCHAR* path);
    BOOL DeleteFileW(const WCHAR* path);
    BOOL MoveFileExW(const WCHAR* from, const WCHAR* to, DWORD flags);
    BOOL CopyFileW(const WCHAR* from, const WCHAR* to, BOOL failIfExists);
    DWORD GetModuleFileNameW(void* module, WCHAR* out, DWORD size);
    DWORD GetTempPathW(DWORD n, WCHAR* out);
  ]])
  local k32 = ffi.C
  local CP_UTF8 = 65001
  local INVALID_HANDLE = ffi.cast("HANDLE", -1)
  local INVALID_ATTRS = 0xFFFFFFFF
  local DIR_ATTR = 0x10

  local function toWide(s)
    local n = k32.MultiByteToWideChar(CP_UTF8, 0, s, -1, nil, 0)
    local buf = ffi.new("WCHAR[?]", n)
    k32.MultiByteToWideChar(CP_UTF8, 0, s, -1, buf, n)
    return buf
  end

  -- Prefixes a fully-qualified path with \\?\ (\\?\UNC\ for a \\server\share
  -- path), which tells the Win32 *W functions to bypass the legacy ~260-char
  -- MAX_PATH limit -- otherwise a deeply nested game/deck library folder
  -- silently "doesn't exist." Only valid for an already-absolute path with
  -- backslash separators and no "."/".." segments, which fs.normalize's
  -- output always is for the absolute paths these calls receive; a relative
  -- or already-prefixed path is returned unchanged.
  local function longPath(p)
    if p:sub(1, 4) == "\\\\?\\" then return p end
    if p:sub(1, 2) == "\\\\" then return "\\\\?\\UNC\\" .. p:sub(3) end
    if p:match("^%a:\\") then return "\\\\?\\" .. p end
    return p
  end

  local function fromWide(w, len)
    len = len or -1
    local n = k32.WideCharToMultiByte(CP_UTF8, 0, w, len, nil, 0, nil, nil)
    if n <= 0 then return "" end
    local buf = ffi.new("char[?]", n)
    k32.WideCharToMultiByte(CP_UTF8, 0, w, len, buf, n, nil, nil)
    if len == -1 then return ffi.string(buf, n - 1) end
    return ffi.string(buf, n)
  end
  impl.toWide, impl.fromWide = toWide, fromWide

  function impl.attrs(p)
    local a = k32.GetFileAttributesW(toWide(longPath(fs.normalize(p))))
    if a == INVALID_ATTRS then return nil end
    return a
  end

  function impl.list(dir)
    local data = ffi.new("WIN32_FIND_DATAW_CF")
    local h = k32.FindFirstFileW(toWide(longPath(fs.join(dir, "*"))), data) -- fs.join already normalizes
    if h == INVALID_HANDLE then return nil end
    local out = {}
    repeat
      local name = fromWide(data.cFileName)
      if name ~= "." and name ~= ".." then
        local isDir = bit.band(data.dwFileAttributes, DIR_ATTR) ~= 0
        local size = tonumber(data.nFileSizeHigh) * 4294967296 + tonumber(data.nFileSizeLow)
        -- FILETIME: 100ns ticks since 1601 -> unix seconds
        local ticks = tonumber(data.ftLastWriteTime.hi) * 4294967296 + tonumber(data.ftLastWriteTime.lo)
        out[#out + 1] = { name = name, isDir = isDir, size = size, mtime = ticks / 1e7 - 11644473600 }
      end
    until k32.FindNextFileW(h, data) == 0
    k32.FindClose(h)
    return out
  end

  function impl.mkdir(p) return k32.CreateDirectoryW(toWide(longPath(fs.normalize(p))), nil) ~= 0 end
  function impl.rmdir(p) return k32.RemoveDirectoryW(toWide(longPath(fs.normalize(p)))) ~= 0 end
  function impl.remove(p) return k32.DeleteFileW(toWide(longPath(fs.normalize(p)))) ~= 0 end
  function impl.move(a, b)
    -- MOVEFILE_REPLACE_EXISTING | MOVEFILE_COPY_ALLOWED
    return k32.MoveFileExW(toWide(longPath(fs.normalize(a))), toWide(longPath(fs.normalize(b))), 0x1 + 0x2) ~= 0
  end
  function impl.copy(a, b) return k32.CopyFileW(toWide(longPath(fs.normalize(a))), toWide(longPath(fs.normalize(b))), 0) ~= 0 end
  function impl.exePath()
    local buf = ffi.new("WCHAR[1024]")
    local n = k32.GetModuleFileNameW(nil, buf, 1024)
    return fromWide(buf, n)
  end
  function impl.tempDir()
    local buf = ffi.new("WCHAR[1024]")
    local n = k32.GetTempPathW(1024, buf)
    return (fromWide(buf, n):gsub("[/\\]+$", ""))
  end

  ffi.cdef([[
    typedef struct _iobuf FILE_CF;
    FILE_CF* _wfopen(const WCHAR* path, const WCHAR* mode);
    size_t fread(void* buf, size_t size, size_t n, FILE_CF* f);
    size_t fwrite(const void* buf, size_t size, size_t n, FILE_CF* f);
    int fclose(FILE_CF* f);
  ]])
  local crt = ffi.load("msvcrt")
  wideIO = {}
  function wideIO.read(path)
    local f = crt._wfopen(toWide(longPath(fs.normalize(path))), toWide("rb"))
    if f == nil then return nil, path .. ": No such file or directory" end
    local chunks, buf = {}, ffi.new("char[65536]")
    while true do
      local n = tonumber(crt.fread(buf, 1, 65536, f))
      if n > 0 then chunks[#chunks + 1] = ffi.string(buf, n) end
      if n < 65536 then break end
    end
    crt.fclose(f)
    return table.concat(chunks)
  end
  function wideIO.write(path, data)
    local f = crt._wfopen(toWide(longPath(fs.normalize(path))), toWide("wb"))
    if f == nil then return false, path .. ": cannot open for writing" end
    local n = tonumber(crt.fwrite(data, 1, #data, f))
    crt.fclose(f)
    return n == #data
  end
else
  ffi.cdef([[
    typedef struct DIR DIR;
    DIR* opendir(const char* name);
    int closedir(DIR* d);
    int mkdir(const char* path, unsigned int mode);
    int rmdir(const char* path);
    int unlink(const char* path);
    int rename(const char* a, const char* b);
  ]])
  -- readdir's struct layout differs by platform; listing goes through `ls`
  -- for portability on the (secondary) non-Windows targets.
  local function shellQuote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
  impl.shellQuote = shellQuote

  function impl.attrs(p)
    local d = ffi.C.opendir(p)
    if d ~= nil then
      ffi.C.closedir(d)
      return "dir"
    end
    local f = io.open(p, "rb")
    if f then f:close() return "file" end
    return nil
  end

  function impl.list(dir)
    if impl.attrs(dir) ~= "dir" then return nil end
    local out = {}
    local pipe = io.popen("ls -1Ap " .. shellQuote(dir) .. " 2>/dev/null")
    if not pipe then return nil end
    for line in pipe:lines() do
      local isDir = line:sub(-1) == "/"
      out[#out + 1] = { name = isDir and line:sub(1, -2) or line, isDir = isDir, size = 0, mtime = 0 }
    end
    pipe:close()
    return out
  end

  function impl.mkdir(p) return ffi.C.mkdir(p, tonumber("755", 8)) == 0 end
  function impl.rmdir(p) return ffi.C.rmdir(p) == 0 end
  function impl.remove(p) return ffi.C.unlink(p) == 0 end
  function impl.move(a, b) return ffi.C.rename(a, b) == 0 end
  function impl.copy(a, b)
    local data = fs.readFile(a)
    if not data then return false end
    return fs.writeFile(b, data)
  end
  function impl.exePath() return nil end
  function impl.tempDir() return os.getenv("TMPDIR") or "/tmp" end
end

fs._impl = impl

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

function fs.exists(p)
  return impl.attrs(p) ~= nil
end

function fs.isDir(p)
  local a = impl.attrs(p)
  if a == nil then return false end
  if isWindows then return bit.band(a, 0x10) ~= 0 end
  return a == "dir"
end

function fs.isFile(p)
  local a = impl.attrs(p)
  if a == nil then return false end
  if isWindows then return bit.band(a, 0x10) == 0 end
  return a == "file"
end

-- Directory entries: { {name, isDir, size, mtime}, ... } sorted by name,
-- or nil if `dir` isn't a readable directory.
function fs.list(dir)
  local items = impl.list(dir)
  if items then table.sort(items, function(a, b) return a.name:lower() < b.name:lower() end) end
  return items
end

-- Creates `p` and any missing parents.
function fs.mkdirs(p)
  p = fs.normalize(p)
  if fs.isDir(p) then return true end
  local parent = fs.dirname(p)
  if parent ~= p and parent ~= "." and not fs.isDir(parent) then fs.mkdirs(parent) end
  impl.mkdir(p)
  return fs.isDir(p)
end

function fs.remove(p) return impl.remove(p) end

function fs.removeTree(p)
  if fs.isDir(p) then
    for _, e in ipairs(fs.list(p) or {}) do fs.removeTree(fs.join(p, e.name)) end
    return impl.rmdir(p)
  end
  return impl.remove(p)
end

function fs.move(a, b) return impl.move(a, b) end
function fs.copy(a, b) return impl.copy(a, b) end

-- Recursively copies `from` into `to`, overwriting existing files.
function fs.copyTree(from, to)
  if fs.isDir(from) then
    fs.mkdirs(to)
    for _, e in ipairs(fs.list(from) or {}) do fs.copyTree(fs.join(from, e.name), fs.join(to, e.name)) end
    return true
  end
  return impl.copy(from, to)
end

function fs.exePath() return impl.exePath() end
function fs.tempDir() return impl.tempDir() end

return fs
