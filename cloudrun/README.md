# Deploying Belenios to Google Cloud Run (São Paulo)

This guide details how to deploy your Belenios application to Google Cloud Run in the `southamerica-east1` (São Paulo) region, using a custom domain (`homolog.votacao.univesp.br`) with a Google-managed SSL certificate (automatic renewal).

## Prerequisites

-   Google Cloud SDK (`gcloud`) installed and authorized (`gcloud auth login`).
-   Billing enabled on your Google Cloud Project.
-   Access to manage DNS records for your domain.

## Project Structure

The `cloudrun/` folder contains all necessary deployment files:

-   `Dockerfile`: Instructions to build the production Belenios image.
-   `entrypoint.sh`: Startup script that initializes the environment.
-   `deploy.ps1`: Automated PowerShell deployment script.
-   `ocsigenserver.conf.in`: Server configuration template adjusted for Cloud Run.
-   `http-redirect.yaml`: Configuration for HTTP-to-HTTPS redirection.

## Deployment Steps

### 1. Run the Deployment Script

Open PowerShell in the root of your project repository and run:

```powershell
.\cloudrun\deploy.ps1
```

This script will automatically:
1.  Build your Docker image and push it to Google Container Registry.
2.  Deploy the service to Cloud Run.
3.  Set up a Global External Application Load Balancer.
4.  Configure a Google-managed SSL certificate.
5.  Set up an HTTP-to-HTTPS redirect.

### 2. Configure DNS

The script will output a **Global IP Address** (e.g., `136.110.239.101`). You must create an **A Record** in your DNS provider settings:

-   **Name**: `homolog.votacao.univesp.br`
-   **Type**: `A`
-   **Value**: `YOUR_GLOBAL_IP_ADDRESS`
-   **TTL**: `300` (or default)

### 3. Verification

After updating DNS, wait 15-60 minutes for Google to provision the SSL certificate.

-   **Check Status**: `gcloud compute ssl-certificates list --global`
-   **Access Site**: `https://homolog.votacao.univesp.br`

## Troubleshooting

-   **502 Bad Gateway**: Check Cloud Run logs. The application might be crashing or not listening on port 8080.
-   **Certificate Staying in PROVISIONING**: Verify your DNS record matches the IP address exactly. Google validates ownership via DNS lookup.
-   **Permissions**: Ensure your `gcloud` account has `Cloud Run Admin`, `Compute Load Balancer Admin`, and `Storage Admin` roles.
