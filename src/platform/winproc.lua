-- Runs a command line with no console window (CreateProcessW +
-- CREATE_NO_WINDOW), so a fused GUI build never flashes a terminal the way
-- io.popen/os.execute would. Windows only.
local ffi = require("ffi")
local fs = require("src.data.fs")

local W = {}

pcall(ffi.cdef, [[
  typedef struct {
    DWORD cb; WCHAR* lpReserved; WCHAR* lpDesktop; WCHAR* lpTitle;
    DWORD dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
    uint16_t wShowWindow; uint16_t cbReserved2; uint8_t* lpReserved2;
    HANDLE hStdInput, hStdOutput, hStdError;
  } cardtable_STARTUPINFOW;
  typedef struct { HANDLE hProcess; HANDLE hThread; DWORD dwProcessId; DWORD dwThreadId; } cardtable_PROCESS_INFORMATION;
  BOOL CreateProcessW(const WCHAR* app, WCHAR* cmdLine, void* procAttrs, void* threadAttrs, BOOL inherit,
                      DWORD flags, void* env, const WCHAR* cwd, cardtable_STARTUPINFOW* si, cardtable_PROCESS_INFORMATION* pi);
  DWORD WaitForSingleObject(HANDLE h, DWORD ms);
  BOOL GetExitCodeProcess(HANDLE h, DWORD* code);
  BOOL CloseHandle(HANDLE h);
]])
pcall(ffi.cdef, "DWORD GetCurrentProcessId(void);")

local CREATE_NO_WINDOW = 0x08000000
local INFINITE = 0xFFFFFFFF
local WAIT_TIMEOUT = 0x102

-- Quotes one argument for the MSVCRT command-line parser.
function W.quoteArg(s)
  s = tostring(s)
  if s ~= "" and not s:find('[%s"]') then return s end
  s = s:gsub('(\\*)"', function(bs) return bs .. bs .. '\\"' end):gsub("(\\+)$", "%1%1")
  return '"' .. s .. '"'
end

-- Runs `cmdLine` hidden. With opts.wait, blocks (opts.timeoutMs, default
-- forever) and returns the exit code; otherwise returns true once started.
-- Returns nil, message on failure.
function W.run(cmdLine, opts)
  opts = opts or {}
  local si = ffi.new("cardtable_STARTUPINFOW")
  si.cb = ffi.sizeof(si)
  local pi = ffi.new("cardtable_PROCESS_INFORMATION")
  -- CreateProcessW may write into the command line buffer, so it must be a
  -- mutable copy.
  local cmd = fs._impl.toWide(cmdLine)
  local cwd = opts.cwd and fs._impl.toWide(opts.cwd) or nil
  if ffi.C.CreateProcessW(nil, cmd, nil, nil, 0, CREATE_NO_WINDOW, nil, cwd, si, pi) == 0 then
    return nil, "could not start process (error " .. tonumber(ffi.C.GetLastError()) .. ")"
  end
  ffi.C.CloseHandle(pi.hThread)
  if not opts.wait then
    ffi.C.CloseHandle(pi.hProcess)
    return true
  end
  local r = ffi.C.WaitForSingleObject(pi.hProcess, opts.timeoutMs or INFINITE)
  local code = ffi.new("DWORD[1]")
  ffi.C.GetExitCodeProcess(pi.hProcess, code)
  ffi.C.CloseHandle(pi.hProcess)
  if r == WAIT_TIMEOUT then return nil, "process timed out" end
  return tonumber(code[0])
end

function W.currentPid() return tonumber(ffi.C.GetCurrentProcessId()) end

return W
