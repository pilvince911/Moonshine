#Requires -Version 5.1
# SPDX-License-Identifier: GPL-3.0-only
param([Parameter(Mandatory=$true)][string]$OutputPath)
$ErrorActionPreference='Stop'
$source=Join-Path $PSScriptRoot 'Launcher.cs'
$icon=Join-Path (Split-Path -Parent $PSScriptRoot) 'moonshine-setup\Moonshine.ico'
$compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not [IO.File]::Exists($compiler)) { throw 'Le compilateur .NET Framework x64 est absent.' }
$output=[IO.Path]::GetFullPath($OutputPath)
[IO.Directory]::CreateDirectory((Split-Path -Parent $output)) | Out-Null
& $compiler /nologo /target:winexe /platform:x64 /optimize+ /reference:System.Windows.Forms.dll "/win32icon:$icon" "/out:$output" $source
if ($LASTEXITCODE -ne 0) { throw 'La compilation du lanceur graphique Moonshine a echoue.' }
$bytes=[IO.File]::ReadAllBytes($output)
$header=[BitConverter]::ToInt32($bytes,60)
if ([BitConverter]::ToUInt16($bytes,$header+4) -ne 0x8664 -or [BitConverter]::ToUInt16($bytes,$header+24+68) -ne 2) {
    throw 'Le lanceur doit etre un executable graphique Windows x64.'
}
