<#
.SYNOPSIS
  Deploy the stack via Google Cloud Infrastructure Manager.

.DESCRIPTION
  Packages the Terraform config into a tarball, uploads it to the state bucket,
  and submits a deployment to Infra Manager. No local Terraform install needed.

.EXAMPLE
  .\scripts\deploy.ps1
#>
[CmdletBinding()]
param(
    [string]$Region = "us-east1",
    [string]$DeploymentName = "genai-gateway"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path "terraform.tfvars")) {
    Write-Error "terraform.tfvars not found. Run from the repo root, after copying from terraform.tfvars.example."
    exit 1
}

# ---- Parse project_id out of terraform.tfvars ------------------------------
$line = Get-Content terraform.tfvars | Select-String -Pattern '^\s*project_id\s*=' | Select-Object -First 1
if (-not $line) { Write-Error "project_id not found in terraform.tfvars"; exit 1 }
$ProjectId = ($line -split '"')[1]

$Bucket  = "gs://$ProjectId-infra-manager-state"
$SaEmail = "infra-manager-runner@$ProjectId.iam.gserviceaccount.com"

$Stamp     = [int][double]::Parse((Get-Date -UFormat %s))
$ZipName   = "config-$Stamp.zip"
$LocalZip  = Join-Path $env:TEMP $ZipName

Write-Host "==> Packaging Terraform config (zip)" -ForegroundColor Cyan
# Infra Manager requires a .zip (not .tar.gz). Stage only the Terraform files
# at the zip root — exclude scripts/, docs/, container/, .git/, and any archives.
$staging = Join-Path $env:TEMP "imgr-staging-$Stamp"
New-Item -ItemType Directory -Path $staging -Force | Out-Null
Copy-Item -Path .\*.tf -Destination $staging
Copy-Item -Path .\terraform.tfvars -Destination $staging
if (Test-Path .\terraform.tfvars.example) { Copy-Item .\terraform.tfvars.example $staging }

if (Test-Path $LocalZip) { Remove-Item $LocalZip -Force }
Compress-Archive -Path "$staging\*" -DestinationPath $LocalZip -Force
Remove-Item $staging -Recurse -Force

if (-not (Test-Path $LocalZip)) { Write-Error "zip packaging failed"; exit 1 }

Write-Host "==> Uploading config to $Bucket/$ZipName" -ForegroundColor Cyan
gcloud storage cp $LocalZip "$Bucket/$ZipName"
if ($LASTEXITCODE -ne 0) { Write-Error "upload failed"; exit 1 }

Write-Host "==> Submitting deployment to Infra Manager" -ForegroundColor Cyan
$exists = $true
try {
    gcloud infra-manager deployments describe $DeploymentName `
      --location=$Region --project=$ProjectId 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { $exists = $false }
} catch { $exists = $false }

if ($exists) {
    Write-Host "    deployment exists, updating" -ForegroundColor DarkGray
} else {
    Write-Host "    creating new deployment" -ForegroundColor DarkGray
}

gcloud infra-manager deployments apply $DeploymentName `
  --location=$Region `
  --project=$ProjectId `
  --service-account="projects/$ProjectId/serviceAccounts/$SaEmail" `
  --gcs-source="$Bucket/$ZipName"
  

if ($LASTEXITCODE -ne 0) { Write-Error "infra-manager apply failed"; exit 1 }

Write-Host ""
Write-Host "==> Submitted." -ForegroundColor Green
Write-Host ""
Write-Host "Watch progress:" -ForegroundColor Yellow
Write-Host "    gcloud infra-manager deployments describe $DeploymentName --location=$Region --project=$ProjectId"
Write-Host ""
Write-Host "Or in the console:" -ForegroundColor Yellow
Write-Host "    https://console.cloud.google.com/infra-manager/deployments?project=$ProjectId"

# Clean up local tarball
Remove-Item $LocalZip -ErrorAction SilentlyContinue
