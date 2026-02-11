$ErrorActionPreference = "Stop"

# Configuration
$PROJECT_ID = gcloud config get-value project
$REGION = "southamerica-east1"
$SERVICE_NAME = "belenios"
$IMAGE_NAME = "gcr.io/$PROJECT_ID/$SERVICE_NAME"
$DOMAIN = "homolog.votacao.univesp.br"

Write-Host "Starting Belenios deployment to Cloud Run in $REGION..." -ForegroundColor Green

# 1. Build and Push Container Image
Write-Host "Building and pushing Docker image..." -ForegroundColor Yellow
# We copy the Dockerfile to root temporarily as Cloud Build needs context
Copy-Item "cloudrun\Dockerfile" -Destination "Dockerfile" -Force
try {
    gcloud builds submit --tag $IMAGE_NAME .
}
finally {
    Remove-Item "Dockerfile" -ErrorAction SilentlyContinue
}

# 2. Deploy Cloud Run Service
Write-Host "Deploying Cloud Run service..." -ForegroundColor Yellow
gcloud run deploy $SERVICE_NAME `
    --image $IMAGE_NAME `
    --platform managed `
    --region $REGION `
    --allow-unauthenticated `
    --port 8080 `
    --set-env-vars="SMTP_RELAY_HOST=127.0.0.1,SMTP_RELAY_PORT=12525"
# To enable email, add these to the command above or set them in Google Cloud Console:
# --set-env-vars="SSH_PRIVATE_KEY=your_key_here,SSH_USER=username"

# 3. Create Global IP Address
Write-Host "Checking/Creating Global IP Address..." -ForegroundColor Yellow
$ipExists = gcloud compute addresses list --filter="name=belenios-ip AND region:global" --format="value(name)"
if (-not $ipExists) {
    gcloud compute addresses create belenios-ip --global
}
$IP_ADDRESS = gcloud compute addresses describe belenios-ip --global --format="value(address)"
Write-Host "Global IP Address: $IP_ADDRESS" -ForegroundColor Cyan
Write-Host "IMPORTANT: Update your DNS A record for $DOMAIN to point to $IP_ADDRESS" -ForegroundColor Red

# 4. Create Serverless NEG
Write-Host "Checking/Creating Network Endpoint Group (NEG)..." -ForegroundColor Yellow
$negExists = gcloud compute network-endpoint-groups list --filter="name=belenios-neg AND region=$REGION" --format="value(name)"
if (-not $negExists) {
    gcloud compute network-endpoint-groups create belenios-neg `
        --region=$REGION `
        --network-endpoint-type=serverless `
        --cloud-run-service=$SERVICE_NAME
}

# 5. Create Backend Service
Write-Host "Checking/Creating Backend Service..." -ForegroundColor Yellow
$backendExists = gcloud compute backend-services list --filter="name=belenios-backend" --format="value(name)"
if (-not $backendExists) {
    gcloud compute backend-services create belenios-backend --global
    gcloud compute backend-services add-backend belenios-backend `
        --global `
        --network-endpoint-group=belenios-neg `
        --network-endpoint-group-region=$REGION
}

# 6. Create Managed SSL Certificate
Write-Host "Checking/Creating Managed SSL Certificate..." -ForegroundColor Yellow
$certExists = gcloud compute ssl-certificates list --filter="name=belenios-cert" --format="value(name)"
if (-not $certExists) {
    gcloud compute ssl-certificates create belenios-cert `
        --domains $DOMAIN `
        --global
}

# 7. Create URL Map (Load Balancer)
Write-Host "Checking/Creating URL Map..." -ForegroundColor Yellow
$urlMapExists = gcloud compute url-maps list --filter="name=belenios-url-map" --format="value(name)"
if (-not $urlMapExists) {
    gcloud compute url-maps create belenios-url-map --default-service belenios-backend
}

# 8. Create Target HTTPS Proxy
Write-Host "Checking/Creating Target HTTPS Proxy..." -ForegroundColor Yellow
$proxyExists = gcloud compute target-https-proxies list --filter="name=belenios-https-proxy" --format="value(name)"
if (-not $proxyExists) {
    gcloud compute target-https-proxies create belenios-https-proxy `
        --ssl-certificates=belenios-cert `
        --url-map=belenios-url-map
}

# 9. Create Global Forwarding Rule (HTTPS)
Write-Host "Checking/Creating Global Forwarding Rule (HTTPS)..." -ForegroundColor Yellow
$ruleExists = gcloud compute forwarding-rules list --filter="name=belenios-lb" --format="value(name)"
if (-not $ruleExists) {
    gcloud compute forwarding-rules create belenios-lb `
        --address=belenios-ip `
        --target-https-proxy=belenios-https-proxy `
        --global `
        --ports=443
}

# 10. Configure HTTP-to-HTTPS Redirect
Write-Host "Configuring HTTP-to-HTTPS Redirect..." -ForegroundColor Yellow
$httpUrlMapExists = gcloud compute url-maps list --filter="name=belenios-http-redirect" --format="value(name)"
if (-not $httpUrlMapExists) {
    gcloud compute url-maps import belenios-http-redirect --source cloudrun\http-redirect.yaml --global --quiet
}

$httpProxyExists = gcloud compute target-http-proxies list --filter="name=belenios-http-proxy" --format="value(name)"
if (-not $httpProxyExists) {
    gcloud compute target-http-proxies create belenios-http-proxy --url-map=belenios-http-redirect --global
}

$httpRuleExists = gcloud compute forwarding-rules list --filter="name=belenios-http-lb" --format="value(name)"
if (-not $httpRuleExists) {
    gcloud compute forwarding-rules create belenios-http-lb `
        --address=belenios-ip `
        --target-http-proxy=belenios-http-proxy `
        --global `
        --ports=80
}

# 11. Allow Public Access
Write-Host "Ensuring public access..." -ForegroundColor Yellow
gcloud run services add-iam-policy-binding $SERVICE_NAME `
    --member="allUsers" `
    --role="roles/run.invoker" `
    --region=$REGION

Write-Host "`nDeployment Complete!" -ForegroundColor Green
Write-Host "1. Ensure DNS A record for $DOMAIN points to $IP_ADDRESS"
Write-Host "2. Wait 15-60 minutes for Google checks to provision the SSL certificate."
Write-Host "3. Access your site at https://$DOMAIN"
