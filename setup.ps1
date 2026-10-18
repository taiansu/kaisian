# kaisian for Windows 11: prepares the Windows side (WSL, font, Windows Terminal),
# then runs setup.sh inside WSL with every argument given after `--`.
#
#   & ([scriptblock]::Create((irm https://kaisian.phx.tw/win))) -NerdFont SourceCodePro -FontFamily 'SauceCodePro NFM' -- --yes --lang en
#
# Runs under Windows PowerShell 5.1 and PowerShell 7. It never calls `exit`, so a
# failure does not close the window that ran it; $LASTEXITCODE carries the result.
[CmdletBinding(PositionalBinding = $false)]
param(
  [string]$NerdFont = '',
  [string]$FontFamily = '',
  [switch]$SkipTerminalUpgrade,
  [switch]$KeepDefaultTerminal,
  [string]$Distro = 'Ubuntu',
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$SetupArgs = @()
)

Set-StrictMode -Version 2.0

$script:KaisianSetupUrl = 'https://kaisian.phx.tw'
$script:MinimumWindowsBuild = 22000
$script:NerdFontsDownloadBase = 'https://github.com/ryanoasis/nerd-fonts/releases/latest/download'
# Windows Terminal derives dynamic WSL profile GUIDs from this namespace:
# https://learn.microsoft.com/en-us/windows/terminal/json-fragment-extensions
$script:TerminalProfileNamespace = '2bde4a90-d05f-401c-9492-e40884ead1d8'
# "Windows Terminal" default-terminal values for HKCU\Console\%%Startup:
# https://learn.microsoft.com/en-us/windows/terminal/group-policy
$script:DelegationConsole = '{2EACA947-7F5F-4CFA-BA87-8F7FBEEFBE69}'
$script:DelegationTerminal = '{E12CFF52-A866-4C77-9A90-F570A7AA2C6B}'
# winget return codes: https://github.com/microsoft/winget-cli/blob/master/doc/windows/package-manager/winget/returnCodes.md
$script:WingetUpdateNotApplicable = -1978335189
$script:WingetAlreadyInstalled = -1978335135

$script:Messages = @{
  'en' = @{
    invalid_nerd_font = "Invalid -NerdFont '{0}': use a Nerd Fonts release name made of ASCII letters and digits."
    font_pair_required = '-NerdFont and -FontFamily must be given together.'
    requires_windows11 = 'kaisian requires Windows 11 (build {0} or later); this is build {1}.'
    would_install_wsl = 'Would install WSL with the {0} distribution (administrator approval required), then stop until you re-run this command.'
    installing_wsl = 'Installing WSL with the {0} distribution; approve the administrator prompt...'
    wsl_install_failed = 'WSL installation failed (exit code {0}).'
    wsl_next_steps = "WSL is installing. Restart Windows if asked, open '{0}' from the Start menu once to create your Linux user, then run this same command again."
    font_present = 'Font {0} is already installed.'
    would_install_font = 'Would download Nerd Font {0} and install it for the current user.'
    installing_font = 'Installing Nerd Font {0} for the current user...'
    font_install_failed = 'Font installation failed: {0}'
    winget_missing = 'winget (App Installer) is required to install or upgrade Windows Terminal.'
    would_install_terminal = 'Would install Windows Terminal with winget.'
    installing_terminal = 'Installing Windows Terminal...'
    terminal_install_failed = 'Windows Terminal installation failed (winget exit code {0}).'
    would_write_fragment = 'Would set the {0} profile font to {1} with a Windows Terminal fragment at {2}.'
    fragment_written = 'Windows Terminal will use {1} for the {0} profile ({2}).'
    fragment_failed = 'Writing the Windows Terminal fragment failed: {0}'
    would_set_default_terminal = 'Would make Windows Terminal the default terminal application.'
    default_terminal_set = 'Windows Terminal is now the default terminal application.'
    default_terminal_failed = 'Setting the default terminal failed: {0}'
    running_setup = 'Running kaisian inside WSL ({0})...'
    setup_failed = 'kaisian failed inside WSL (exit code {0}); Windows Terminal was not upgraded.'
    would_upgrade_terminal = 'Would upgrade Windows Terminal with winget as the last step.'
    upgrade_may_close = 'Setup has finished. Upgrading Windows Terminal now may close this window.'
    upgrading_terminal = 'Upgrading Windows Terminal...'
    terminal_upgrade_failed = 'Windows Terminal upgrade failed (winget exit code {0}).'
    done = 'kaisian finished.'
  }
  'zh-TW' = @{
    invalid_nerd_font = '無效的 -NerdFont「{0}」：請使用只含英文字母與數字的 Nerd Fonts 發行檔名。'
    font_pair_required = '-NerdFont 與 -FontFamily 必須一起指定。'
    requires_windows11 = 'kaisian 需要 Windows 11（組建 {0} 以上）；目前是組建 {1}。'
    would_install_wsl = '將會安裝 WSL 與 {0} 發行版（需要系統管理員核准），然後停止，等你重新執行這行指令。'
    installing_wsl = '正在安裝 WSL 與 {0} 發行版，請核准系統管理員提示…'
    wsl_install_failed = 'WSL 安裝失敗（結束代碼 {0}）。'
    wsl_next_steps = 'WSL 安裝中。若系統要求就重新啟動 Windows，從開始功能表開啟「{0}」一次以建立 Linux 使用者，然後再執行同一行指令。'
    font_present = '字型 {0} 已安裝。'
    would_install_font = '將會下載 Nerd Font {0} 並為目前使用者安裝。'
    installing_font = '正在為目前使用者安裝 Nerd Font {0}…'
    font_install_failed = '字型安裝失敗：{0}'
    winget_missing = '安裝或升級 Windows Terminal 需要 winget（應用程式安裝程式）。'
    would_install_terminal = '將會用 winget 安裝 Windows Terminal。'
    installing_terminal = '正在安裝 Windows Terminal…'
    terminal_install_failed = 'Windows Terminal 安裝失敗（winget 結束代碼 {0}）。'
    would_write_fragment = '將會以 Windows Terminal fragment（{2}）把 {0} 設定檔的字型設為 {1}。'
    fragment_written = 'Windows Terminal 的 {0} 設定檔將使用 {1}（{2}）。'
    fragment_failed = '寫入 Windows Terminal fragment 失敗：{0}'
    would_set_default_terminal = '將會把 Windows Terminal 設為預設終端機應用程式。'
    default_terminal_set = 'Windows Terminal 已設為預設終端機應用程式。'
    default_terminal_failed = '設定預設終端機失敗：{0}'
    running_setup = '正在 WSL（{0}）中執行 kaisian…'
    setup_failed = 'kaisian 在 WSL 中執行失敗（結束代碼 {0}）；未升級 Windows Terminal。'
    would_upgrade_terminal = '最後一步將會用 winget 升級 Windows Terminal。'
    upgrade_may_close = '安裝已完成。現在升級 Windows Terminal 可能會關閉這個視窗。'
    upgrading_terminal = '正在升級 Windows Terminal…'
    terminal_upgrade_failed = 'Windows Terminal 升級失敗（winget 結束代碼 {0}）。'
    done = 'kaisian 已完成。'
  }
}

# Reads the installer language from the forwarded setup.sh arguments.
function Get-KaisianLanguage {
  param([string[]]$Arguments)
  $lang = 'en'
  for ($i = 0; $i -lt $Arguments.Count; $i++) {
    $value = $null
    if ($Arguments[$i] -eq '--lang' -and $i + 1 -lt $Arguments.Count) {
      $value = $Arguments[$i + 1]
    } elseif ($Arguments[$i] -like '--lang=*') {
      $value = $Arguments[$i].Substring(7)
    }
    if ($value -ceq 'en' -or $value -ceq 'zh-TW') { $lang = $value }
  }
  return $lang
}

function Test-KaisianDryRun {
  param([string[]]$Arguments)
  return ($Arguments -contains '--dry-run')
}

function Format-KaisianMessage {
  param([string]$Lang, [string]$Key, [object[]]$Values = @())
  return ($script:Messages[$Lang][$Key] -f $Values)
}

# Returns the message key of the first invalid font argument, or $null.
function Get-KaisianInputProblem {
  param([string]$NerdFont, [string]$FontFamily)
  if (($NerdFont -eq '') -ne ($FontFamily -eq '')) { return 'font_pair_required' }
  if ($NerdFont -ne '' -and $NerdFont -cnotmatch '^[A-Za-z0-9]+$') { return 'invalid_nerd_font' }
  return $null
}

# UUIDv5 over the UTF-16LE profile name, as Windows Terminal generates the GUIDs
# of WSL profiles; Microsoft's test vector: Ubuntu -> {2c4de342-38b7-51cf-b940-2309a097f518}.
function Get-WslProfileGuid {
  param([string]$DistroName)
  $hex = $script:TerminalProfileNamespace -replace '-', ''
  $namespaceBytes = New-Object byte[] 16
  for ($i = 0; $i -lt 16; $i++) {
    $namespaceBytes[$i] = [Convert]::ToByte($hex.Substring($i * 2, 2), 16)
  }
  $nameBytes = [System.Text.Encoding]::Unicode.GetBytes($DistroName)
  $sha1 = [System.Security.Cryptography.SHA1]::Create()
  try {
    $hash = $sha1.ComputeHash([byte[]]($namespaceBytes + $nameBytes))
  } finally {
    $sha1.Dispose()
  }
  $hash[6] = ($hash[6] -band 0x0F) -bor 0x50
  $hash[8] = ($hash[8] -band 0x3F) -bor 0x80
  $h = (($hash[0..15] | ForEach-Object { $_.ToString('x2') }) -join '')
  return '{' + $h.Substring(0, 8) + '-' + $h.Substring(8, 4) + '-' + $h.Substring(12, 4) + '-' + $h.Substring(16, 4) + '-' + $h.Substring(20, 12) + '}'
}

function Get-TerminalFragmentJson {
  param([string]$DistroName, [string]$Family)
  $profileUpdate = [ordered]@{
    updates = (Get-WslProfileGuid $DistroName)
    font = [ordered]@{ face = $Family }
  }
  return (ConvertTo-Json -Depth 4 -InputObject ([ordered]@{ profiles = @($profileUpdate) }))
}

function Get-TerminalFragmentPath {
  return (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\Fragments\kaisian\kaisian.json')
}

# --- Windows operations; thin wrappers so tests can mock them. ---

function Get-WindowsBuild {
  return [Environment]::OSVersion.Version.Build
}

# Returns installed distribution names, or $null when WSL itself is missing.
function Get-WslDistro {
  $env:WSL_UTF8 = '1'
  $output = & wsl.exe --list --quiet 2>$null
  if ($LASTEXITCODE -ne 0) { return $null }
  # Older WSL builds ignore WSL_UTF8 and emit UTF-16; dropping NULs recovers the names.
  return @(($output -join "`n") -replace "`0", '' -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
}

function Install-WslDistro {
  param([string]$DistroName)
  $process = Start-Process -FilePath 'wsl.exe' -ArgumentList @('--install', '-d', $DistroName) -Verb RunAs -Wait -PassThru
  return $process.ExitCode
}

function Test-FontFamilyInstalled {
  param([string]$Family)
  try {
    Add-Type -AssemblyName System.Drawing
    $collection = New-Object System.Drawing.Text.InstalledFontCollection
    try {
      return (@($collection.Families | ForEach-Object { $_.Name }) -contains $Family)
    } finally {
      $collection.Dispose()
    }
  } catch {
    return $false
  }
}

# Installs the Mono variant (the NFM families) for the current user; no admin needed.
function Install-NerdFont {
  param([string]$Name)
  $ErrorActionPreference = 'Stop'
  # Windows PowerShell 5.1 may not offer TLS 1.2 to GitHub by default.
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  $work = Join-Path ([System.IO.Path]::GetTempPath()) ('kaisian-font-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $work | Out-Null
  try {
    $zip = Join-Path $work "$Name.zip"
    Invoke-WebRequest -Uri "$script:NerdFontsDownloadBase/$Name.zip" -OutFile $zip -UseBasicParsing
    Expand-Archive -Path $zip -DestinationPath (Join-Path $work 'files') -Force
    $files = @(Get-ChildItem -Path (Join-Path $work 'files') -Recurse -File | Where-Object { $_.Name -match 'NerdFontMono-.*\.(ttf|otf)$' })
    if ($files.Count -eq 0) { throw "no Nerd Font Mono files in $Name.zip" }
    $fontDir = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
    New-Item -ItemType Directory -Path $fontDir -Force | Out-Null
    $registryPath = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts'
    if (-not (Test-Path $registryPath)) { New-Item -Path $registryPath -Force | Out-Null }
    foreach ($file in $files) {
      $target = Join-Path $fontDir $file.Name
      Copy-Item -Path $file.FullName -Destination $target -Force
      $kind = 'TrueType'
      if ($file.Extension -eq '.otf') { $kind = 'OpenType' }
      Set-ItemProperty -Path $registryPath -Name "$($file.BaseName) ($kind)" -Value $target
    }
  } finally {
    Remove-Item -Path $work -Recurse -Force -ErrorAction SilentlyContinue
  }
}

function Test-WindowsTerminalInstalled {
  try {
    if (@(Get-AppxPackage -Name 'Microsoft.WindowsTerminal' -ErrorAction Stop).Count -gt 0) { return $true }
  } catch {
    # PowerShell 7 can fail to load the Appx module; the wt.exe alias still tells.
  }
  return ($null -ne (Get-Command 'wt.exe' -ErrorAction SilentlyContinue))
}

function Test-Winget {
  return ($null -ne (Get-Command 'winget.exe' -ErrorAction SilentlyContinue))
}

# Native commands run uncaptured so they keep the console (prompts, colors); callers
# read $LASTEXITCODE afterwards. Capturing their output would also turn it into
# the function's return value.
function Invoke-Winget {
  param([string[]]$Arguments)
  & winget.exe @Arguments
}

function Write-TerminalFragment {
  param([string]$Path, [string]$Json)
  $ErrorActionPreference = 'Stop'
  New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
  # Windows Terminal reads fragments as UTF-8; Windows PowerShell defaults to UTF-16.
  [System.IO.File]::WriteAllText($Path, $Json, (New-Object System.Text.UTF8Encoding $false))
}

function Set-DefaultTerminal {
  $ErrorActionPreference = 'Stop'
  $key = 'HKCU:\Console\%%Startup'
  if (-not (Test-Path -LiteralPath $key)) { New-Item -Path $key -Force | Out-Null }
  Set-ItemProperty -LiteralPath $key -Name 'DelegationConsole' -Value $script:DelegationConsole
  Set-ItemProperty -LiteralPath $key -Name 'DelegationTerminal' -Value $script:DelegationTerminal
}

# Runs setup.sh in WSL. --exec skips the login shell, so each argument reaches
# bash as its own argv entry. The bash script holds no quotes because Windows
# PowerShell 5.1 mangles embedded quotes in native arguments; an empty IFS and
# set -f keep the unquoted expansions from splitting or globbing.
function Invoke-WslSetup {
  param([string]$DistroName, [string]$Url, [string[]]$Arguments)
  $bashScript = 'set -f -o pipefail; IFS=; curl -fsSL $0 | bash -s -- $@'
  & wsl.exe -d $DistroName --exec bash -c $bashScript $Url @Arguments
}

# --- Orchestration ---

# Sets $global:LASTEXITCODE and writes nothing to the pipeline; call it uncaptured.
function Invoke-Kaisian {
  param(
    [string]$NerdFont = '',
    [string]$FontFamily = '',
    [switch]$SkipTerminalUpgrade,
    [switch]$KeepDefaultTerminal,
    [string]$Distro = 'Ubuntu',
    [string[]]$SetupArgs = @(),
    [string]$SetupUrl = $script:KaisianSetupUrl
  )
  $lang = Get-KaisianLanguage $SetupArgs
  $dryRun = Test-KaisianDryRun $SetupArgs
  $say = { param($Key, [object[]]$Values = @()) Write-Host (Format-KaisianMessage $lang $Key $Values) }
  $fail = { param($Key, [object[]]$Values = @()) Write-Host (Format-KaisianMessage $lang $Key $Values) -ForegroundColor Red }
  $global:LASTEXITCODE = 1

  $problem = Get-KaisianInputProblem -NerdFont $NerdFont -FontFamily $FontFamily
  if ($problem) { & $fail $problem @($NerdFont); $global:LASTEXITCODE = 2; return }

  $build = Get-WindowsBuild
  if ($build -lt $script:MinimumWindowsBuild) { & $fail 'requires_windows11' @($script:MinimumWindowsBuild, $build); $global:LASTEXITCODE = 1; return }

  $distros = Get-WslDistro
  if ($null -eq $distros -or $distros -notcontains $Distro) {
    if ($dryRun) { & $say 'would_install_wsl' @($Distro); $global:LASTEXITCODE = 0; return }
    & $say 'installing_wsl' @($Distro)
    $code = Install-WslDistro $Distro
    if ($code -ne 0) { & $fail 'wsl_install_failed' @($code); $global:LASTEXITCODE = 1; return }
    & $say 'wsl_next_steps' @($Distro)
    $global:LASTEXITCODE = 0
    return
  }

  if ($NerdFont -ne '') {
    if (Test-FontFamilyInstalled $FontFamily) {
      & $say 'font_present' @($FontFamily)
    } elseif ($dryRun) {
      & $say 'would_install_font' @($NerdFont)
    } else {
      & $say 'installing_font' @($NerdFont)
      try { Install-NerdFont $NerdFont } catch { & $fail 'font_install_failed' @($_.Exception.Message); $global:LASTEXITCODE = 1; return }
    }
  }

  $terminalPreinstalled = Test-WindowsTerminalInstalled
  if (-not $terminalPreinstalled) {
    if (-not (Test-Winget)) { & $fail 'winget_missing'; $global:LASTEXITCODE = 1; return }
    if ($dryRun) {
      & $say 'would_install_terminal'
    } else {
      & $say 'installing_terminal'
      Invoke-Winget @('install', '--id', 'Microsoft.WindowsTerminal', '--exact', '--source', 'winget', '--accept-package-agreements', '--accept-source-agreements')
      $code = $LASTEXITCODE
      if ($code -ne 0 -and $code -ne $script:WingetAlreadyInstalled) { & $fail 'terminal_install_failed' @($code); $global:LASTEXITCODE = 1; return }
    }
  }

  if ($FontFamily -ne '') {
    $fragmentPath = Get-TerminalFragmentPath
    if ($dryRun) {
      & $say 'would_write_fragment' @($Distro, $FontFamily, $fragmentPath)
    } else {
      try { Write-TerminalFragment -Path $fragmentPath -Json (Get-TerminalFragmentJson $Distro $FontFamily) } catch { & $fail 'fragment_failed' @($_.Exception.Message); $global:LASTEXITCODE = 1; return }
      & $say 'fragment_written' @($Distro, $FontFamily, $fragmentPath)
    }
  }

  if (-not $KeepDefaultTerminal) {
    if ($dryRun) {
      & $say 'would_set_default_terminal'
    } else {
      try { Set-DefaultTerminal } catch { & $fail 'default_terminal_failed' @($_.Exception.Message); $global:LASTEXITCODE = 1; return }
      & $say 'default_terminal_set'
    }
  }

  & $say 'running_setup' @($Distro)
  Invoke-WslSetup -DistroName $Distro -Url $SetupUrl -Arguments $SetupArgs
  $code = $LASTEXITCODE
  if ($code -ne 0) { & $fail 'setup_failed' @($code); $global:LASTEXITCODE = $code; return }

  # Last on purpose: upgrading the running Windows Terminal can close this window.
  if ($terminalPreinstalled -and -not $SkipTerminalUpgrade) {
    if ($dryRun) {
      & $say 'would_upgrade_terminal'
    } elseif (-not (Test-Winget)) {
      & $fail 'winget_missing'; $global:LASTEXITCODE = 1; return
    } else {
      if ($env:WT_SESSION) { Write-Host (Format-KaisianMessage $lang 'upgrade_may_close') -ForegroundColor Yellow }
      & $say 'upgrading_terminal'
      Invoke-Winget @('upgrade', '--id', 'Microsoft.WindowsTerminal', '--exact', '--source', 'winget', '--accept-package-agreements', '--accept-source-agreements')
      $code = $LASTEXITCODE
      if ($code -ne 0 -and $code -ne $script:WingetUpdateNotApplicable) { & $fail 'terminal_upgrade_failed' @($code); $global:LASTEXITCODE = 1; return }
    }
  }

  & $say 'done'
  $global:LASTEXITCODE = 0
}

if ($env:KAISIAN_TESTING -ne '1') {
  $setupUrl = $script:KaisianSetupUrl
  if ($env:KAISIAN_SETUP_URL) { $setupUrl = $env:KAISIAN_SETUP_URL }
  Invoke-Kaisian -NerdFont $NerdFont -FontFamily $FontFamily `
    -SkipTerminalUpgrade:$SkipTerminalUpgrade -KeepDefaultTerminal:$KeepDefaultTerminal `
    -Distro $Distro -SetupArgs $SetupArgs -SetupUrl $setupUrl
}
