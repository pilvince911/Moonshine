#Requires -Version 5.1
# This helper is used only by GitHub's disposable Windows CI machines.
function New-MoonshineCITestUser {
    if ($env:GITHUB_ACTIONS -ne 'true') { throw 'Creation du compte de test limitee aux machines jetables de GitHub Actions.' }
    $name='MoonshineCI'+[guid]::NewGuid().ToString('N').Substring(0,8)
    $password=ConvertTo-SecureString ([guid]::NewGuid().ToString('N')+'!Aa3') -AsPlainText -Force
    $account=$null
    try {
        $account=New-LocalUser -Name $name -Password $password -AccountNeverExpires -PasswordNeverExpires -UserMayNotChangePassword -ErrorAction Stop
        Add-LocalGroupMember -SID 'S-1-5-32-545' -Member $name -ErrorAction Stop
        return @{Name=$name;Password=$password;Sid=$account.SID}
    } catch { if ($account) { Remove-LocalUser -SID $account.SID -Confirm:$false };$password.Dispose();throw }
}
function Grant-MoonshineCITestFolder([string]$Folder,$User) {
    $acl=New-Object Security.AccessControl.DirectorySecurity;$acl.SetAccessRuleProtection($true,$false)
    $identities=@([Security.Principal.WindowsIdentity]::GetCurrent().User,$User.Sid,(New-Object Security.Principal.SecurityIdentifier('S-1-5-18')))
    foreach ($sid in $identities) {
        $rule=New-Object Security.AccessControl.FileSystemAccessRule($sid,[Security.AccessControl.FileSystemRights]::FullControl,([Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit),[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow)
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Folder -AclObject $acl
}
function Remove-MoonshineCITestUser($User) {
    if (-not $User) { return }
    if ($env:GITHUB_ACTIONS -ne 'true' -or $User.Name -cnotmatch '\AMoonshineCI[a-f0-9]{8}\z') { throw 'Compte hors du perimetre CI : aucun retrait.' }
    $actual=Get-LocalUser -Name $User.Name -ErrorAction SilentlyContinue
    if ($actual -and $actual.SID.Value -ceq $User.Sid.Value) {
        try {
            $profile=Get-CimInstance -ClassName Win32_UserProfile -Filter ("SID='"+$User.Sid.Value+"'") -ErrorAction Stop
            if ($profile -and -not $profile.Loaded) { $profile | Remove-CimInstance -ErrorAction Stop }
        } catch { Write-Warning 'Profil temporaire CI conserve pour le nettoyage de la machine jetable.' }
        Remove-LocalUser -SID $User.Sid -Confirm:$false -ErrorAction Stop
    }
    $User.Password.Dispose()
}
