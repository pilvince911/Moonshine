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
    $script:Data=$temporary;$script:Runtime=Join-Path $temporary 'versions\0.8.1'
    $script:GuiBridge=$null;$script:EmbeddedCancel=$null;$script:SelfTestStatus='running'
    # Load the actual native logging adapter before the complete regression suite.
    # Parameter binding happens even when self-test messages are suppressed.
    function Import-AdapterFunction([string]$File,[string]$Name) {
        $tokens=$null;$errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile($File,[ref]$tokens,[ref]$errors)
        if ($errors.Count) { throw 'Adapter source could not be parsed.' }
        $definition=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name},$false)
        if (-not $definition) { throw ('Missing adapter function: '+$Name) }
        Set-Item -Path ('Function:script:'+ $Name) -Value ([scriptblock]::Create($definition.Body.Extent.Text.Substring(1,$definition.Body.Extent.Text.Length-2)))
    }
    $script:AdapterFrames=New-Object Collections.ArrayList
    function Emit-Moonshine([string]$Type,$Data) { $null=$script:AdapterFrames.Add(@{type=$Type;message=$Data.message}) }
    Import-AdapterFunction (Join-Path $engine 'Moonshine-Worker.ps1') 'Write-Host'
    $count=Invoke-SelfTests
    $script:SelfTestStatus='passed'
    Write-Output ('Moonshine embedded engine: '+$count+' autotests passed; synthetic data only.')
    $checks=0
    foreach ($adapter in @('Moonshine-Worker.ps1','GuiEngine.ps1')) {
        Import-AdapterFunction (Join-Path $engine $adapter) 'Write-Host'
        if ($adapter -eq 'GuiEngine.ps1') {
            Import-AdapterFunction (Join-Path $engine $adapter) 'Gui-Text'
            $script:GuiBridge=New-Object PSObject
            $script:GuiBridge | Add-Member -MemberType ScriptMethod -Name Publish -Value { param($Type,$Message,$Percent,$Payload) $null=$script:AdapterFrames.Add(@{type=$Type;message=$Message}) }
        }
        $script:SelfTestStatus='passed';$script:AdapterFrames.Clear()
        Write-Host 'Alpha Beta' -ForegroundColor Green -BackgroundColor DarkBlue
        if ($script:AdapterFrames.Count -ne 1 -or $script:AdapterFrames[0].message -cne 'Alpha Beta') { throw ($adapter+': named colours consumed the message.') };$checks++
        Write-Host 'Alpha' 'Beta' -ForegroundColor Cyan -Separator ' / ' -NoNewline
        if ($script:AdapterFrames.Count -ne 2 -or $script:AdapterFrames[1].message -cne 'Alpha / Beta') { throw ($adapter+': remaining message arguments were not joined.') };$checks++
        Write-Host @('One','Two') -BackgroundColor Black
        if ($script:AdapterFrames.Count -ne 3 -or $script:AdapterFrames[2].message -cne 'One Two') { throw ($adapter+': array message did not preserve its items.') };$checks++
        Write-Host '' -ForegroundColor Red
        if ($script:AdapterFrames.Count -ne 3) { throw ($adapter+': empty message created a log frame.') };$checks++
        $script:SelfTestStatus='running'
        Write-Host 'Suppressed self-test message' -ForegroundColor Yellow -BackgroundColor Black
        if ($script:AdapterFrames.Count -ne 3) { throw ($adapter+': suppressed self-test message reached the log.') };$checks++
    }
    $script:GuiBridge=$null;$script:SelfTestStatus='passed'
    Write-Output ('Moonshine native/desktop log adapters: '+$checks+' regression checks passed.')
} finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force } }
