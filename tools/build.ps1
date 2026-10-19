<#
.SYNOPSIS
  Packages CardTable (LOVE port) as a fused Windows build, and optionally
  publishes it as a GitHub Release the in-app updater picks up.

.DESCRIPTION
  1. (-Bump / -Publish) increments `build` in src/version.lua.
  2. Runs the test suite (skip with -SkipTests).
  3. Zips the game sources into build\game.love.
  4. Copies love.exe, swaps its icon for assets\icon.ico, and appends
     game.love to make build\CardTable\CardTable.exe.
  5. Adds the LOVE runtime DLLs, the app's own DLLs (Discord SDK, libwebp),
     LICENSE, CONTROLS.md and SUPPORT-ME.md.
  6. Zips build\CardTable\* (flat) as build\cardtable-windows.zip -- the exact
     asset name src/platform/updater.lua looks for.
  7. (-Publish) commits the version bump, pushes, and creates the GitHub
     Release (tag vNAME+BUILD) with the zip attached, via the gh CLI.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File tools\build.ps1
  powershell -ExecutionPolicy Bypass -File tools\build.ps1 -Publish
#>
param(
  [switch]$Bump,
  [switch]$Publish,
  [switch]$SkipTests
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$buildDir = Join-Path $root 'build'
$outDir = Join-Path $buildDir 'CardTable'
$versionPath = Join-Path $root 'src\version.lua'
$exeName = 'CardTable.exe'
$assetName = 'cardtable-windows.zip'

function Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }

# --- Locate LOVE -------------------------------------------------------------
$loveDir = $null
foreach ($d in @("$env:ProgramFiles\LOVE", "${env:ProgramFiles(x86)}\LOVE")) {
  if ($d -and (Test-Path (Join-Path $d 'love.exe'))) { $loveDir = $d; break }
}
if (-not $loveDir) {
  $cmd = Get-Command love.exe -ErrorAction SilentlyContinue
  if ($cmd) { $loveDir = Split-Path $cmd.Source }
}
if (-not $loveDir) { throw 'Could not find LOVE 11.5 (love.exe). Install it from https://love2d.org.' }

# --- Version -----------------------------------------------------------------
function Read-Version {
  $text = [IO.File]::ReadAllText($versionPath)
  $name = [regex]::Match($text, 'name\s*=\s*"([^"]+)"').Groups[1].Value
  $build = [int][regex]::Match($text, 'build\s*=\s*(\d+)').Groups[1].Value
  $repo = [regex]::Match($text, 'releaseRepo\s*=\s*"([^"]+)"').Groups[1].Value
  if (-not $name -or -not $repo) { throw "Could not read name/build/releaseRepo from $versionPath" }
  [pscustomobject]@{ Name = $name; Build = $build; Repo = $repo; Text = $text }
}

if ($Publish) {
  $dirty = git -C $root status --porcelain
  if ($dirty) { throw "Working tree has uncommitted changes -- commit or stash them before publishing:`n$dirty" }
  if (-not (Get-Command gh -ErrorAction SilentlyContinue) -and -not (Test-Path "$env:ProgramFiles\GitHub CLI\gh.exe")) {
    throw 'The GitHub CLI (gh) is required for -Publish.'
  }
}

$v = Read-Version
if ($Bump -or $Publish) {
  $newBuild = $v.Build + 1
  $text = [regex]::Replace($v.Text, '(build\s*=\s*)\d+', "`${1}$newBuild", 1)
  [IO.File]::WriteAllText($versionPath, $text, (New-Object Text.UTF8Encoding $false))
  $v = Read-Version
  Step "Bumped build number to $($v.Build)"
}
$tag = "v$($v.Name)+$($v.Build)"
Step "Packaging $tag"

# --- Tests -------------------------------------------------------------------
if (-not $SkipTests) {
  Step 'Running tests'
  & (Join-Path $loveDir 'lovec.exe') $root --test | Out-Host
  if ($LASTEXITCODE -ne 0) { throw "Tests failed (exit code $LASTEXITCODE)." }
}

# --- game.love ---------------------------------------------------------------
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

# Zip with forward-slash entry names (Compress-Archive in Windows PowerShell
# writes backslashes, which LOVE's PhysFS can't resolve).
function New-Zip($zipPath, $baseDir, $relPaths) {
  if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
  $zip = [IO.Compression.ZipFile]::Open($zipPath, 'Create')
  try {
    foreach ($rel in $relPaths) {
      $entry = $rel -replace '\\', '/'
      [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, (Join-Path $baseDir $rel), $entry, 'Optimal')
    }
  } finally { $zip.Dispose() }
}

function Get-RelFiles($baseDir, $items) {
  foreach ($item in $items) {
    $p = Join-Path $baseDir $item
    if (Test-Path $p -PathType Leaf) { $item; continue }
    Get-ChildItem $p -Recurse -File | ForEach-Object { $_.FullName.Substring($baseDir.Length + 1) }
  }
}

Step 'Creating game.love'
if (Test-Path $buildDir) { Remove-Item $buildDir -Recurse -Force }
New-Item -ItemType Directory -Force $outDir | Out-Null
$loveFiles = Get-RelFiles $root @('conf.lua', 'main.lua', 'lib', 'src', 'assets', 'CONTROLS.md', 'SUPPORT-ME.md') | Where-Object { $_ -ne 'assets\icon.ico' }
$lovePath = Join-Path $buildDir 'game.love'
New-Zip $lovePath $root $loveFiles

# --- Icon --------------------------------------------------------------------
# Replaces every icon resource in an exe with the frames of an .ico file.
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public static class CardTableIconPatcher {
  const uint LOAD_LIBRARY_AS_DATAFILE = 0x2;
  static readonly IntPtr RT_ICON = (IntPtr)3;
  static readonly IntPtr RT_GROUP_ICON = (IntPtr)14;
  static readonly IntPtr RT_VERSION = (IntPtr)16;

  [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
  static extern IntPtr LoadLibraryEx(string file, IntPtr reserved, uint flags);
  [DllImport("kernel32.dll")] static extern bool FreeLibrary(IntPtr module);
  delegate bool EnumNameProc(IntPtr module, IntPtr type, IntPtr name, IntPtr param);
  delegate bool EnumLangProc(IntPtr module, IntPtr type, IntPtr name, ushort lang, IntPtr param);
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
  static extern bool EnumResourceNames(IntPtr module, IntPtr type, EnumNameProc cb, IntPtr param);
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
  static extern bool EnumResourceLanguages(IntPtr module, IntPtr type, IntPtr name, EnumLangProc cb, IntPtr param);
  [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
  static extern IntPtr BeginUpdateResource(string file, bool deleteExisting);
  [DllImport("kernel32.dll", SetLastError = true, EntryPoint = "UpdateResourceW")]
  static extern bool UpdateResourceId(IntPtr h, IntPtr type, IntPtr name, ushort lang, byte[] data, uint size);
  [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "UpdateResourceW")]
  static extern bool UpdateResourceStr(IntPtr h, IntPtr type, string name, ushort lang, byte[] data, uint size);
  [DllImport("kernel32.dll", SetLastError = true)]
  static extern bool EndUpdateResource(IntPtr h, bool discard);

  class Res { public IntPtr Type; public bool IsId; public IntPtr Id; public string Name; public ushort Lang; }

  static List<Res> Existing(string exe, IntPtr[] types) {
    var list = new List<Res>();
    IntPtr module = LoadLibraryEx(exe, IntPtr.Zero, LOAD_LIBRARY_AS_DATAFILE);
    if (module == IntPtr.Zero) throw new Exception("LoadLibraryEx failed: " + Marshal.GetLastWin32Error());
    try {
      foreach (IntPtr type in types) {
        EnumResourceNames(module, type, (m, t, name, p) => {
          bool isId = ((ulong)name.ToInt64() >> 16) == 0;
          string str = isId ? null : Marshal.PtrToStringUni(name);
          EnumResourceLanguages(m, t, name, (m2, t2, n2, lang, p2) => {
            list.Add(new Res { Type = t, IsId = isId, Id = name, Name = str, Lang = lang });
            return true;
          }, IntPtr.Zero);
          return true;
        }, IntPtr.Zero);
      }
    } finally { FreeLibrary(module); }
    return list;
  }

  public static void Apply(string exe, string ico) {
    byte[] b = File.ReadAllBytes(ico);
    int count = BitConverter.ToUInt16(b, 4);
    var existing = Existing(exe, new[] { RT_GROUP_ICON, RT_ICON });
    ushort lang = 0x0409;
    foreach (var r in existing) if (r.Type == RT_GROUP_ICON) { lang = r.Lang; break; }

    IntPtr h = BeginUpdateResource(exe, false);
    if (h == IntPtr.Zero) throw new Exception("BeginUpdateResource failed: " + Marshal.GetLastWin32Error());
    bool ok = false;
    try {
      foreach (var r in existing) {
        bool done = r.IsId ? UpdateResourceId(h, r.Type, r.Id, r.Lang, null, 0)
                           : UpdateResourceStr(h, r.Type, r.Name, r.Lang, null, 0);
        if (!done) throw new Exception("Removing an old icon failed: " + Marshal.GetLastWin32Error());
      }
      var group = new MemoryStream();
      var w = new BinaryWriter(group);
      w.Write((ushort)0); w.Write((ushort)1); w.Write((ushort)count);
      for (int i = 0; i < count; i++) {
        int o = 6 + 16 * i;
        int size = BitConverter.ToInt32(b, o + 8);
        int offset = BitConverter.ToInt32(b, o + 12);
        byte[] frame = new byte[size];
        Array.Copy(b, offset, frame, 0, size);
        ushort id = (ushort)(i + 1);
        if (!UpdateResourceId(h, RT_ICON, (IntPtr)id, lang, frame, (uint)size))
          throw new Exception("Adding an icon frame failed: " + Marshal.GetLastWin32Error());
        w.Write(b, o, 8);          // width, height, colors, reserved, planes, bpp
        w.Write((uint)size);
        w.Write(id);
      }
      byte[] dir = group.ToArray();
      if (!UpdateResourceId(h, RT_GROUP_ICON, (IntPtr)1, lang, dir, (uint)dir.Length))
        throw new Exception("Adding the icon group failed: " + Marshal.GetLastWin32Error());
      ok = true;
    } finally {
      if (!EndUpdateResource(h, !ok) && ok) throw new Exception("EndUpdateResource failed: " + Marshal.GetLastWin32Error());
    }
  }

  // --- Version resource ---------------------------------------------------
  // Builds one VS_VERSIONINFO-style node (shared shape for VS_VERSION_INFO,
  // StringFileInfo, StringTable, String, VarFileInfo and Var). `value` is the
  // raw Value payload (or null); `children` are already-built child nodes.
  // The returned array's length always equals the node's own wLength -- a
  // parent pads BETWEEN children (never after the last one) when nesting.
  static byte[] BuildVersionNode(ushort wType, string key, byte[] value, ushort wValueLengthField, byte[][] children) {
    using (var ms = new MemoryStream())
    using (var w = new BinaryWriter(ms)) {
      w.Write((ushort)0); // wLength placeholder, patched below
      w.Write(wValueLengthField);
      w.Write(wType);
      foreach (char c in key) w.Write((ushort)c);
      w.Write((ushort)0); // key NUL terminator
      while (ms.Position % 4 != 0) w.Write((byte)0);

      if (value != null && value.Length > 0) {
        w.Write(value);
        if (children != null && children.Length > 0)
          while (ms.Position % 4 != 0) w.Write((byte)0);
      }

      if (children != null) {
        for (int i = 0; i < children.Length; i++) {
          w.Write(children[i]);
          if (i < children.Length - 1)
            while (ms.Position % 4 != 0) w.Write((byte)0);
        }
      }

      w.Flush();
      byte[] bytes = ms.ToArray();
      ushort len = (ushort)bytes.Length;
      bytes[0] = (byte)(len & 0xFF);
      bytes[1] = (byte)(len >> 8);
      return bytes;
    }
  }

  static byte[] BuildFixedFileInfo(ushort major, ushort minor, ushort patch, ushort build) {
    using (var ms = new MemoryStream())
    using (var w = new BinaryWriter(ms)) {
      uint verMS = ((uint)major << 16) | minor;
      uint verLS = ((uint)patch << 16) | build;
      w.Write((uint)0xFEEF04BD); // dwSignature
      w.Write((uint)0x00010000); // dwStrucVersion (1.0)
      w.Write(verMS);            // dwFileVersionMS
      w.Write(verLS);            // dwFileVersionLS
      w.Write(verMS);            // dwProductVersionMS
      w.Write(verLS);            // dwProductVersionLS
      w.Write((uint)0x3F);       // dwFileFlagsMask
      w.Write((uint)0x0);        // dwFileFlags
      w.Write((uint)0x00040004); // dwFileOS = VOS_NT_WINDOWS32
      w.Write((uint)0x1);        // dwFileType = VFT_APP
      w.Write((uint)0x0);        // dwFileSubtype
      w.Write((uint)0x0);        // dwFileDateMS
      w.Write((uint)0x0);        // dwFileDateLS
      return ms.ToArray();       // 52 bytes
    }
  }

  static byte[] BuildVersionResource(
      string fileDescription, string productName, string fileVersion, string productVersion,
      string internalName, string originalFilename,
      ushort verMajor, ushort verMinor, ushort verPatch, ushort verBuild,
      ushort langId) {

    ushort codepage = 0x04B0; // 1200 decimal = Unicode
    byte[] fixedInfo = BuildFixedFileInfo(verMajor, verMinor, verPatch, verBuild);

    Func<string, string, byte[]> buildString = (key, val) => {
      byte[] valBytes = Encoding.Unicode.GetBytes(val + "\0");
      ushort wValueLength = (ushort)(val.Length + 1); // WCHARs including NUL
      return BuildVersionNode(1, key, valBytes, wValueLength, null);
    };

    var strings = new[] {
      buildString("FileDescription", fileDescription),
      buildString("FileVersion", fileVersion),
      buildString("InternalName", internalName),
      buildString("OriginalFilename", originalFilename),
      buildString("ProductName", productName),
      buildString("ProductVersion", productVersion),
    };

    string tableKey = langId.ToString("X4") + codepage.ToString("X4"); // e.g. "040904B0"
    byte[] stringTable = BuildVersionNode(1, tableKey, null, 0, strings);
    byte[] stringFileInfo = BuildVersionNode(1, "StringFileInfo", null, 0, new[] { stringTable });

    byte[] translation = new byte[4];
    translation[0] = (byte)(langId & 0xFF);
    translation[1] = (byte)(langId >> 8);
    translation[2] = (byte)(codepage & 0xFF);
    translation[3] = (byte)(codepage >> 8);
    byte[] varEntry = BuildVersionNode(0, "Translation", translation, 4, null);
    byte[] varFileInfo = BuildVersionNode(1, "VarFileInfo", null, 0, new[] { varEntry });

    return BuildVersionNode(0, "VS_VERSION_INFO", fixedInfo, (ushort)fixedInfo.Length,
        new[] { stringFileInfo, varFileInfo });
  }

  public static void ApplyVersion(string exe,
      string fileDescription, string productName, string fileVersion, string productVersion,
      string internalName, string originalFilename,
      ushort verMajor, ushort verMinor, ushort verPatch, ushort verBuild) {

    var existing = Existing(exe, new[] { RT_VERSION });
    ushort lang = 0x0409;
    foreach (var r in existing) if (r.Type == RT_VERSION) { lang = r.Lang; break; }

    byte[] blob = BuildVersionResource(fileDescription, productName, fileVersion, productVersion,
        internalName, originalFilename, verMajor, verMinor, verPatch, verBuild, lang);

    IntPtr h = BeginUpdateResource(exe, false);
    if (h == IntPtr.Zero) throw new Exception("BeginUpdateResource failed: " + Marshal.GetLastWin32Error());
    bool ok = false;
    try {
      foreach (var r in existing) {
        bool done = r.IsId ? UpdateResourceId(h, r.Type, r.Id, r.Lang, null, 0)
                           : UpdateResourceStr(h, r.Type, r.Name, r.Lang, null, 0);
        if (!done) throw new Exception("Removing an old version resource failed: " + Marshal.GetLastWin32Error());
      }
      if (!UpdateResourceId(h, RT_VERSION, (IntPtr)1, lang, blob, (uint)blob.Length))
        throw new Exception("Adding the version resource failed: " + Marshal.GetLastWin32Error());
      ok = true;
    } finally {
      if (!EndUpdateResource(h, !ok) && ok) throw new Exception("EndUpdateResource failed: " + Marshal.GetLastWin32Error());
    }
  }
}
'@

Step "Building $exeName"
# The icon and version resource must be patched before game.love is
# appended: rewriting resources would drop the appended archive.
$baseExe = Join-Path $buildDir 'love-base.exe'
Copy-Item (Join-Path $loveDir 'love.exe') $baseExe
[CardTableIconPatcher]::Apply($baseExe, (Join-Path $root 'assets\icon.ico'))

$verTag = "$($v.Name)+$($v.Build)"
$verParts = $v.Name.Split('.')
[CardTableIconPatcher]::ApplyVersion(
  $baseExe,
  'CardTable', 'CardTable',
  $verTag, $verTag,
  $exeName, $exeName,
  [uint16]$verParts[0], [uint16]$verParts[1], [uint16]$verParts[2], [uint16]$v.Build
)

$exePath = Join-Path $outDir $exeName
$out = [IO.File]::Create($exePath)
try {
  foreach ($part in @($baseExe, $lovePath)) {
    $in = [IO.File]::OpenRead($part)
    try { $in.CopyTo($out) } finally { $in.Dispose() }
  }
} finally { $out.Dispose() }
Remove-Item $baseExe

# --- Runtime files -----------------------------------------------------------
Step 'Copying runtime files'
foreach ($dll in @('love.dll', 'lua51.dll', 'SDL2.dll', 'OpenAL32.dll', 'mpg123.dll', 'msvcp120.dll', 'msvcr120.dll')) {
  Copy-Item (Join-Path $loveDir $dll) $outDir
}
Copy-Item (Join-Path $loveDir 'license.txt') (Join-Path $outDir 'LOVE-license.txt')
foreach ($f in @('discord_partner_sdk.dll', 'libwebp-7.dll', 'libsharpyuv-0.dll', 'LICENSE', 'CONTROLS.md', 'SUPPORT-ME.md')) {
  $p = Join-Path $root $f
  if (-not (Test-Path $p)) { throw "Missing $f in the project folder." }
  Copy-Item $p $outDir
}

# --- Release zip -------------------------------------------------------------
Step "Creating $assetName"
$zipPath = Join-Path $buildDir $assetName
New-Zip $zipPath $outDir (Get-ChildItem $outDir -File | ForEach-Object { $_.Name })
$mb = [math]::Round((Get-Item $zipPath).Length / 1MB, 1)
Step "Built $exePath"
Step "Built $zipPath ($mb MB)"

# --- Publish -----------------------------------------------------------------
if ($Publish) {
  $gh = (Get-Command gh -ErrorAction SilentlyContinue).Source
  if (-not $gh) { $gh = "$env:ProgramFiles\GitHub CLI\gh.exe" }
  $branch = (git -C $root rev-parse --abbrev-ref HEAD).Trim()
  Step "Committing version bump on $branch"
  git -C $root add src/version.lua
  git -C $root commit -m "Release $tag"
  if ($LASTEXITCODE -ne 0) { throw 'git commit failed.' }
  git -C $root push
  if ($LASTEXITCODE -ne 0) { throw 'git push failed.' }
  Step "Creating GitHub Release $tag on $($v.Repo)"
  & $gh release create $tag $zipPath --repo $v.Repo --target $branch --title $tag --generate-notes
  if ($LASTEXITCODE -ne 0) { throw 'gh release create failed.' }
  Step "Published $tag"
}
