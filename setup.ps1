# gogo kit bootstrap for Windows (no admin rights needed).
#   $env:GOGO_PC_NAME='<pc name>'; irm https://raw.githubusercontent.com/subbyscenter/claude-gogo-kit/main/setup.ps1 | iex
# Optional env: GOGO_VAULT (vault folder), GOGO_KIT_DIR (default ~\claude-gogo-kit), GOGO_REPO, GOGO_BRANCH, GOGO_SKIP (e.g. obsidian-app)
# 1) Node.js LTS (portable, per-user) if missing  2) MinGit (portable) if git is missing
# 3) download or update the kit                   4) node gogo.mjs install  (Claude settings, skills, vault, caveman, Discord bot)
# ASCII only on purpose: Windows PowerShell 5.1 misreads UTF-8 scripts without a BOM.
& {
  $ErrorActionPreference = 'Stop'
  $ProgressPreference = 'SilentlyContinue'
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}   # node prints Korean as UTF-8

  $Repo   = if ($env:GOGO_REPO)    { $env:GOGO_REPO }    else { 'subbyscenter/claude-gogo-kit' }
  $Branch = if ($env:GOGO_BRANCH)  { $env:GOGO_BRANCH }  else { 'main' }
  $KitDir = if ($env:GOGO_KIT_DIR) { $env:GOGO_KIT_DIR } else { Join-Path $HOME 'claude-gogo-kit' }
  $Programs = Join-Path $env:LOCALAPPDATA 'Programs'
  $OriginalPath = $env:Path
  New-Item -ItemType Directory -Force -Path $Programs | Out-Null

  function Say($m) { Write-Host "[gogo] $m" }
  function Add-UserPath($dir) {
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (-not $user) { $user = '' }
    if (($user -split ';') -notcontains $dir) { [Environment]::SetEnvironmentVariable('Path', ($user.TrimEnd(';') + ';' + $dir).TrimStart(';'), 'User') }
    if (($env:Path -split ';') -notcontains $dir) { $env:Path = $dir + ';' + $env:Path }
  }
  function Expand-Zip($zip, $dest) {
    if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
    [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $dest)
  }
  function Node-Major {
    $n = Get-Command node -ErrorAction SilentlyContinue
    if (-not $n) { return 0 }
    try { return [int]((& $n.Source -v) -replace '^v(\d+).*', '$1') } catch { return 0 }
  }

  # 1) Node.js
  if ((Node-Major) -lt 18) {
    Say 'Node.js not found (or too old) -> installing portable LTS (per user, no admin)'
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
    $rel = (Invoke-RestMethod 'https://nodejs.org/dist/index.json') | Where-Object { $_.lts -and ($_.files -contains "win-$arch-zip") } | Select-Object -First 1
    $zip = Join-Path $env:TEMP "node-$($rel.version).zip"
    Invoke-WebRequest -UseBasicParsing "https://nodejs.org/dist/$($rel.version)/node-$($rel.version)-win-$arch.zip" -OutFile $zip
    $tmp = Join-Path $env:TEMP "gogo-node-$PID"
    Expand-Zip $zip $tmp
    $nodeDir = Join-Path $Programs 'nodejs'
    if (Test-Path $nodeDir) { Remove-Item -Recurse -Force $nodeDir }
    Move-Item (Get-ChildItem $tmp | Select-Object -First 1).FullName $nodeDir
    Remove-Item -Recurse -Force $tmp, $zip -ErrorAction SilentlyContinue
    Add-UserPath $nodeDir
    Say "Node.js $($rel.version) -> $nodeDir"
  }
  $node = (Get-Command node).Source
  # Claude Code (and its plugin hooks) may keep running with the PATH it started with. If no folder on that old PATH
  # has node.exe, hard-link node.exe into one that is already on it, so `node` works without restarting anything.
  $seen = $false
  foreach ($d in ($OriginalPath -split ';')) { if ($d -and (Test-Path (Join-Path $d 'node.exe'))) { $seen = $true; break } }
  if (-not $seen) {
    foreach ($d in @((Join-Path $HOME '.local\bin'), (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps'))) {
      if ((($OriginalPath -split ';') -contains $d) -and (Test-Path $d)) {
        try { New-Item -ItemType HardLink -Path (Join-Path $d 'node.exe') -Target $node -ErrorAction Stop | Out-Null; Say "node.exe linked into $d"; break }
        catch { try { Copy-Item $node (Join-Path $d 'node.exe') -Force; Say "node.exe copied into $d"; break } catch {} }
      }
    }
  }

  # 2) git (optional: used for kit updates and the caveman plugin; the kit also works from zip files)
  if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    try {
      Say 'git not found -> installing portable MinGit (per user, no admin)'
      $r = Invoke-RestMethod 'https://api.github.com/repos/git-for-windows/git/releases/latest' -Headers @{ 'User-Agent' = 'gogo-kit' }
      $a = $r.assets | Where-Object { $_.name -match '^MinGit-[\d.]+-64-bit\.zip$' } | Select-Object -First 1
      $zip = Join-Path $env:TEMP $a.name
      Invoke-WebRequest -UseBasicParsing $a.browser_download_url -OutFile $zip
      $gitDir = Join-Path $Programs 'MinGit'
      Expand-Zip $zip $gitDir
      Remove-Item $zip -ErrorAction SilentlyContinue
      Add-UserPath (Join-Path $gitDir 'cmd')
      Say "MinGit -> $gitDir"
    } catch { Say "MinGit install skipped: $($_.Exception.Message)" }
  }

  # 3) the kit
  $git = Get-Command git -ErrorAction SilentlyContinue
  if ($git -and (Test-Path (Join-Path $KitDir '.git'))) {
    Say "updating $KitDir"
    & $git.Source -C $KitDir pull --ff-only
  } elseif ($git -and -not (Test-Path $KitDir)) {
    Say "downloading kit -> $KitDir"
    & $git.Source clone --depth 1 -b $Branch "https://github.com/$Repo.git" $KitDir
  } else {
    Say "downloading kit (zip) -> $KitDir"
    $zip = Join-Path $env:TEMP "gogo-kit-$PID.zip"
    Invoke-WebRequest -UseBasicParsing "https://codeload.github.com/$Repo/zip/refs/heads/$Branch" -OutFile $zip
    $tmp = Join-Path $env:TEMP "gogo-kit-$PID"
    Expand-Zip $zip $tmp
    $src = (Get-ChildItem $tmp | Select-Object -First 1).FullName
    New-Item -ItemType Directory -Force -Path $KitDir | Out-Null
    Copy-Item -Path (Join-Path $src '*') -Destination $KitDir -Recurse -Force
    Remove-Item -Recurse -Force $tmp, $zip -ErrorAction SilentlyContinue
  }
  if (-not (Test-Path (Join-Path $KitDir 'gogo.mjs'))) { throw "kit download failed: $KitDir\gogo.mjs missing" }

  # 4) install (idempotent: running setup again = update + repair)
  $argv = @((Join-Path $KitDir 'gogo.mjs'), 'install')
  if ($env:GOGO_PC_NAME) { $argv += @('--pc-name', $env:GOGO_PC_NAME) }
  if ($env:GOGO_VAULT)   { $argv += @('--vault', $env:GOGO_VAULT) }
  if ($env:GOGO_SKIP)    { $argv += @('--skip', $env:GOGO_SKIP) }
  if ($env:GOGO_TEST_HOME) { $argv += @('--home', $env:GOGO_TEST_HOME) }   # tests: install into a fake user folder
  & $node @argv
}
