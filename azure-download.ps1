#!/usr/bin/env pwsh

Set-PSDebug -Trace 0

# Check if az command is available, otherwise recommend to run brew install azure-cli
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Host "Azure CLI not found. Please install Azure CLI from https://docs.microsoft.com/en-us/cli/azure/install-azure-cli-macos"
    exit 1
}

# Check if az login has been run, otherwise recommend to run az login
if (-not (az account show -o json)) {
    Write-Host "Azure CLI not logged in. Running az login..."
    # run az login without showing the output
    az login > $null
}

$mode = 'interactive'

# Check if there is a parameter passed to the script
if ($args.Count -gt 0) {
  # Check if the parameter matches one of the pre-defined azure environments
  $azureEnvironment = $azureEnvironments | Where-Object { $_.key -eq $args[0] }
  if ($azureEnvironment) {
    # Set the azure environment as the active azure environment
    $mode = 'automatic'
    $subscriptionId = $azureEnvironment.value.subscriptionId
    $resourceGroupName = $azureEnvironment.value.resourceGroupName
  }
  else {
    # Print out the available azure environments
    Write-Host "Available azure environments:"
    $azureEnvironments | ForEach-Object {
      Write-Host "$($_.key)" -ForegroundColor Green
    }
    exit 1
  }
}

# List all accounts to select from
$accounts = az account list --all -o json | ConvertFrom-Json

# Filter out accounts that are not 'Enabled'
$enabledAccounts = $accounts | Where-Object { $_.state -eq 'Enabled' } | Sort-Object -Property name

$enabledAccounts | ForEach-Object {
    $count++
    Write-Host "[$($count)] $($_.id) - $($_.name)" -ForegroundColor Green
}

# Prompt for account selection:
$account_id = Read-Host "Select azure subscription"

# set the selected account as the active account
$selectedAccount = $enabledAccounts[$account_id - 1]
$subscriptionId = $selectedAccount.id


az account set --subscription $subscriptionId

# List all resource groups that end with '-ops'
$resourceGroups = az group list --query "[?ends_with(name, '-ops')]" -o json | ConvertFrom-Json

# test if resourceGroups is empty
if (-not $resourceGroups) {
  Write-Host "No resource groups found. Exiting..." -ForegroundColor Red
  exit 1
}

# If theres only one resource group, set it as the active resource group
if ($resourceGroups.Count -eq 1) {
  $resourceGroup = $resourceGroups[0]
  # print the name of the resource group
  Write-Host "Resource group found: $($resourceGroup.name)"
}
else {
  Write-Host "Multiple resource groups found:"
  $count = 0
  $resourceGroups | ForEach-Object {
    $count++
    Write-Host "[$($count)] $($_.name)" -ForegroundColor Green1
  }
  # Prompt for resource group selection:
  $selected = Read-Host "Select resource group"
  # set the selected resource group as the active resource group
  $resourceGroup = $resourceGroups[$selected - 1]
}

# Exit error if no resource group was selectecd
if (-not $resourceGroup) {
  Write-Host "No resource group selected. Exiting..."  -ForegroundColor Red
  exit 1
}

az configure --defaults group=$resourceGroups.name

# Get the storage account name and key from the resource group
$storageAccountName = az storage account list -g $($resourceGroup.name) --query "[0].name" -o tsv
$storageAccountKey = az storage account keys list -g $($resourceGroup.name) --account-name $storageAccountName --query "[0].value" -o tsv


# create a sas token for the storage account, that expires tomorrow
$storageAccountSasToken = az storage account generate-sas --account-key $storageAccountKey --account-name $storageAccountName --expiry $(date -v+1d +%Y-%m-%dT%H:%M:%SZ) --permissions acdlrw --resource-types sco --services b --https-only --output tsv


Write-Host "Storage account name: $storageAccountName"
Write-Host "Storage account sas token: $storageAccountSasToken"

# Get a list of the 20 most recenct storage containers
$storageContainers = az storage container list --num-results 10 --account-name $storageAccountName --account-key $storageAccountKey --sas-token $storageAccountSasToken -o json 2>$null | ConvertFrom-Json

# if there is no storage container, exit with error
if (-not $storageContainers) {
  Write-Host "No storage containers found. Exiting..." -ForegroundColor Red
  exit 1
}


# sort the storage containers by name in reverse order
$storageContainers = $storageContainers | Sort-Object -Property name -Descending

#
Write-Host "Storage containers:"

$count = 0
$storageContainers | ForEach-Object {
  $count++
  Write-Host "[$($count)] $($_.name)" -ForegroundColor Green
}


# Prompt for storage container selection:
$selected = Read-Host "Select storage container to download"

# set the selected storage container as the active storage container
$storageContainer = $storageContainers[$selected - 1]

Write-Host "Selected storage container: ${storageContainer.name}"

# create a list of download options
$downloadOptions = @(
  @{ key = 0; value = "dump.sql" }
  @{ key = 1; value = "files" }
  @{ key = 2; value = "dump.sql and files" }
)

foreach ($option in $downloadOptions) {
  Write-Host "[$($option.key)] $($option.value)" -ForegroundColor Green
}

# Prompt for download option selection:
$selected = Read-Host "Select what to download"

# if $selected is within the range of the download options, create a folder with the current datetime
if ($selected -ge 0 -and $selected -lt $downloadOptions.Count) {
  $folderName = $storageContainer.name
  mkdir $folderName
}

# set the selected download option as the active download option
if ($selected -eq 0) {
  # download the dump.sql file from the storage container to the folder
  az storage blob download --container-name $storageContainer.name --name dump.sql --file $folderName/dump.sql --account-name $storageAccountName --account-key $storageAccountKey --sas-token $storageAccountSasToken > $null
}
elseif ($selected -eq 1) {
  mkdir $folderName/static
  # download the static folder from the storage container
  az storage blob download-batch --source $storageContainer.name --pattern "static/*" --destination "$folderName" --account-name $storageAccountName --account-key $storageAccountKey --sas-token $storageAccountSasToken > $null
}
elseif ($selected -eq 2) {
  az storage blob download-batch --source $storageContainer.name --destination $folderName --account-name $storageAccountName --account-key $storageAccountKey --sas-token $storageAccountSasToken > $null
}

# Print out the folder name
Write-Host "Files successfully downloaded to $folderName"

#>
