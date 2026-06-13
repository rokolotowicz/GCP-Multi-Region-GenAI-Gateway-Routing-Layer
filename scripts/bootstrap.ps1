<#
.SYNOPSIS
  One-time bootstrap for Infrastructure Manager.

.DESCRIPTION
  Enables required APIs, creates the GCS state bucket, creates the Infra Manager
  runner service account, and grants it the roles needed to provision the stack.

.EXAMPLE
  .\scripts\bootstrap.ps1 -ProjectId vertexai-436401
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$ProjectId,

    [string]$Region = "us-east1",

    [string]$SaName = "infra-manager-runner"
)

$ErrorActionPreference = "Stop"

$Bucket  = "gs://$ProjectId-infra-manager-state"
$SaEmail = "$SaName@$ProjectId.iam.gserviceaccount.com"

Write-Host "==> Setting active project to $ProjectId" -ForegroundColor Cyan
gcloud config set project $ProjectId | Out-Null

Write-Host "==> Enabling required APIs (one-time)" -ForegroundColor Cyan
gcloud services enable `
  config.googleapis.com `
  cloudresourcemanager.googleapis.com `
  iam.googleapis.com `
  serviceusage.googleapis.com `
  storage.googleapis.com `
  --project=$ProjectId

Write-Host "==> Creating GCS bucket for Infra Manager source uploads" -ForegroundColor Cyan
$bucketExists = $true
try {
    gcloud storage buckets describe $Bucket 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { $bucketExists = $false }
} catch { $bucketExists = $false }

if (-not $bucketExists) {
    gcloud storage buckets create $Bucket `
      --project=$ProjectId `
      --location=$Region `
      --uniform-bucket-level-access
} else {
    Write-Host "    bucket already exists, skipping" -ForegroundColor DarkGray
}

Write-Host "==> Creating Infra Manager runner service account" -ForegroundColor Cyan
$saExists = $true
try {
    gcloud iam service-accounts describe $SaEmail 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { $saExists = $false }
} catch { $saExists = $false }

if (-not $saExists) {
    gcloud iam service-accounts create $SaName `
      --display-name="Infra Manager runner" `
      --project=$ProjectId
} else {
    Write-Host "    SA already exists, skipping" -ForegroundColor DarkGray
}

Write-Host "==> Granting roles to Infra Manager runner SA" -ForegroundColor Cyan
$roles = @(
    "roles/editor",
    "roles/iam.securityAdmin",
    "roles/compute.networkAdmin",
    "roles/compute.securityAdmin",
    "roles/run.admin",
    "roles/redis.admin",
    "roles/cloudkms.admin",
    "roles/dns.admin",
    "roles/secretmanager.admin",
    "roles/accesscontextmanager.policyAdmin",
    "roles/serviceusage.serviceUsageAdmin"
)
foreach ($role in $roles) {
    Write-Host "    granting $role" -ForegroundColor DarkGray
    gcloud projects add-iam-policy-binding $ProjectId `
      --member="serviceAccount:$SaEmail" `
      --role=$role `
      --condition=None `
      --quiet | Out-Null
}

Write-Host ""
Write-Host "==> Done." -ForegroundColor Green
Write-Host ""
Write-Host "    State bucket:    $Bucket"
Write-Host "    Runner SA:       $SaEmail"
Write-Host ""
Write-Host "Next:" -ForegroundColor Yellow
Write-Host "    Copy-Item terraform.tfvars.example terraform.tfvars"
Write-Host "    # edit terraform.tfvars"
Write-Host "    .\scripts\deploy.ps1"
