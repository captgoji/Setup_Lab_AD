# ==============================================================================
# Setup_AGDLP.ps1 - Met en place le modele AGDLP par decouverte (script autonome)
#
#   A ccount  -> comptes (dans les OUs)
#   G lobal   -> 1 groupe global par ressource, nom derive du dossier (ex: GG_RH)
#   DL omain local -> groupes DL par ressource et par niveau d'acces (ex: DL_RH_RW)
#   P ermission -> les groupes DL sont ajoutes sur les dossiers (sans rien retirer)
#
# Niveaux d'acces crees pour chaque ressource :
#   RO    (Allow) ReadAndExecute                   lecture seule
#   RW    (Allow) Modify                           lire / ecrire / supprimer
#   CT    (Allow) FullControl                       controle total
#   DEL   (Allow) Delete + DeleteSubdir            suppression seule (a combiner avec RO)
#   DENY  (Deny)  Delete + DeleteSubdir            interdit la suppression (un refus gagne toujours)
#
# ATTENTION : une ACE Deny l'emporte sur toute autorisation. Un compte present a
# la fois dans _DENY et dans un groupe autorise a supprimer (_RW, _CT, _DEL) ne
# pourra PAS supprimer. Le script le detecte et l'affiche en alerte.
#
# Aucune ressource n'est codee en dur : le script SCANNE les partages SMB du
# serveur (hors partages administratifs $). Pour chaque partage :
#   1. cree le groupe global     GG_<Dossier>
#   2. si une OU <Dossier> existe -> y place ses utilisateurs ; sinon groupe vide
#   3. cree les 5 groupes DL      DL_<Dossier>_RO / _RW / _CT / _DEL / _DENY
#   4. imbrique le global dans le DL "RW" (role principal de la ressource)
#   5. applique l'ACL du dossier en mode EXCLUSIF (AGDLP strict) :
#      casse l'heritage et NE GARDE que SYSTEM, Administrateurs et les groupes DL.
#      Tout le reste (groupes globaux, comptes directs, Utilisateurs...) est retire.
#   6. alerte si un compte est a la fois dans _DENY et un groupe autorise a supprimer
#
#   .\Setup_AGDLP.ps1                       # scan, creation des groupes ET application des ACL
#   .\Setup_AGDLP.ps1 -NoAcl                # cree les groupes sans toucher aux ACL
#   .\Setup_AGDLP.ps1 -WhatIfAcl            # montre les ACL cibles sans les ecrire
#   .\Setup_AGDLP.ps1 -GroupsOU "OU=Groupes,OU=LAB,DC=lab,DC=ap" -UsersParentOU "OU=Utilisateurs,OU=LAB,DC=lab,DC=ap"
# ==============================================================================

#Requires -RunAsAdministrator

param(
    # OU ou creer les groupes. Defaut : conteneur par defaut des groupes du domaine (CN=Users)
    [string]$GroupsOU       = "",
    # OU parente sous laquelle chercher une OU du meme nom que le dossier (pour peupler le global).
    # Defaut : tout le domaine est fouille.
    [string]$UsersParentOU  = "",
    # Prefixes des noms de groupes
    [string]$GlobalPrefix   = "GG_",
    [string]$DomainLocalPrefix = "DL_",
    # Chemins a ignorer (en plus des partages administratifs se terminant par $)
    [string[]]$ExcludeShares = @("NETLOGON","SYSVOL"),
    # Par defaut le script applique les ACL. -NoAcl pour seulement creer les groupes.
    [switch]$NoAcl,
    [switch]$WhatIfAcl
)

$ErrorActionPreference = "Stop"
Import-Module ActiveDirectory -ErrorAction Stop
Import-Module SmbShare        -ErrorAction Stop

function Write-Log { param([string]$M,[string]$C="White") Write-Host "[$(Get-Date -Format HH:mm:ss)] $M" -ForegroundColor $C }

$domain = Get-ADDomain
$DomainDN = $domain.DistinguishedName
if (-not $GroupsOU) { $GroupsOU = "CN=Users,$DomainDN" }

# Verifs d'emplacement
if (-not (Get-ADObject -Filter "DistinguishedName -eq '$GroupsOU'" -ErrorAction SilentlyContinue)) {
    Write-Log "OU des groupes introuvable : $GroupsOU" "Red"; exit 1
}
if ($UsersParentOU -and -not (Get-ADObject -Filter "DistinguishedName -eq '$UsersParentOU'" -ErrorAction SilentlyContinue)) {
    Write-Log "OU parente des utilisateurs introuvable : $UsersParentOU" "Red"; exit 1
}

Write-Log "Domaine $($domain.DNSRoot) | groupes dans $GroupsOU" "Cyan"

# Niveaux d'acces DL crees pour chaque ressource.
#   Type   : Allow ou Deny
#   Rights : droits FileSystemRights (combinables par virgule)
$AccessLevels = @(
    @{ Suffix = "RO";   Type = "Allow"; Rights = "ReadAndExecute" }
    @{ Suffix = "RW";   Type = "Allow"; Rights = "Modify" }
    @{ Suffix = "CT";   Type = "Allow"; Rights = "FullControl" }
    @{ Suffix = "DEL";  Type = "Allow"; Rights = "Delete, DeleteSubdirectoriesAndFiles" }
    @{ Suffix = "DENY"; Type = "Deny";  Rights = "Delete, DeleteSubdirectoriesAndFiles" }
)

function Get-SafeGroupName {
    # Nettoie le nom de dossier pour en faire un SamAccountName valide
    param([string]$Name)
    $clean = ($Name -replace '[^\w\-]', '_')
    if ($clean.Length -gt 48) { $clean = $clean.Substring(0,48) }
    return $clean
}

function New-LabGroup {
    param([string]$Name, [string]$Scope, [string]$Description)
    $existing = Get-ADGroup -Filter "SamAccountName -eq '$Name'" -ErrorAction SilentlyContinue
    if ($existing) {
        if ($existing.GroupScope -ne $Scope) {
            Write-Log "    ! $Name existe mais scope $($existing.GroupScope) (attendu $Scope) - ignore" "Yellow"
            return $null
        }
        Write-Log "    = $Name (existe)" "DarkGray"
        return $existing
    }
    $g = New-ADGroup -Name $Name -SamAccountName $Name -Path $GroupsOU `
            -GroupScope $Scope -GroupCategory Security -Description $Description -PassThru
    Write-Log "    + $Name" "Green"
    return $g
}

function Add-MemberOnce {
    param([string]$Group, $Member, [string]$Label)
    $exists = Get-ADGroupMember -Identity $Group -ErrorAction SilentlyContinue |
              Where-Object { $_.distinguishedName -eq $Member.distinguishedName }
    if ($exists) { Write-Log "      = $Label deja membre de $Group" "DarkGray"; return }
    Add-ADGroupMember -Identity $Group -Members $Member
    Write-Log "      + $Label -> $Group" "Green"
}

# ==============================================================================
# SCAN DES PARTAGES
# ==============================================================================
$shares = Get-SmbShare | Where-Object {
    -not $_.Special -and $_.Name -notlike '*$' -and $ExcludeShares -notcontains $_.Name
}
if (-not $shares) { Write-Log "Aucun partage SMB exploitable trouve." "Yellow"; exit 0 }
Write-Log "$($shares.Count) partage(s) a traiter : $(($shares.Name) -join ', ')" "Cyan"

foreach ($share in $shares) {
    $folder = $share.Name
    $base   = Get-SafeGroupName $folder
    Write-Log "[$folder] $($share.Path)" "White"

    # --- 1. Groupe global de la ressource ---
    $ggName = "$GlobalPrefix$base"
    $gg = New-LabGroup -Name $ggName -Scope Global -Description "Role - acces $folder"

    # --- 2. Peupler le global avec les utilisateurs d'une OU du meme nom (si elle existe) ---
    if ($gg) {
        $ouFilter = "Name -eq '$folder'"
        $ou = if ($UsersParentOU) {
            Get-ADOrganizationalUnit -Filter $ouFilter -SearchBase $UsersParentOU -ErrorAction SilentlyContinue
        } else {
            Get-ADOrganizationalUnit -Filter $ouFilter -ErrorAction SilentlyContinue
        }
        $ou = @($ou) | Select-Object -First 1

        if (-not $ou) {
            Write-Log "    ~ aucune OU nommee '$folder' - groupe global laisse vide (a remplir a la main)" "Yellow"
        } else {
            $users = Get-ADUser -Filter * -SearchBase $ou.DistinguishedName -ErrorAction SilentlyContinue
            if (-not $users) { Write-Log "    ~ OU '$folder' sans utilisateur" "DarkGray" }
            foreach ($u in $users) { Add-MemberOnce -Group $ggName -Member $u -Label $u.SamAccountName }
        }
    }

    # --- 3. Groupes DL par niveau d'acces ---
    $dlGroups = @{}
    foreach ($lvl in $AccessLevels) {
        $dlName = "$DomainLocalPrefix${base}_$($lvl.Suffix)"
        $desc   = "Ressource $folder - $($lvl.Type) $($lvl.Rights)"
        $dl = New-LabGroup -Name $dlName -Scope DomainLocal -Description $desc
        if ($dl) { $dlGroups[$lvl.Suffix] = @{ Name = $dlName; Rights = $lvl.Rights; Type = $lvl.Type } }
    }

    # --- 4. Imbrication : le global entre dans le DL "RW" (role principal) ---
    if ($gg -and $dlGroups.ContainsKey("RW")) {
        Add-MemberOnce -Group $dlGroups["RW"].Name -Member $gg -Label $ggName
    }

    # --- 5. Permissions : ACL EXCLUSIVE (AGDLP strict) ---
    # On reconstruit une ACL qui ne contient QUE SYSTEM, Administrateurs et les groupes DL.
    # Heritage casse et ACE heritees non copiees -> tout le reste disparait.
    if (-not $NoAcl) {
        if (-not (Test-Path -LiteralPath $share.Path)) {
            Write-Log "    ! dossier introuvable : $($share.Path)" "Yellow"
        } else {
            $acl = New-Object System.Security.AccessControl.DirectorySecurity
            $acl.SetAccessRuleProtection($true, $false)   # casse l'heritage, ne copie pas les ACE heritees

            # Socle minimal : SYSTEM et Administrateurs locaux en controle total (SID fixes)
            foreach ($sidStr in @("S-1-5-18", "S-1-5-32-544")) {
                $sid  = New-Object System.Security.Principal.SecurityIdentifier($sidStr)
                $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                    $sid, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
                $acl.AddAccessRule($rule)
            }
            Write-Log "    ACL reconstruite : SYSTEM + Administrateurs (controle total)" "DarkGray"

            # Deny d'abord (ordre canonique), puis Allow
            foreach ($lvl in ($AccessLevels | Sort-Object { if ($_.Type -eq 'Deny') { 0 } else { 1 } })) {
                if (-not $dlGroups.ContainsKey($lvl.Suffix)) { continue }
                $info = $dlGroups[$lvl.Suffix]
                $grp  = Get-ADGroup -Filter "SamAccountName -eq '$($info.Name)'" -ErrorAction SilentlyContinue
                if (-not $grp) { continue }
                $sid  = [System.Security.Principal.SecurityIdentifier]$grp.SID
                $ctrl = [System.Security.AccessControl.AccessControlType]::$($info.Type)
                $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                    $sid, $info.Rights, "ContainerInherit,ObjectInherit", "None", $ctrl)
                $acl.AddAccessRule($rule)
                $mark = if ($info.Type -eq 'Deny') { "DENY" } else { "+" }
                $col  = if ($info.Type -eq 'Deny') { "DarkYellow" } else { "Green" }
                Write-Log "    ACL $mark $($info.Name) -> $($info.Rights)" $col
            }

            # Proprietaire sain : Administrateurs (evite qu'un ancien proprietaire garde la main)
            $acl.SetOwner((New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")))

            if ($WhatIfAcl) { Write-Log "    (WhatIf : ACL non ecrite)" "DarkGray" }
            else {
                Set-Acl -LiteralPath $share.Path -AclObject $acl
                Write-Log "    ACL appliquee (exclusive) sur $($share.Path)" "Green"
            }
        }
    }

    # --- 6. Controle de coherence : membre a la fois dans _DENY et dans un groupe autorise a supprimer ---
    if ($dlGroups.ContainsKey("DENY")) {
        $denyMembers = @(Get-ADGroupMember -Identity $dlGroups["DENY"].Name -Recursive -ErrorAction SilentlyContinue)
        foreach ($suffix in @("RW","CT","DEL")) {
            if (-not $dlGroups.ContainsKey($suffix)) { continue }
            $allowMembers = @(Get-ADGroupMember -Identity $dlGroups[$suffix].Name -Recursive -ErrorAction SilentlyContinue)
            foreach ($dm in $denyMembers) {
                if ($allowMembers.distinguishedName -contains $dm.distinguishedName) {
                    Write-Log "    ! $($dm.SamAccountName) est dans _DENY ET _$suffix : il ne pourra PAS supprimer (le refus gagne)" "Yellow"
                }
            }
        }
    }
}

if ($NoAcl) {
    Write-Log "Groupes crees (ACL non modifiees : -NoAcl). Relance sans -NoAcl pour appliquer." "Cyan"
}
Write-Log "Termine." "Green"