$ErrorActionPreference = "Stop"

# Configuration
$SA_NAME = "github-actions-deployer"
$PROJECT_ID = gcloud config get-value project 2>$null

if ([string]::IsNullOrWhiteSpace($PROJECT_ID)) {
    Write-Host "Error: No active gcloud project found. Run 'gcloud config set project YOUR_PROJECT_ID' first." -ForegroundColor Red
    exit 1
}

Write-Host "Setting up GitHub Actions for project: $PROJECT_ID" -ForegroundColor Cyan

# 1. Create Service Account (if not exists)
Write-Host "checking/Creating Service Account: $SA_NAME..." -ForegroundColor Yellow
$saExists = gcloud iam service-accounts list --filter="email:$SA_NAME@$PROJECT_ID.iam.gserviceaccount.com" --format="value(email)"
if (-not $saExists) {
    gcloud iam service-accounts create $SA_NAME --display-name "GitHub Actions Deployer"
    Write-Host "Service Account created." -ForegroundColor Green
}
else {
    Write-Host "Service Account already exists." -ForegroundColor Gray
}

# 2. Assign Permissions
Write-Host "Assigning permissions (Cloud Run Admin, Storage Admin, Service Account User)..." -ForegroundColor Yellow
$SA_EMAIL = "$SA_NAME@$PROJECT_ID.iam.gserviceaccount.com"
gcloud projects add-iam-policy-binding $PROJECT_ID --member="serviceAccount:$SA_EMAIL" --role="roles/run.admin" | Out-Null
gcloud projects add-iam-policy-binding $PROJECT_ID --member="serviceAccount:$SA_EMAIL" --role="roles/storage.admin" | Out-Null
gcloud projects add-iam-policy-binding $PROJECT_ID --member="serviceAccount:$SA_EMAIL" --role="roles/iam.serviceAccountUser" | Out-Null # Needed to deploy as compute service account
Write-Host "Permissions assigned." -ForegroundColor Green

# 3. Create Key
$KeyFile = "gcp-sa-key.json"
if (-not (Test-Path $KeyFile)) {
    Write-Host "Creating Service Account Key..." -ForegroundColor Yellow
    gcloud iam service-accounts keys create $KeyFile --iam-account=$SA_EMAIL
    Write-Host "Key downloaded to $KeyFile" -ForegroundColor Green
}

# 4. Set Secrets using GH CLI
Write-Host "Setting GitHub Secrets..." -ForegroundColor Cyan

# GCP_PROJECT_ID
echo $PROJECT_ID | gh secret set GCP_PROJECT_ID
Write-Host "Secret GCP_PROJECT_ID set." -ForegroundColor Green

# GCP_SA_KEY
Get-Content $KeyFile -Raw | gh secret set GCP_SA_KEY
Write-Host "Secret GCP_SA_KEY set." -ForegroundColor Green

# SSH_PRIVATE_KEY
$SSH_KEY_PATH = Read-Host "Enter path to SSH Private Key (or press Enter to paste content directly)"
if (-not [string]::IsNullOrWhiteSpace($SSH_KEY_PATH) -and (Test-Path $SSH_KEY_PATH)) {
    Get-Content $SSH_KEY_PATH -Raw | gh secret set SSH_PRIVATE_KEY
}
else {
    Write-Host "Please paste the SSH Private Key content (User: lucas.teles) needed for the tunnel:" -ForegroundColor Yellow
    $SSH_KEY_CONTENT = Read-Host -MaskInput
    if (-not [string]::IsNullOrWhiteSpace($SSH_KEY_CONTENT)) {
        echo $SSH_KEY_CONTENT | gh secret set SSH_PRIVATE_KEY
    }
    else {
        Write-Host "Warning: SSH_PRIVATE_KEY not set. Deployment might fail if tunnel is needed." -ForegroundColor Red
    }
}
Write-Host "Secret SSH_PRIVATE_KEY set." -ForegroundColor Green


Write-Host "`nSetup Complete!" -ForegroundColor Green
Write-Host "1. Commited workflow file to .github/workflows/deploy.yml"
Write-Host "2. Secrets are configured in GitHub repo."
Write-Host "3. Push to 'main' to trigger deployment."

# Clean up key file?
$cleanup = Read-Host "Delete local key file $KeyFile? (Y/N)"
if ($cleanup -eq 'Y') {
    Remove-Item $KeyFile
    Write-Host "Key file deleted."
}
