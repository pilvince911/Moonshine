#Requires -Version 5.1
param([string]$Output='prerequisites',[string]$Evidence='build-evidence\prerequisites.json')
$ErrorActionPreference='Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:CI -ne 'true') { throw 'Payload preparation is restricted to a disposable CI runner.' }
$outputRoot=[IO.Path]::GetFullPath($Output)
if (Test-Path -LiteralPath $outputRoot) { throw 'Prerequisite output already exists.' }
$temporary=Join-Path $env:TEMP ('moonshine-prerequisites-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($temporary) | Out-Null
$database=$null
try {
    $installer=Join-Path $temporary 'VibeshineSetup-v2.0.1.exe'
    $url='https://github.com/Nonary/vibeshine/releases/download/2.0.1/VibeshineSetup-v2.0.1.exe'
    Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $installer
    $expected='b46abb8a778de59b33fa5fa853819c1144f548be0d3db487a704e505c5b64838'
    if ((Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash -ine $expected -or (Get-Item -LiteralPath $installer).Length -ne 45434664) { throw 'Pinned upstream installer bytes differ.' }
    # Reflection-only loading reads its resource without invoking the entry point.
    $assembly=[Reflection.Assembly]::ReflectionOnlyLoadFrom($installer)
    $stream=$assembly.GetManifestResourceStream('Payload.msi')
    if (-not $stream) { throw 'Pinned MSI resource missing.' }
    $msi=Join-Path $temporary 'payload.msi'
    try { $file=[IO.File]::Create($msi);try { $stream.CopyTo($file) } finally { $file.Dispose() } } finally { $stream.Dispose() }
    Add-Type -Path (Join-Path $PSScriptRoot 'Read-MsiPayload.cs')
    $database=New-Object MoonshineMsiReader($msi)
    $cabRoot=Join-Path $temporary 'cab';[IO.Directory]::CreateDirectory($cabRoot) | Out-Null
    $cabinets=$database.Query('SELECT `Cabinet` FROM `Media`',1)
    $index=0
    foreach ($cabinet in $cabinets) {
        if (-not $cabinet[0].StartsWith('#') -or $index -gt 30) { throw 'Only embedded reviewed cabinets are supported.' }
        $cab=Join-Path $temporary ('payload-'+$index+'.cab');$index++
        $database.ExtractStream($cabinet[0].Substring(1),$cab)
        & "$env:WINDIR\System32\expand.exe" '-F:*' $cab $cabRoot | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Read-only cabinet extraction failed.' }
    }
    $directories=@{};foreach ($row in $database.Query('SELECT `Directory`,`Directory_Parent`,`DefaultDir` FROM `Directory`',3)) { $directories[$row[0]]=@{parent=$row[1];name=(($row[2] -split ':')[0] -split '\|')[-1]} }
    $components=@{};foreach ($row in $database.Query('SELECT `Component`,`Directory_` FROM `Component`',2)) { $components[$row[0]]=$row[1] }
    function Directory-Path([string]$Key) {
        $parts=New-Object 'Collections.Generic.List[string]';$seen=@{}
        while ($Key) {
            if ($seen.ContainsKey($Key) -or -not $directories.ContainsKey($Key)) { throw 'Invalid MSI directory graph.' }
            $seen[$Key]=$true;$row=$directories[$Key]
            if ($row.name -ne '.') { $parts.Insert(0,$row.name) };$Key=$row.parent
        }
        return ($parts -join '/')
    }
    [IO.Directory]::CreateDirectory($outputRoot) | Out-Null
    $files=@()
    foreach ($row in $database.Query('SELECT `File`,`Component_`,`FileName` FROM `File`',3)) {
        $path=(Directory-Path $components[$row[1]])+'/'+($row[2] -split '\|')[-1]
        $match=[regex]::Match($path,'(?i)(?:^|/)(drivers/(?:sunshine|vhf-gamepad)/.+)$')
        if (-not $match.Success) { continue }
        $relative=$match.Groups[1].Value
        if ($relative -match '(^|/)\.\.(/|$)|[:\r\n]' -or $row[0] -match '[:\\/]') { throw 'Unsafe payload path.' }
        $from=Join-Path $cabRoot $row[0];$to=Join-Path $outputRoot $relative
        [IO.Directory]::CreateDirectory((Split-Path -Parent $to)) | Out-Null
        [IO.File]::Copy($from,$to,$false)
        $files+=@(@{path=$relative;sha256=(Get-FileHash -LiteralPath $to).Hash.ToLowerInvariant();size=(Get-Item -LiteralPath $to).Length})
    }
    $display=Join-Path $outputRoot 'drivers\sunshine';$gamepad=Join-Path $outputRoot 'drivers\vhf-gamepad'
    & "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $display 'install.ps1') -ValidateOnly
    if ($LASTEXITCODE -ne 0) { throw 'Independent display package validation failed.' }
    # Load declarations from the immutable vendor script, never its install body.
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $gamepad 'install.ps1'),[ref]$tokens,[ref]$errors)
    if ($errors.Count) { throw 'Vendor validator parse failed.' }
    foreach ($statement in $ast.EndBlock.Statements) {
        if ($statement -is [Management.Automation.Language.FunctionDefinitionAst]) { break }
        if ($statement -is [Management.Automation.Language.AssignmentStatementAst]) { . ([scriptblock]::Create($statement.Extent.Text)) }
    }
    foreach ($function in $ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]},$false)) { . ([scriptblock]::Create($function.Extent.Text)) }
    $validated=Assert-DriverPackage -Root $gamepad -AllowUntrustedLocalPackage
    $catalog=Get-AuthenticodeSignature -LiteralPath $validated.CatalogPath
    $vhfManifest=Get-Content -LiteralPath (Join-Path $gamepad 'manifest.json') -Raw | ConvertFrom-Json
    if ([int]$vhfManifest.protocol_version -ne 2) { throw 'Gamepad protocol incompatible with the pinned host.' }
    $certificates=@()
    foreach ($certificateFile in @(Get-ChildItem -LiteralPath $outputRoot -Filter *.cer -Recurse)) {
        $certificate=New-Object Security.Cryptography.X509Certificates.X509Certificate2($certificateFile.FullName)
        if ($certificate.HasPrivateKey) { throw 'A driver payload must never contain a private key.' }
        $certificates+=@(@{subject=$certificate.Subject;thumbprint=$certificate.Thumbprint;path=$certificateFile.FullName.Substring($outputRoot.Length+1).Replace('\','/')})
    }
    $record=@{schema='moonshine-prerequisites/1';source_url=$url;source_sha256=$expected;source_msi_sha256=(Get-FileHash -LiteralPath $msi).Hash.ToLowerInvariant();display_validation='passed';gamepad_validation='passed';gamepad_protocol=2;catalog_signer=$catalog.SignerCertificate.Subject;catalog_thumbprint=$catalog.SignerCertificate.Thumbprint;certificates=$certificates;files=$files;driver_install_executed=$false;trust_modified=$false}
    $json=ConvertTo-Json -InputObject $record -Depth 20
    [IO.File]::WriteAllText((Join-Path $outputRoot 'provenance.json'),$json,(New-Object Text.UTF8Encoding($false)))
    [IO.Directory]::CreateDirectory((Split-Path -Parent ([IO.Path]::GetFullPath($Evidence)))) | Out-Null
    [IO.File]::WriteAllText([IO.Path]::GetFullPath($Evidence),$json,(New-Object Text.UTF8Encoding($false)))
    Write-Output ('Verified '+$files.Count+' original prerequisite files; no installer, driver or certificate trust change executed.')
} finally {
    if ($database) { $database.Dispose() }
    Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
}
