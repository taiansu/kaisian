# Pester 5 tests for setup.ps1. Windows operations are mocked, so the suite also
# runs under PowerShell 7 on Linux/macOS:
#   pwsh -c 'Invoke-Pester tests/setup.Tests.ps1 -Output Detailed'
BeforeAll {
  $env:KAISIAN_TESTING = '1'
  . (Join-Path $PSScriptRoot '..' 'setup.ps1')
}

AfterAll {
  Remove-Item Env:KAISIAN_TESTING -ErrorAction SilentlyContinue
}

Describe 'Get-WslProfileGuid' {
  It 'matches the Windows Terminal documentation vector for Ubuntu' {
    Get-WslProfileGuid 'Ubuntu' | Should -Be '{2c4de342-38b7-51cf-b940-2309a097f518}'
  }

  It 'hashes the UTF-16LE distro name for other distributions' {
    # Python: uuid.uuid5(ns, "Ubuntu-24.04".encode("UTF-16LE").decode("ASCII"))
    Get-WslProfileGuid 'Ubuntu-24.04' | Should -Be '{963ff2f7-6aed-5ce3-9d91-90d99571f53a}'
  }
}

Describe 'Get-TerminalFragmentJson' {
  It 'updates the distro profile font only' {
    $fragment = Get-TerminalFragmentJson 'Ubuntu' 'SauceCodePro NFM' | ConvertFrom-Json
    @($fragment.profiles).Count | Should -Be 1
    $fragment.profiles[0].updates | Should -Be '{2c4de342-38b7-51cf-b940-2309a097f518}'
    $fragment.profiles[0].font.face | Should -Be 'SauceCodePro NFM'
    @($fragment.PSObject.Properties.Name) | Should -Be @('profiles')
  }
}

Describe 'Get-KaisianLanguage' {
  It 'reads <arguments> as <expected>' -ForEach @(
    @{ arguments = @('--yes', '--lang', 'zh-TW'); expected = 'zh-TW' }
    @{ arguments = @('--lang=zh-TW', '--yes'); expected = 'zh-TW' }
    @{ arguments = @('--yes'); expected = 'en' }
    @{ arguments = @('--lang', 'fr'); expected = 'en' }
    @{ arguments = @('--lang'); expected = 'en' }
  ) {
    Get-KaisianLanguage $arguments | Should -Be $expected
  }
}

Describe 'Get-KaisianInputProblem' {
  It 'accepts no font or a valid pair' {
    Get-KaisianInputProblem -NerdFont '' -FontFamily '' | Should -BeNullOrEmpty
    Get-KaisianInputProblem -NerdFont 'IBMPlexMono' -FontFamily 'BlexMono NFM' | Should -BeNullOrEmpty
  }

  It 'rejects asset names that could leave the release URL: <name>' -ForEach @(
    @{ name = '../evil' }
    @{ name = 'Source Code' }
    @{ name = 'a/b' }
    @{ name = 'Fira%2F' }
  ) {
    Get-KaisianInputProblem -NerdFont $name -FontFamily 'X' | Should -Be 'invalid_nerd_font'
  }

  It 'requires -NerdFont and -FontFamily together' {
    Get-KaisianInputProblem -NerdFont 'FiraCode' -FontFamily '' | Should -Be 'font_pair_required'
    Get-KaisianInputProblem -NerdFont '' -FontFamily 'FiraCode NFM' | Should -Be 'font_pair_required'
  }
}

Describe 'Invoke-Kaisian' {
  BeforeEach {
    $script:Calls = [System.Collections.Generic.List[string]]::new()
    $script:SetupExit = 0
    $script:WingetExit = 0
    $script:Distros = @('Ubuntu')
    $script:TerminalInstalled = $true
    $script:ForwardedArgs = $null

    Mock Write-Host {}
    Mock Get-WindowsBuild { 26100 }
    Mock Get-WslDistro { $script:Distros }
    Mock Install-WslDistro { $script:Calls.Add('install-wsl'); 0 }
    Mock Test-FontFamilyInstalled { $false }
    Mock Install-NerdFont { $script:Calls.Add("font:$Name") }
    Mock Test-WindowsTerminalInstalled { $script:TerminalInstalled }
    Mock Test-Winget { $true }
    Mock Invoke-Winget { $script:Calls.Add("winget:$($Arguments[0])"); $global:LASTEXITCODE = $script:WingetExit }
    Mock Get-TerminalFragmentPath { 'C:\Users\t\AppData\Local\Microsoft\Windows Terminal\Fragments\kaisian\kaisian.json' }
    Mock Write-TerminalFragment { $script:Calls.Add('fragment') }
    Mock Set-DefaultTerminal { $script:Calls.Add('default-terminal') }
    Mock Invoke-WslSetup { $script:Calls.Add('setup'); $script:ForwardedArgs = $Arguments; $global:LASTEXITCODE = $script:SetupExit }
  }

  It 'upgrades a preinstalled Windows Terminal only after setup.sh succeeds' {
    Invoke-Kaisian -NerdFont 'FiraCode' -FontFamily 'FiraCode NFM' -SetupArgs @('--yes')
    $LASTEXITCODE | Should -Be 0
    @($script:Calls) | Should -Be @('font:FiraCode', 'fragment', 'default-terminal', 'setup', 'winget:upgrade')
  }

  It 'treats "no applicable upgrade" from winget as success' {
    $script:WingetExit = -1978335189
    Invoke-Kaisian -SetupArgs @('--yes')
    $LASTEXITCODE | Should -Be 0
  }

  It 'does not upgrade and returns the setup.sh exit code when setup.sh fails' {
    $script:SetupExit = 7
    Invoke-Kaisian -SetupArgs @('--yes')
    $LASTEXITCODE | Should -Be 7
    $script:Calls | Should -Not -Contain 'winget:upgrade'
  }

  It 'skips the upgrade with -SkipTerminalUpgrade' {
    Invoke-Kaisian -SkipTerminalUpgrade -SetupArgs @('--yes')
    $LASTEXITCODE | Should -Be 0
    $script:Calls | Should -Not -Contain 'winget:upgrade'
  }

  It 'installs a missing Windows Terminal before setup and does not upgrade it afterwards' {
    $script:TerminalInstalled = $false
    Invoke-Kaisian -SetupArgs @('--yes')
    $LASTEXITCODE | Should -Be 0
    @($script:Calls) | Should -Be @('winget:install', 'default-terminal', 'setup')
  }

  It 'fails before setup when Windows Terminal is missing and winget is unavailable' {
    $script:TerminalInstalled = $false
    Mock Test-Winget { $false }
    Invoke-Kaisian -SetupArgs @('--yes')
    $LASTEXITCODE | Should -Be 1
    $script:Calls | Should -Not -Contain 'setup'
  }

  It 'keeps the current default terminal with -KeepDefaultTerminal' {
    Invoke-Kaisian -KeepDefaultTerminal -SetupArgs @('--yes')
    $script:Calls | Should -Not -Contain 'default-terminal'
  }

  It 'skips font download when the family is already installed' {
    Mock Test-FontFamilyInstalled { $true }
    Invoke-Kaisian -NerdFont 'FiraCode' -FontFamily 'FiraCode NFM' -SetupArgs @('--yes')
    $script:Calls | Should -Not -Contain 'font:FiraCode'
    $script:Calls | Should -Contain 'fragment'
  }

  It 'changes nothing on Windows during --dry-run but still forwards to setup.sh' {
    Invoke-Kaisian -NerdFont 'FiraCode' -FontFamily 'FiraCode NFM' -SetupArgs @('--yes', '--dry-run')
    $LASTEXITCODE | Should -Be 0
    @($script:Calls) | Should -Be @('setup')
    $script:ForwardedArgs | Should -Contain '--dry-run'
  }

  It 'forwards setup.sh arguments unchanged and in order' {
    $forward = @('--yes', '--prompt', 'prompt-pure', '--brew', 'ripgrep,fzf', '--lang', 'zh-TW')
    Invoke-Kaisian -SetupArgs $forward
    $script:ForwardedArgs | Should -Be $forward
  }

  It 'installs WSL and stops when the distro is missing' {
    $script:Distros = @('Debian')
    Invoke-Kaisian -SetupArgs @('--yes')
    $LASTEXITCODE | Should -Be 0
    @($script:Calls) | Should -Be @('install-wsl')
  }

  It 'only reports the WSL installation during --dry-run' {
    $script:Distros = $null
    Invoke-Kaisian -SetupArgs @('--dry-run')
    $LASTEXITCODE | Should -Be 0
    $script:Calls.Count | Should -Be 0
  }

  It 'refuses Windows 10 before touching anything' {
    Mock Get-WindowsBuild { 19045 }
    Invoke-Kaisian -NerdFont 'FiraCode' -FontFamily 'FiraCode NFM' -SetupArgs @('--yes')
    $LASTEXITCODE | Should -Be 1
    $script:Calls.Count | Should -Be 0
  }

  It 'rejects invalid font input before touching anything' {
    Invoke-Kaisian -NerdFont '../x' -FontFamily 'X' -SetupArgs @('--yes')
    $LASTEXITCODE | Should -Be 2
    $script:Calls.Count | Should -Be 0
  }
}

Describe 'script parameters' {
  It 'binds named options and collects everything after -- for setup.sh' {
    $source = Get-Content -Raw (Join-Path $PSScriptRoot '..' 'setup.ps1')
    $probe = [scriptblock]::Create(($source -replace '(?s)\r?\nif \(\$env:KAISIAN_TESTING -ne ''1''\).*$', '') + "`n[pscustomobject]@{ NerdFont = `$NerdFont; FontFamily = `$FontFamily; Skip = [bool]`$SkipTerminalUpgrade; Distro = `$Distro; SetupArgs = `$SetupArgs }")
    $bound = & $probe -NerdFont 'SourceCodePro' -FontFamily 'SauceCodePro NFM' -SkipTerminalUpgrade -- --yes --brew 'ripgrep,fzf' --lang zh-TW
    $bound.NerdFont | Should -Be 'SourceCodePro'
    $bound.FontFamily | Should -Be 'SauceCodePro NFM'
    $bound.Skip | Should -BeTrue
    $bound.Distro | Should -Be 'Ubuntu'
    $bound.SetupArgs | Should -Be @('--yes', '--brew', 'ripgrep,fzf', '--lang', 'zh-TW')
  }
}
