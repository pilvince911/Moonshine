#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$engine=Join-Path $root 'overlay\tools\moonshine'
if (-not (Test-Path -LiteralPath $engine)) { $engine=Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'tools\moonshine' }
$temporary=Join-Path $env:TEMP ('moonshine-engine-validation-'+[guid]::NewGuid().ToString('N'))
try {
    foreach ($file in @(Get-ChildItem -LiteralPath $engine -Filter '*.ps1')) {
        $tokens=$null;$parseErrors=$null
        $null=[Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$parseErrors)
        if ($parseErrors.Count) { throw ($file.Name+': '+(($parseErrors | ForEach-Object { 'line '+$_.Extent.StartLineNumber+': '+$_.Message }) -join '; ')) }
    }
    . (Join-Path $engine 'VibeShine-Xbox.ps1') -FunctionsOnly
    $script:Data=$temporary;$script:Runtime=Join-Path $temporary 'versions\0.8.0'
    $script:GuiBridge=$null;$script:EmbeddedCancel=$null;$script:SelfTestStatus='running'
    $count=Invoke-SelfTests
    $script:SelfTestStatus='passed'
    Write-Output ('Moonshine embedded engine: '+$count+' autotests passed; synthetic data only.')
} finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force } }
