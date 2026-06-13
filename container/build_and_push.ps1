<#
.SYNOPSIS
  Build the gateway container in Cloud Build and push to Artifact Registry.
  No local Docker required.

.EXAMPLE
  .\container\build_and_push.ps1 -ProjectId vertexai-436401
  .\container\build_and_push.ps1 -ProjectId vertexai-436401 -Tag v2
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$ProjectId,

    [string]$Tag = "v1",
    [string]$Region = "us-east1",
    [string]$Repo = "gateway"
)

$ErrorActionPreference = "Stop"

$Image = "$Region-docker.pkg.dev/$ProjectId/$Repo/proxy:$Tag"

Write-Host "==> Enabling Artifact Registry + Cloud Build APIs" -ForegroundColor Cyan
gcloud services enable `
  artifactregistry.googleapis.com `
  cloudbuild.googleapis.com `
  --project=$ProjectId

Write-Host "==> Creating Artifact Registry repo (if missing)" -ForegroundColor Cyan
$repoExists = $true
try {
    gcloud artifacts repositories describe $Repo `
      --location=$Region --project=$ProjectId 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { $repoExists = $false }
} catch { $repoExists = $false }

if (-not $repoExists) {
    gcloud artifacts repositories create $Repo `
      --repository-format=docker `
      --location=$Region `
      --description="GenAI gateway containers" `
      --project=$ProjectId
} else {
    Write-Host "    repo exists, skipping" -ForegroundColor DarkGray
}

Write-Host "==> Submitting build to Cloud Build (this takes ~3-5 min)" -ForegroundColor Cyan
# Run from the directory containing this script (the 'container' folder)
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Push-Location $ScriptDir
try {
    gcloud builds submit . `
      --tag=$Image `
      --project=$ProjectId `
      --region=$Region
} finally {
    Pop-Location
}

Write-Host ""
Write-Host "==> Built and pushed:" -ForegroundColor Green
Write-Host "    $Image"
Write-Host ""
Write-Host "Set this in terraform.tfvars:" -ForegroundColor Yellow
Write-Host "    container_image = `"$Image`""
