#!/usr/bin/env bash
# deploy.sh — build and deploy the Safeguard Classifier pipeline.
#
# Run this after setup.sh and after the Vertex AI endpoint is live.
# Re-run any time you change ai_test.py or bigquery_io.py.
#
# Usage:
#   export SAFEGUARD_PROJECT=my-gcp-project
#   export SAFEGUARD_ENDPOINT=1234567890123456789  # from: terraform -chdir=terraform output endpoint_id
#   bash deploy.sh

set -euo pipefail

# ── Config ─────────────────────────────────────────────────────────────────────
PROJECT="${SAFEGUARD_PROJECT:?Set SAFEGUARD_PROJECT to your GCP project ID}"
ENDPOINT="${SAFEGUARD_ENDPOINT:?Set SAFEGUARD_ENDPOINT to the Vertex AI endpoint ID}"
REGION="${SAFEGUARD_REGION:-europe-west2}"
DATASET="${SAFEGUARD_DATASET:-safeguard}"
REPO="${SAFEGUARD_REPO:-safeguard}"
BUILD_BUCKET="${SAFEGUARD_BUILD_BUCKET:-${PROJECT}-cloudbuild-${REGION}}"
JOB_NAME="${SAFEGUARD_JOB:-safeguard-classifier}"
SCHEDULER_JOB="${JOB_NAME}-trigger"
IMAGE="${REGION}-docker.pkg.dev/${PROJECT}/${REPO}/classifier:latest"

PROJECT_NUMBER=$(gcloud projects describe "$PROJECT" --format='value(projectNumber)')
SCHEDULER_SA="safeguard-scheduler@${PROJECT}.iam.gserviceaccount.com"

echo "=== Safeguard Classifier — Deploy ==="
echo "Project  : $PROJECT"
echo "Region   : $REGION"
echo "Endpoint : $ENDPOINT"
echo "Image    : $IMAGE"
echo ""

# ── 1. Build and push Docker image via Cloud Build ─────────────────────────────
echo "[1/3] Building Docker image..."
gcloud builds submit \
  --tag "$IMAGE" \
  --region="$REGION" \
  --gcs-source-staging-dir="gs://$BUILD_BUCKET/source" \
  --project="$PROJECT" .
echo "      Image pushed: $IMAGE"

# ── 2. Create or update Cloud Run Job ─────────────────────────────────────────
ENV_VARS="SAFEGUARD_PROJECT=${PROJECT},SAFEGUARD_REGION=${REGION},SAFEGUARD_DATASET=${DATASET},SAFEGUARD_ENDPOINT=${ENDPOINT}"

echo "[2/3] Deploying Cloud Run Job '$JOB_NAME'..."
if gcloud run jobs describe "$JOB_NAME" \
    --region="$REGION" --project="$PROJECT" &>/dev/null 2>&1; then
  gcloud run jobs update "$JOB_NAME" \
    --image="$IMAGE" \
    --region="$REGION" \
    --project="$PROJECT" \
    --set-env-vars="$ENV_VARS" \
    --task-timeout=600 \
    --max-retries=3
  echo "      Updated."
else
  gcloud run jobs create "$JOB_NAME" \
    --image="$IMAGE" \
    --region="$REGION" \
    --project="$PROJECT" \
    --set-env-vars="$ENV_VARS" \
    --task-timeout=600 \
    --max-retries=3
  echo "      Created."
fi

# ── 3. Create or update Cloud Scheduler job ────────────────────────────────────
# Calls the Cloud Run Admin API to execute the job every 5 minutes.
JOB_URI="https://${REGION}-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/${PROJECT}/jobs/${JOB_NAME}:run"

echo "[3/3] Configuring Cloud Scheduler '$SCHEDULER_JOB'..."
if gcloud scheduler jobs describe "$SCHEDULER_JOB" \
    --location="$REGION" --project="$PROJECT" &>/dev/null 2>&1; then
  gcloud scheduler jobs update http "$SCHEDULER_JOB" \
    --location="$REGION" \
    --project="$PROJECT" \
    --schedule="*/5 * * * *" \
    --uri="$JOB_URI" \
    --message-body='{}' \
    --oauth-service-account-email="$SCHEDULER_SA" \
    --oauth-token-scope="https://www.googleapis.com/auth/cloud-platform"
  echo "      Updated."
else
  gcloud scheduler jobs create http "$SCHEDULER_JOB" \
    --location="$REGION" \
    --project="$PROJECT" \
    --schedule="*/5 * * * *" \
    --uri="$JOB_URI" \
    --message-body='{}' \
    --oauth-service-account-email="$SCHEDULER_SA" \
    --oauth-token-scope="https://www.googleapis.com/auth/cloud-platform"
  echo "      Created (runs every 5 minutes)."
fi

echo ""
echo "=== Deploy complete ==="
echo ""
echo "To verify: run the job manually and check BigQuery:"
echo "  gcloud run jobs execute $JOB_NAME --region=$REGION --project=$PROJECT"
echo "  bq query --use_legacy_sql=false --project_id=$PROJECT \\"
echo "    'SELECT * FROM \`${PROJECT}.${DATASET}.user_prompts_enriched\` ORDER BY classified_at DESC LIMIT 10'"
