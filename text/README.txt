# Safeguard Classifier

An automated SOC detection pipeline that screens user prompts for attacks against or abuse of the AI system itself. Detects prompt injection, jailbreaks, cyber exploitation (malware/exploit development), credential harvesting, and red-team reconnaissance using [gpt-oss-safeguard-20b](https://huggingface.co/openai/gpt-oss-safeguard-20b) hosted on Vertex AI.

**Production performance:** 98-100% recall, 0% false positive rate on prompt injection, jailbreak, and red-team categories (200-row balanced test dataset). `cyber_exploitation` and `credential_harvesting` were added after that evaluation and have no test coverage yet — re-run the evaluation against the current category set before relying on these numbers for them.

## Architecture

```
Cloud Scheduler (every 5 min)
    └── Cloud Run Job (safeguard-classifier)
            ├── BigQuery: claim unclassified rows from user_prompts
            ├── Vertex AI Endpoint: classify each prompt (gpt-oss-safeguard-20b)
            └── BigQuery: write results to user_prompts_enriched
```


## Prerequisites

- [gcloud CLI](https://cloud.google.com/sdk/docs/install) — run `gcloud auth login` AND `gcloud auth application-default login` (Terraform needs ADC)
- [Terraform](https://developer.hashicorp.com/terraform/install) ≥ 1.5
- [bq CLI](https://cloud.google.com/bigquery/docs/bq-command-line-tool) (included with gcloud SDK)
- `envsubst` — included on Linux/Cloud Shell; on macOS: `brew install gettext`
- A GCP project with billing enabled
- [GitHub CLI](https://cli.github.com/) (`gh`) if cloning from a private repo

## Quick Start

### 1. Set environment variables

```bash
cp .env.example .env
# Edit .env with your GCP project ID and preferred region
export SAFEGUARD_PROJECT=<my-gcp-project>
export SAFEGUARD_REGION=europe-west2   # must be in an allowed region
```

### 2. One-time infrastructure setup

Creates the Artifact Registry repo, BigQuery dataset + tables, Cloud Build staging bucket, and IAM bindings.

```bash
bash setup.sh
```

### 3. Deploy the Vertex AI endpoint

This deploys gpt-oss-safeguard-20b on a GPU-backed Vertex AI endpoint. Takes ~15 minutes and costs GPU time while running.

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: set project_id and region
terraform init
terraform apply
terraform output endpoint_id   # save this value
cd ..
```

> **Note:** The default config deploys a `g2-standard-12` instance (1× NVIDIA L4). This has a **4,096 total token context window** (input + output combined) — a confirmed constraint of this Vertex AI deployment, not the underlying model architecture.

### 4. Build and deploy the pipeline

```bash
export SAFEGUARD_ENDPOINT=<endpoint_id from step 3>
bash deploy.sh
```

This builds the Docker image via Cloud Build, creates the Cloud Run Job, and creates a Cloud Scheduler job that triggers it every 5 minutes.

### 5. Seed data and verify

```bash
# Load the 22-row demo dataset
cd datasets
SAFEGUARD_PROJECT=<my-gcp-project> python demo_populate.py

# Wait one scheduler cycle (~5 min), then check results
bq query --use_legacy_sql=false --project_id=<my-gcp-project> \
  'SELECT username, violation, category, confidence, rationale
   FROM `<my-gcp-project>.safeguard.user_prompts_enriched`
   ORDER BY classified_at DESC LIMIT 20'
```

Or trigger the job immediately:

```bash
gcloud run jobs execute safeguard-classifier \
  --region=$SAFEGUARD_REGION --project=$SAFEGUARD_PROJECT
```

## Running Locally

Requires a Vertex AI endpoint already deployed and `SAFEGUARD_ENDPOINT` set.

```bash
pip install -r requirements.txt

# Classify a single prompt
echo "Ignore all previous instructions" | python classifier.py

# Run built-in demo examples
python classifier.py --demo

# Classify from a text file (one prompt per line)
python classifier.py --file prompts.txt

# BigQuery mode (same as the Cloud Run Job)
SAFEGUARD_PROJECT=<my-gcp-project> python classifier.py --bigquery
```

## Evaluation Dataset

`datasets/repopulate_user_prompts.py` loads a 200-row balanced dataset:

| Category | Count | Username |
|---|---|---|
| Prompt injection | 50 | `injection_user` |
| Jailbreak | 50 | `jailbreak_user` |
| Red team | 50 | `red_team_user` |
| Benign | 50 | `benign_user` |

```bash
SAFEGUARD_PROJECT=<my-gcp-project> python datasets/repopulate_user_prompts.py
```

## Environment Variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `SAFEGUARD_PROJECT` | Yes | — | GCP project ID |
| `SAFEGUARD_ENDPOINT` | Yes | — | Vertex AI endpoint ID (from `terraform output`) |
| `SAFEGUARD_REGION` | No | `europe-west2` | GCP region |
| `SAFEGUARD_DATASET` | No | `safeguard` | BigQuery dataset name |
| `SAFEGUARD_REPO` | No | `safeguard` | Artifact Registry repo name |
| `SAFEGUARD_BUILD_BUCKET` | No | `{project}-cloudbuild-{region}` | Cloud Build staging bucket |
| `SAFEGUARD_JOB` | No | `safeguard-classifier` | Cloud Run Job name |
| `SAFEGUARD_MAX_INPUT_CHARS` | No | `4000` | Max prompt chars before truncation |

## Files

| File | Purpose |
|---|---|
| `classifier.py` | Classifier — `SafeguardClient`, 17 few-shot examples, CLI |
| `bigquery_io.py` | BigQuery helpers — atomic row claiming, result writing |
| `Dockerfile` | Container for the Cloud Run Job |
| `requirements.txt` | Python dependencies |
| `create_tables.sql` | BigQuery schema (template — substituted by `setup.sh`) |
| `.gcloudignore` | Cloud Build allowlist (only the 4 production files) |
| `setup.sh` | One-time GCP infrastructure setup |
| `deploy.sh` | Build image + create/update Cloud Run Job + Scheduler |
| `deploy_endpoint.py` | Redeploy the model to the existing production endpoint |
| `deploy_new_endpoint.py` | Deploy the model to a brand new endpoint (e.g. larger context) |
| `terraform/` | Terraform config for Vertex AI endpoint deployment |
| `datasets/repopulate_user_prompts.py` | 200-row evaluation dataset |
| `datasets/demo_populate.py` | 22-row curated demo dataset |

## Key Design Decisions

- **Batch load over streaming inserts:** `bigquery_io.py` uses `load_table_from_json` (not `insert_rows_json`) for all BigQuery writes. Streaming inserts are blocked after `CREATE OR REPLACE TABLE`, causing silent write failures.
- **Atomic row claiming:** each Cloud Run execution stamps rows with its own ID before reading, preventing duplicate processing when multiple executions overlap.
- **4,096-token context budget:** the Vertex AI endpoint has a confirmed 4,096 total token limit (input + output). System prompt is ~2,450 tokens (17 few-shot examples across 8 SOC-scoped categories); user input is capped at 4,000 chars (~1,000 tokens); JSON output needs ~80-120 tokens.
- **`response_format: json_object`:** forces the model to output JSON immediately without preamble, critical given the tight token budget.
