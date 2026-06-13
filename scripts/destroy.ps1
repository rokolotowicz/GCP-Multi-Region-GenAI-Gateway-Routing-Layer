<#
.SYNOPSIS
  Tear down the deployment and all managed resources.
#>
[CmdletBinding()]
param(
    [string]$Region = "us-east1",
    [string]$DeploymentName = "genai-gateway"
)

$ErrorActionPreference = "Stop"

$line = Get-Content terraform.tfvars | Select-String -Pattern '^\s*project_id\s*=' | Select-Object -First 1
$ProjectId = ($line -split '"')[1]

Write-Host "==> Deleting Infra Manager deployment '$DeploymentName' (this will destroy all managed resources)" -ForegroundColor Yellow
$confirm = Read-Host "Type 'DESTROY' to confirm"
if ($confirm -ne "DESTROY") { Write-Host "Aborted."; exit 0 }

gcloud infra-manager deployments delete $DeploymentName `
  --location=$Region `
  --project=$ProjectId `
  --delete-policy=DELETE `
  --quiet
