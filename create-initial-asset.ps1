# Parameters
param (
	[Parameter(Mandatory = $true)][string]$location,
	[Parameter(Mandatory = $true)][string]$subscriptionId,
	[Parameter(Mandatory = $true)][string]$resourceGroupName,
	[Parameter(Mandatory = $true)][string]$ownerServicePrincipalName,
	[Parameter(Mandatory = $true)][string]$servicePrincipalName,
	[Parameter(Mandatory = $true)][string]$roleDefinition,
	[Parameter(Mandatory = $true)][string]$keyVaultName,
	[Parameter(Mandatory = $true)][string]$storageAccount,
	[Parameter(Mandatory = $true)][string]$storageAccountContainer,
	[Parameter(Mandatory = $false)][string]$yourTenantConfiguredEmailAddress,
	[Parameter(Mandatory = $false)][string]$appIDKeyVaultName,
	[Parameter(Mandatory = $false)][string]$secretKeyVaultName,
	[Parameter(Mandatory = $false)][string]$objectIDKeyVaultName,
	[Parameter(Mandatory = $false)][string]$gitPatKeyVaultName,
	[Parameter(Mandatory = $false)][string]$existingKeyvault,
	[Parameter(Mandatory = $false)][string]$storageKeyIDKeyVaultName,
	[Parameter(Mandatory = $false)][boolean]$enableCustomGraphRoles,
	[Parameter(Mandatory = $false)][array]$appRoles,
	[Parameter(Mandatory = $false)][boolean]$enableSetPermissionSP,
	[Parameter(Mandatory = $false)][boolean]$enableCustomADRoles,
	[Parameter(Mandatory = $false)][array]$customADRoles
)
if ($subscriptionId -eq "Visual Studio Enterprise Subscription") {
	$subscriptionId = "Visual Studio Enterprise Subscription"
}

function Find-GraphPerms {
	param (
		[string[]] $roles
	)
	$graphAPIPerms = @()
	foreach ($roleName in $roles) {
		if ([string]::IsNullOrWhiteSpace($roleName)) {
			Write-Error -Message "Empty Graph Roles not allowed"
			Exit 1
		}
		$perms = Find-MgGraphPermission $roleName | Where-Object {$_.PermissionType -eq "Application"} | Select-Object -Property Id | ForEach-Object { $_.Id }
		if ($perms.Count -eq 0) {
			Write-Error -Message "Could not find the appRole named $roleName"
			Exit 1
		}
		$graphAPIPerms = $graphAPIPerms + $perms
	}
	return $graphAPIPerms
}

function Find-CustomADRoles {
	param (
		[string[]] $roles
	)
	$adRoles = @()
	foreach ($roleName in $roles) {
		if ([string]::IsNullOrWhiteSpace($roleName)) {
			Write-Error -Message "Empty AD Roles not allowed"
			Exit 1
		}
		$foundRole = Get-AzRoleDefinition -Name $roleName
		if ($foundRole.Count -eq 0) {
			Write-Error -Message "Could not find AD role named $roleName"
			Exit 1
		}
		$adRoles = $adRoles + $foundRole.Name
	}
	return $adRoles
}

function New-GraphRoleAssignments {
	param (
		[string] $spName,
		[string] $spId,
		[string[]] $graphPerms
	)
	foreach ($appRoleId in $graphPerms) {
		$params = @{
			PrincipalId = $spId
			ResourceId = "abce22f1-733c-4f10-9215-dd8eabd7b1d4"
			AppRoleId = $appRoleId
		}
		Write-Output "Assigning appRole $appRoleId to Service Principal $spName ($spId) ..."
		New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $spId -BodyParameter $params
	}
}

# retrieving the GitPAT from azure keyvault
# $gitPat = Get-AzKeyVaultSecret -VaultName $existingKeyvault -Name "kv-git-pat" -AsPlainText
# $spAppID = Get-AzKeyVaultSecret -VaultName $existingKeyvault -Name "kv-sp-mgmt-app-id" -AsPlainText
# $spObjIdOwnerObjId = Get-AzKeyVaultSecret -VaultName $existingKeyvault -Name "kv-sp-mgmt-object-id" -AsPlainText
# $spSecret = Get-AzKeyVaultSecret -VaultName $existingKeyvault -Name "kv-sp-mgmt-secret" -AsPlainText
# $spSecretCnvtd = ConvertTo-SecureString -String $spSecret -AsPlainText -Force
# $spTenant = Get-AzKeyVaultSecret -VaultName $existingKeyvault -Name "kv-sp-mgmt-tenant" -AsPlainText

# validate graph api app roles if present

$graphAPIPerms = @()
if ($enableCustomGraphRoles -and $appRoles.Count -gt 0) {

	Install-Module Microsoft.Graph -Scope CurrentUser
	$response = Invoke-RestMethod "https://login.microsoftonline.com/$spTenant/oauth2/v2.0/token" -Method "POST" -Headers @{ "Content-Type" = "application/x-www-form-urlencoded" } -Body "grant_type=client_credentials&client_id=$spAppID&client_secret=$spSecret&scope=https%3A%2F%2Fgraph.microsoft.com%2F.default"
	Connect-MgGraph -AccessToken $response.access_token
	$graphAPIPerms = Find-GraphPerms -roles $appRoles

}

if ($enableCustomADRoles -and $customADRoles) {
	$customADRoleObjs = Find-CustomADRoles -roles $customADRoles
}

# Log in and switch to supplied subscription
$Credential = New-Object -TypeName "System.Management.Automation.PSCredential" -ArgumentList $spAppID, $spSecretCnvtd
Connect-AzAccount -ServicePrincipal -Credential $Credential -Tenant $spTenant -Subscription $subscriptionId

#$rgNames = "rg-finops-kcl-eastus-001,rg-kcns-blob-0107,rg-kcns-blob-0108" for example
# Specify a separator to divide the entries into individual rg names
$separator = ","

# Remove any empty entries
$option = [System.StringSplitOptions]::RemoveEmptyEntries

# Assign the split input resource group names to another variable
$splitEachRG = $resourceGroupName.Split($separator, $option)

# Create a hash table to save the rg names
$stringHashStore = @()

# Here, you need to filter the input entries collected from the user.

foreach($eachRG in $splitEachRG) {
	# Convert each of the split rg names to hashtable or dictionary and then assign to a new variable
	$stringHashStore += "$eachRG"
}

# This section covers the creation of the resource group for the initial asset creation.

$initialRG = $stringHashStore[0]

$checkInitialRG = Get-AzResourceGroup -Name $initialRG -ErrorAction SilentlyContinue

Write-Host "Getting Service Principal Named ${ServicePrincipalName}"
$checkServicePrincipal = Get-AzADServicePrincipal -DisplayName $ServicePrincipalName -ErrorAction SilentlyContinue

$checkStorageAccount = Get-AzStorageAccount -StorageAccountName $storageAccount -ResourceGroupName $initialRG -ErrorAction SilentlyContinue

$checkKeyVault = Get-AzKeyVault -VaultName $keyVaultName -ResourceGroupName $initialRG -ErrorAction SilentlyContinue

# Scope
$scope = "/subscriptions/$subscriptionId/resourceGroups/$initialRG"

# If true, the rg for the initial asset will be created
if($null -eq $checkInitialRG) {

	Write-Host -ForegroundColor Cyan "Creating $initialRG resource group...."
	New-AzResourceGroup -Name $initialRG -Location $location

} else {
	# Otherwise report the initial asset resource group already exist
	Write-Host -ForegroundColor DarkMagenta "$initialRG resource group already exist...."
}

#Create a Storage account of kind StorageV2 for terraform statefile, generate and assign an Identity for Azure KeyVault.
if ($null -eq $checkStorageAccount) {

	Write-Host -ForegroundColor Cyan "Creating Storage Account $storageAccount ..."
	New-AzStorageAccount -ResourceGroupName $initialRG -Name $storageAccount -Location "$location" -SkuName Standard_GRS -Kind StorageV2

	# Create a Storage blob container with Storage account object and container name, with public access as Blob

} else {
	Write-Host -ForegroundColor DarkMagenta "Storage Account $storageAccount already exist !!!"
}
$storageAccountObject = Get-AzStorageAccount -ResourceGroupName $initialRG -AccountName $storageAccount
$saContainer = New-AzRmStorageContainer -StorageAccount $storageAccountObject -ContainerName $storageAccountContainer -PublicAccess Blob -ErrorAction Stop
$storageAccountKey = (Get-AzStorageAccountkey -ResourceGroupName $initialRG -Name $storageAccount)[0].value

# This section covers the creation of the service principal for the initial asset creation.
if ($null -eq $checkServicePrincipal) {

	Write-Host -ForegroundColor Cyan "Creating Service Principal $ServicePrincipalName ..."
	$servicePrincipal = New-AzADServicePrincipal -DisplayName $ServicePrincipalName -Role $roleDefinition -Scope $scope
	$servicePrincipalSecret = $servicePrincipal.PasswordCredentials.SecretText

} else {
	Write-Host -ForegroundColor DarkMagenta "Service Principal $ServicePrincipalName already exist !!!"
	$servicePrincipal = $checkServicePrincipal
	Write-Host "Using existing Service Principal: ${servicePrincipal}"
	$servicePrincipalSecret = (New-AzADAppCredential -ApplicationId $servicePrincipal.AppId).SecretText
}
$servicePrincipalObjId = $servicePrincipal.Id
$servicePrincipalAppId = $servicePrincipal.AppId
Write-Host "SP Obj ID: ${servicePrincipalObjId}, SP App ID: ${servicePrincipalAppId}"
# Convert to secure strings
$spAppId = ConvertTo-SecureString -String $servicePrincipalAppId -AsPlainText -Force
$spSecret = ConvertTo-SecureString -String $servicePrincipalSecret -AsPlainText -Force
$spObjId = ConvertTo-SecureString -String $servicePrincipalObjId -AsPlainText -Force
$spGitPat = ConvertTo-SecureString -String $gitPat -AsPlainText -Force
$spStrgAcctKey = ConvertTo-SecureString -String $storageAccountKey -AsPlainText -Force


# Add required application MS Graph permissions requested if any
if ($graphAPIPerms.Count -gt 0) {
	New-GraphRoleAssignments -spName $servicePrincipalName -spId $servicePrincipalObjId -graphPerms $graphAPIPerms
}

# This section covers the creation of the key-vault for the initial asset creation.

if ($null -eq $checkKeyVault) {
	# Create A Key Vault Resource

	$checkRemovedKeyVault = Get-AzKeyVault -VaultName $keyVaultName -Location $location -InRemovedState
	if ($null -ne $checkRemovedKeyVault) {
		Write-Host -ForegroundColor DarkMagenta "This Key Vault $keyVaultName already exists in deleted state !!!"
		Remove-AzKeyVault -VaultName $keyVaultName -Location $location -InRemovedState -Force
	}
	Write-Host -ForegroundColor Cyan "Creating Key Vault $keyVaultName ..."
	New-AzKeyVault -VaultName $keyVaultName -ResourceGroupName $initialRG -Location $location
	$kvObj = Get-AzKeyVault -VaultName $keyVaultName -ResourceGroupName $initialRG -ErrorAction Stop
} else {
	Write-Host -ForegroundColor DarkMagenta "This Key Vault $keyVaultName already exist !!!"
	$kvObj = $checkKeyVault
}

# Set Access policy for owner SP
#Set-AzKeyVaultAccessPolicy -VaultName $keyVaultName -ObjectId $spObjIdOwnerObjId -PermissionsToSecrets get,list,set -PermissionsToKeys get,list,update -BypassObjectIdValidation
Set-AzKeyVaultAccessPolicy -VaultName $keyVaultName -ObjectId $spObjIdOwnerObjId -PermissionsToSecrets all -PermissionsToKeys get,list,update -BypassObjectIdValidation

if ($enableSetPermissionSP) {
	Set-AzKeyVaultAccessPolicy -VaultName $keyVaultName -ObjectId $ServicePrincipalObjId -PermissionsToSecrets get,list,set -PermissionsToKeys get,list -BypassObjectIdValidation
}else{
    Set-AzKeyVaultAccessPolicy -VaultName $keyVaultName -ObjectId $ServicePrincipalObjId -PermissionsToSecrets get,list -PermissionsToKeys get,list -BypassObjectIdValidation
}


# Set keyvault keys and values
Set-AzKeyVaultSecret -VaultName $keyVaultName -Name $appIDKeyVaultName -SecretValue $spAppId
Set-AzKeyVaultSecret -VaultName $keyVaultName -Name $secretKeyVaultName -SecretValue $spSecret
Set-AzKeyVaultSecret -VaultName $keyVaultName -Name $objectIDKeyVaultName -SecretValue $spObjId
Set-AzKeyVaultSecret -VaultName $keyVaultName -Name $gitPatKeyVaultName -SecretValue $spGitPat
Set-AzKeyVaultSecret -VaultName $keyVaultName -Name $storageKeyIDKeyVaultName -SecretValue $spStrgAcctKey

Write-Host "*******Creating Other Resource groups and assigning contributor role*********"

# This checks to see if the RG already exists otherwise, it creates those RG that do not exist.
foreach ($newRGName in $stringHashStore) {

	Start-Sleep -Seconds 1

	$checkRGnotPresent = Get-AzResourceGroup -Name $newRGName -ErrorAction SilentlyContinue

	# Here you will check to see if the resource group name in the first entry exists under any subscription
	if($null -eq $checkRGnotPresent) {

		# if Otherwise, the rg will be created
		Write-Host -ForegroundColor Green "Creating $newRGName resource group...."
		New-AzResourceGroup -Name $newRGName -Location $location

		Start-Sleep -Seconds 1

	} else {
		# Based on the result of the "if" statement, if the rg exist nothing will be done as rg already exist
		Write-Host -ForegroundColor Red "Resource Group name ${newRGName} already exists!"
		$existingRoleAssignment = Get-AzRoleAssignment -ObjectId $servicePrincipalObjId -RoleDefinitionName $roleDefinition -ResourceGroupName $newRGName
	}

	if ($null -eq $existingRoleAssignment) {
		# Grant the service principal contributor role on the newly created resource group
		Write-Host -ForegroundColor Yellow "Granting SP ${servicePrincipalObjId} ${roleDefinition} role on ${newRGName} resource group...."
		New-AzRoleAssignment -ObjectId $servicePrincipalObjId -RoleDefinitionName $roleDefinition -ResourceGroupName $newRGName
	} else {
		Write-Host -ForegroundColor Yellow "SP ${servicePrincipalObjId} is already granted ${roleDefinition} role on ${newRGName} resource group, skipping..."
	}
}

# Give current user id access
$yourObjectID = (Get-AzADUser -Mail $yourTenantConfiguredEmailAddress).Id
if ($yourObjectID) {
	Set-AzKeyVaultAccessPolicy -VaultName $keyVaultName -ObjectId $yourObjectID -PermissionsToSecrets get,list,set -PermissionsToKeys get,list,update -BypassObjectIdValidation
} else {
	Write-Host "$yourTenantConfiguredEmailAddress was not found!"
}

# Add required Active Directory Roles if any
if ($enableCustomADRoles) {
	foreach ($roleName in $customADRoleObjs) {
		Write-Output "Adding role assignment '${roleName}' to ${spObjId} on Resource Group ${initialRG}."
		New-AzRoleAssignment -ObjectId $servicePrincipalObjId -RoleDefinitionName $roleName -ResourceGroupName $initialRG
	}
}

# Summary of what was created:
Write-Output "---Summary of Initial Assets Created--"
Write-Output "***Subscription Details***"
Write-Output "	Subscription ID: $subscriptionId`n"
if ($null -ne $checkInitialRG) {
	Write-Output "***Existing Resource Group(RG) Details***"
} else {
	Write-Output "***Created Resource Group(RG) Details***"
}
Write-Output "	RG Name: ${initialRG}"
Write-Output "	RG Name Location: $location`n"
if ($null -ne $checkServicePrincipal) {
	Write-Output "***Existing Service Principal (SP) Details***"
} else {
	Write-Output "***Created Service Principal (SP) Details***"
}
Write-Output "	SP Name: $servicePrincipalName"
Write-Output "	SP AppID: $servicePrincipalAppId"
Write-Output "	SP ObjectID: $servicePrincipalObjId`n"
if ($null -ne $checkStorageAccount) {
	Write-Output "***Existing Storage Account (SA) Details***"
} else {
	Write-Output "***Created Storage Account (SA) Details***"
}
$saId = $storageAccountObject.Id
Write-Output "	SA Name: $storageAccount"
Write-Output "	SA Id: ${saId}"
Write-Output "	SA Container Name: $storageAccountContainer"
$scId = $saContainer.Id
Write-Output "  SA Container Id: ${scId}`n"
if ($null -ne $checkKeyVault) {
	Write-Output "***Existing Key vault (KV) Details***"
} else {
	if ($null -ne $checkRemovedKeyVault) {
		$purgedKVId = $checkRemovedKeyVault.Id
		Write-Output "***NOTE: Key vault ${purgedKVId} was purged***"
	}
	Write-Output "***Created Key vault (KV) Details***"
}
Write-Output "	KV Name: $keyVaultName"
$kvId = $kvObj.VaultUri
Write-Output "	KV Vault URI: $kvId`n"
Write-Output "	AppID KV Name: $appIDKeyVaultName"
Write-Output "	Secret KV Name: $secretKeyVaultName"
Write-Output "	ObjectID KV Name: $objectIDKeyVaultName"
Write-Output "	GitPat KV Name: $gitPatKeyVaultName"
Write-Output "	StorageKey KV Name: $storageKeyIDKeyVaultName`n"