#!/usr/bin/env bash
# setup.sh — one-time GCP infrastructure setup for the Safeguard Classifier.
#
# Run this ONCE per GCP project before the first deployment.
# After this completes, deploy the Vertex AI endpoint via Terraform,
# then run deploy.sh to build and launch the pipeline.
#
# Usage:
#   export SAFEGUARD_PROJECT=my-gcp-project  # required
#   export SAFEGUARD_REGION=europe-west2      # optional, default shown
#   bash setup.sh

set -euo pipefail

# ── Config ─────────────────────────────────────────────────────────────────────
PROJECT="${SAFEGUARD_PROJECT:?Set SAFEGUARD_PROJECT to your GCP project ID}"
REGION="${SAFEGUARD_REGION:-europe-west2}"
DATASET="${SAFEGUARD_DATASET:-safeguard}"
REPO="${SAFEGUARD_REPO:-safeguard}"
BUILD_BUCKET="${SAFEGUARD_BUILD_BUCKET:-${PROJECT}-cloudbuild-${REGION}}"
JOB_NAME="${SAFEGUARD_JOB:-safeguard-classifier}"

echo "=== Safeguard Classifier — Infrastructure Setup ==="
echo "Project : $PROJECT"
echo "Region  : $REGION"
echo "Dataset : $DATASET"
echo ""

# ── 1. Enable required GCP APIs ────────────────────────────────────────────────
echo "[1/6] Enabling GCP APIs..."
gcloud services enable \
  aiplatform.googleapis.com \
  bigquery.googleapis.com \
  run.googleapis.com \
  cloudbuild.googleapis.com \
  cloudscheduler.googleapis.com \
  artifactregistry.googleapis.com \
  --project="$PROJECT"
echo "      Done."

# ── 2. Artifact Registry repository ───────────────────────────────────────────
echo "[2/6] Creating Artifact Registry repository '$REPO'..."
if gcloud artifacts repositories describe "$REPO" \
    --location="$REGION" --project="$PROJECT" &>/dev/null; then
  echo "      Already exists, skipping."
else
  gcloud artifacts repositories create "$REPO" \
    --repository-format=docker \
    --location="$REGION" \
    --project="$PROJECT"
  echo "      Created."
fi

# ── 3. Cloud Build staging bucket ─────────────────────────────────────────────
echo "[3/6] Creating Cloud Build staging bucket 'gs://$BUILD_BUCKET'..."
if gcloud storage buckets describe "gs://$BUILD_BUCKET" &>/dev/null 2>&1; then
  echo "      Already exists, skipping."
else
  gcloud storage buckets create "gs://$BUILD_BUCKET" \
    --location="$REGION" \
    --project="$PROJECT"
  echo "      Created."
fi

# ── 4. BigQuery dataset ────────────────────────────────────────────────────────
echo "[4/6] Creating BigQuery dataset '$DATASET'..."
if bq show --project_id="$PROJECT" "$PROJECT:$DATASET" &>/dev/null 2>&1; then
  echo "      Already exists, skipping."
else
  bq --location="$REGION" mk --dataset "$PROJECT:$DATASET"
  echo "      Created."
fi

# ── 5. BigQuery tables ─────────────────────────────────────────────────────────
echo "[5/6] Creating BigQuery tables..."
export SAFEGUARD_PROJECT="$PROJECT"
export SAFEGUARD_DATASET="$DATASET"
envsubst < create_tables.sql \
  | bq query --use_legacy_sql=false --project_id="$PROJECT"
echo "      Tables created (or already exist)."

# ── 6. IAM — service account permissions ──────────────────────────────────────
# The Cloud Run Job uses the default Compute Engine service account.
# The Cloud Scheduler uses a dedicated scheduler SA to invoke the job.
echo "[6/6] Granting IAM permissions..."
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT" --format='value(projectNumber)')
COMPUTE_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
SCHEDULER_SA="safeguard-scheduler@${PROJECT}.iam.gserviceaccount.com"

# Cloud Run Job (Compute SA) needs BigQuery and Vertex AI access
gcloud projects add-iam-policy-binding "$PROJECT" \
  --member="serviceAccount:$COMPUTE_SA" \
  --role="roles/bigquery.dataEditor" --condition=None --quiet
gcloud projects add-iam-policy-binding "$PROJECT" \
  --member="serviceAccount:$COMPUTE_SA" \
  --role="roles/bigquery.jobUser" --condition=None --quiet
gcloud projects add-iam-policy-binding "$PROJECT" \
  --member="serviceAccount:$COMPUTE_SA" \
  --role="roles/aiplatform.user" --condition=None --quiet

# Create scheduler service account if it doesn't exist
if ! gcloud iam service-accounts describe "$SCHEDULER_SA" --project="$PROJECT" &>/dev/null; then
  gcloud iam service-accounts create safeguard-scheduler \
    --display-name="Safeguard Scheduler" \
    --project="$PROJECT"
fi

# Scheduler SA needs permission to invoke Cloud Run Jobs
gcloud projects add-iam-policy-binding "$PROJECT" \
  --member="serviceAccount:$SCHEDULER_SA" \
  --role="roles/run.invoker" --condition=None --quiet

echo "      IAM bindings set."

echo ""
echo "=== Infrastructure setup complete ==="
echo ""
echo "Next steps:"
echo "  1. Deploy the Vertex AI endpoint (takes ~15 min, costs GPU time):"
echo "       cd terraform"
echo "       cp terraform.tfvars.example terraform.tfvars"
echo "       # Edit terraform.tfvars: set project_id and region"
echo "       terraform init && terraform apply"
echo "       terraform output endpoint_id   # <- save this value"
echo ""
echo "  2. Build and deploy the pipeline:"
echo "       export SAFEGUARD_ENDPOINT=<endpoint_id from step 1>"
echo "       bash deploy.sh"
