#Requires -Version 5.1
function Plain-Secret([Security.SecureString]$Secret) {
    $ptr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secret)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}
function Api-Call([string]$Method,[string]$Path,$Body=$null,[string]$Authorization='') {
    Init-Native
    if ($Path -notmatch '^/api/[A-Za-z0-9/_-]+$') { throw 'Chemin API invalide.' }
    if (-not $script:Connection) { throw 'Connecter VibeShine avec le choix 2 du menu.' }
    if (-not $Authorization) { $Authorization=$script:Authorization }
    $content=[System.Management.Automation.Language.NullString]::Value
    if ($null -ne $Body) { $content=Json $Body }
    $reply=$null
    $attempts=$(if ($Method -eq 'GET') { 3 } else { 1 })
    for ($attempt=1;$attempt -le $attempts;$attempt++) {
        try {
            $reply=[OPi5Native]::Send($script:Connection.url+$Path,$Method,$Authorization,$content,$script:Connection.pin)
            if ($reply.Status -notin @(408,429,502,503,504) -or $attempt -eq $attempts) { break }
        } catch {
            if ($attempt -eq $attempts) { throw }
        }
        Start-Sleep -Seconds $attempt
    }
    if ($attempt -gt 1 -and $reply -and $reply.Status -ge 200 -and $reply.Status -lt 300) { Repair-Event 'api' 'read_recovered' ($Method+' '+$Path) }
    if ($reply.Status -lt 200 -or $reply.Status -ge 300) {
        if ($reply.Status -in @(401,403)) { throw 'Connexion VibeShine refusee. Refaire le choix 2 du menu (identifiants ou autorisations).' }
        throw ('Erreur API VibeShine HTTP '+$reply.Status+' sur '+$Method+' '+$Path+'.')
    }
    try { $result=$reply.Body | ConvertFrom-Json -ErrorAction Stop }
    catch { throw 'Reponse VibeShine non JSON.' }
    if ((Field $result 'status' $true) -eq $false -or (Field $result 'error')) { throw ('Operation API refusee : '+$Method+' '+$Path+'.') }
    return $result
}
function Probe-Connection([string]$Url,[string]$Pin) {
    return [OPi5Native]::Send($Url+'/api/csrf-token','GET','',[System.Management.Automation.Language.NullString]::Value,$Pin)
}
function Validate-Connection($Connection) {
    if ((Field $Connection 'url') -isnot [string] -or $Connection.url -notmatch '^https://127\.0\.0\.1:\d{1,5}$' -or
        (Field $Connection 'pin') -isnot [string] -or $Connection.pin -notmatch '^[A-Fa-f0-9]{64}$') { throw 'Configuration de connexion invalide.' }
    $null=Parse-Port ($Connection.url.Split(':')[-1])
    if ((Field $Connection 'schema') -and $Connection.schema -ne 'opi5-vibeshine-connection/2') { throw 'Version de connexion non reconnue; fichier conservé.' }
}
function Save-Connection($Connection,[string]$Token) {
    Validate-Connection $Connection
    if (-not $Token -or $Token -match '[\r\n]' -or $Token.Length -gt 32768) { throw 'Jeton API invalide.' }
    $secure=ConvertTo-SecureString $Token -AsPlainText -Force
    try { $encrypted=ConvertFrom-SecureString $secure } finally { $secure.Dispose() }
    # The endpoint, certificate pin and DPAPI token commit together. A failed
    # write cannot pair a new token with an older endpoint, or the reverse.
    $record=[ordered]@{schema='opi5-vibeshine-connection/2';url=$Connection.url;pin=$Connection.pin;
        version=$script:Version;encrypted_token=$encrypted}
    Write-Json (Join-Path $script:Data 'connection.json') $record
    return ,$record
}
function Load-Connection {
    $script:Connection=$null;$script:Authorization=''
    $candidate=Read-Json (Join-Path $script:Data 'connection.json')
    if (-not $candidate) { return }
    Validate-Connection $candidate
    if ((Field $candidate 'schema') -eq 'opi5-vibeshine-connection/2') {
        $secret=Field $candidate 'encrypted_token'
        if ($secret -isnot [string] -or -not $secret -or $secret.Length -gt 131072) { throw 'Connexion chiffrée incomplète; utiliser Reconnecter.' }
    } else { $secret=Read-Text (Join-Path $script:Data 'api-token.dpapi') 65536 }
    $secure=$null
    try {
        $secure=ConvertTo-SecureString $secret
        $token=Plain-Secret $secure
        if (-not $token -or $token -match '[\r\n]' -or $token.Length -gt 32768) { throw 'Jeton enregistré invalide; utiliser Reconnecter.' }
        $script:Connection=$candidate;$script:Authorization='Bearer '+$token
    } finally { if ($secure) { $secure.Dispose() };$token=$null;$secret=$null }
}
function Connect-Vibe {
    Init-Native
    $previousConnection=$script:Connection;$previousAuthorization=$script:Authorization
    $password=$null;$session='';$committed=$false
    try {
        Write-Host 'Connexion a VibeShine sur ce PC. Utiliser les identifiants de son interface Web.'
        Write-Host 'Appuyer sur la touche Entree sans rien saisir pour utiliser 47990.'
        $port=Parse-Port (Read-Host 'Port HTTPS (nombre seulement, ou laisser vide)')
        $url='https://127.0.0.1:'+$port
        $existing=Read-Json (Join-Path $script:Data 'connection.json')
        $pin=''
        if ($existing -and $existing.url -eq $url) { Validate-Connection $existing;$pin=$existing.pin }
        $probe=Probe-Connection $url $pin
        if ($probe.Status -ne 200 -or $probe.Fingerprint -notmatch '^[A-Fa-f0-9]{64}$') { throw 'Interface locale VibeShine non reconnue.' }
        $script:Connection=[ordered]@{url=$url;pin=$probe.Fingerprint;version=$script:Version}
        $script:Authorization=''
        $user=Read-Host 'Nom utilisateur VibeShine'
        $password=Read-Host 'Mot de passe VibeShine (saisie masquee)' -AsSecureString
        $loginBody=[ordered]@{username=$user;password=(Plain-Secret $password);remember_me=$false}
        try { $login=Api-Call 'POST' '/api/auth/login' $loginBody }
        finally { $loginBody.password='';$password.Dispose();$password=$null }
        $session='Session '+[string](Field $login 'token')
        if ($session -eq 'Session ') { throw 'VibeShine ne retourne pas de session.' }
        $script:Authorization=$session
        $apps=Get-Apps
        $scopes=@(
            @{path='/api/apps';methods=@('GET','POST')},
            @{path='/api/apps/706c6f73-7862-[A-Fa-f0-9-]+';methods=@('DELETE')},
            @{path='/api/session/status';methods=@('GET')}
        )
        $created=Api-Call 'POST' '/api/token' @{scopes=$scopes}
        $token=[string](Field $created 'token')
        if (-not $token) { throw 'Creation du jeton API impossible.' }
        $saved=Save-Connection $script:Connection $token
        $script:Connection=$saved;$script:Authorization='Bearer '+$token;$committed=$true
        Write-Host 'Connexion enregistree. Le jeton est chiffre pour ce compte Windows.' -ForegroundColor Green
    } finally {
        if ($session) { try { $null=Api-Call 'POST' '/api/auth/logout' $null $session } catch { } }
        if (-not $committed) { $script:Connection=$previousConnection;$script:Authorization=$previousAuthorization }
        if ($password) { $password.Dispose() }
        $user=$null;$session=$null;$login=$null;$created=$null;$token=$null;$previousAuthorization=$null
    }
}
function Get-Apps {
    $root=Api-Call 'GET' '/api/apps'
    if ('apps' -notin @(Keys $root) -or $null -eq $root.apps -or
        -not ($root.apps -is [System.Array])) { throw 'Catalogue API sans tableau apps valide; aucune reconstruction ni ecriture.' }
    foreach ($app in @($root.apps)) {
        if ($null -eq $app -or $app.GetType().FullName -ne 'System.Management.Automation.PSCustomObject' -or
            -not (Field $app 'uuid')) { throw 'Entree API mal formee; aucune reconstruction ni ecriture.' }
    }
    return $root
}
