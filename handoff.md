# Project Handoff — AI Safety Classifier
**Last updated: 2026-06-30 (session 6)**

---

## Goal

Build an automated pipeline that screens user prompts sent to an LLM for safety violations — prompt injection, jailbreak attempts, red team reconnaissance, harassment, hate speech, violence, and illegal content — before or after they reach the model.

The classifier uses a specialist safety model (GPT-OSS-Safeguard-20b) hosted on Vertex AI. It reads prompts from BigQuery, classifies each one, and writes the verdict back to a second BigQuery table. Everything runs automatically on a schedule via Cloud Run and Cloud Scheduler.

The longer-term vision is to wire this up inline as a real-time tool call from an AI agent, so prompts can be blocked before they ever reach the main model.

---

## Current State

The pipeline is fully operational end-to-end. Classification performance is production-ready. Session 6 focused on presentation prep, codebase cleanup, and an attempted upgrade to a larger-context endpoint.

**Active dataset (session 6 — presentation demo):**
- 22 rows in `user_prompts` loaded via `population/demo_populate.py`
- 6 prompt injections (`demo_injection`) / 6 jailbreaks (`demo_jailbreak`) / 6 red team (`demo_red_team`) / 4 benign (`demo_benign`)
- Full 200-row evaluation dataset available via `population/repopulate_user_prompts.py`

**Container state (latest build — session 5, unchanged in session 6):**
- **15 few-shot examples** (trimmed from 32; fewer examples is critical — see issue 19)
- `response_format: {"type": "json_object"}` added to API request — forces JSON-first output
- `reasoning_effort: "low"` passed as API parameter
- `MAX_TOKENS = 65536`, `MAX_INPUT_CHARS = 6000`
- `bigquery_io.write_enriched()` uses `load_table_from_json` (batch) instead of `insert_rows_json` (streaming) — fixes "Table is truncated" errors after CTAS
- INFO-level token logging + partial content logging on truncation for diagnostics
- **Endpoint total context window: 4096 tokens** (confirmed via token usage logs — see issue 19)
- Effective token budget: ~2,000 (system prompt) + ~1,500 (user input) + ~80 (JSON output) ≈ 3,580 total

**Current performance metrics (session 5, 200-row balanced dataset):**

| Category | Detected | Total | Recall |
|---|---|---|---|
| prompt_injection | 49 | 50 | **98%** |
| jailbreak | 50 | 50 | **100%** |
| red_team | 50 | 50 | **100%** |
| benign (FP check) | 0 FP | 50 | **0%** |
| **Overall** | **149** | **150** | **99.3%** |

**Zero token errors, zero false positives.**

**Session 6 changes:**
- Codebase cleaned up — endpoint manager removed, stale scripts deleted, population scripts moved to `population/` subdirectory (see Files section)
- Presentation materials created: `one_pager.md` (executive overview), `architecture.md` (Mermaid diagram)
- Large-context endpoint deployment attempted (see issue 21) — blocked by GCP capacity, pending resolution

---

## Files

**Production pipeline** (the 4 files uploaded to Cloud Build and run in the container)

| File | Purpose |
|---|---|
| [ai_test.py](ai_test.py) | Main classifier — SafeguardClient, few-shot system prompt, BigQuery mode, CLI |
| [bigquery_io.py](bigquery_io.py) | BigQuery helpers — atomic row claiming and result writing |
| [Dockerfile](Dockerfile) | Container definition for the classifier Cloud Run Job |
| [requirements.txt](requirements.txt) | Python dependencies for the classifier |

**Data population scripts**

| File | Purpose |
|---|---|
| [population/repopulate_user_prompts.py](population/repopulate_user_prompts.py) | Full 200-row balanced evaluation dataset (50 per category) — clears all rows before loading |
| [population/demo_populate.py](population/demo_populate.py) | 22-row curated demo set for presentations — only touches `demo_*` usernames, leaves other data intact |

**Infrastructure**

| File | Purpose |
|---|---|
| [.gcloudignore](.gcloudignore) | Cloud Build allowlist — only the 4 production files are uploaded (keeps build from uploading the venv) |
| [deploy_endpoint.py](deploy_endpoint.py) | Script to deploy a new Vertex AI endpoint — currently configured for g2-standard-24 (2× L4, 16K context); see issue 21 |
| [create_tables.sql](create_tables.sql) | BigQuery schema definitions for both tables |

**Documentation**

| File | Purpose |
|---|---|
| [handoff.md](handoff.md) | This file — full project history, architecture, and next steps |
| [architecture.md](architecture.md) | Mermaid end-to-end architecture diagram (renders in VS Code) |
| [one_pager.md](one_pager.md) | Executive one-pager — what we built, why it matters, risk of not implementing |

---

## Everything That Was Tried and Failed

### 1. Streaming inserts for `user_prompts` → broke DML claiming
`populate_user_prompts.py` originally used `client.insert_rows_json()` (BigQuery streaming API). Streaming rows land in a buffer for up to 90 minutes and **cannot be updated by DML** during that time. The container's atomic claim logic does an `UPDATE user_prompts SET claimed_by = ...` — this threw a 400 error on every execution.

**Fix:** switched `populate_user_prompts.py` to use `load_table_from_json()` (batch load). Batch-loaded rows are immediately available for DML.

### 2. Race condition — multiple executions processing the same rows
With no claiming mechanism, the scheduler spawned a new execution every 5 minutes. If the previous execution hadn't finished, both would SELECT the same unclassified rows and duplicate work.

**Fix:** added atomic DML UPDATE in `bigquery_io.fetch_unclassified()` — each execution stamps rows with its own execution ID before reading. Two concurrent executions can never claim the same row. Stale claims (>30 min) auto-expire.

### 3. Task timeout at 300 seconds — executions killed mid-run
The original Cloud Run Job had a 300-second task timeout. With 1000 rows and 4 workers, jobs were consistently hitting the limit and being killed before writing results.

**Fix:** updated task timeout to 600 seconds and limited each execution to 200 rows (`--limit 200`).

### 4. Cloud Build uploading 13GB — entire project directory
`gcloud builds submit` was uploading the whole project folder including the Python virtualenv (thousands of files).

**Fix:** created `.gcloudignore` as an allowlist — only `Dockerfile`, `requirements.txt`, `ai_test.py`, and `bigquery_io.py` are sent. Upload went from 13GB to 27KB.

### 5. Cloud Build failing due to org policy (US region)
`gcloud builds submit` defaulted to a US staging bucket, which was blocked by an org policy requiring all resources in `europe-west2`.

**Fix:** added `--region=europe-west2 --gcs-source-staging-dir=gs://coeus-sorites-cloudbuild-europe/source` to every build command.

### 6. Max tokens causing empty model responses (original)
Some very long jailbreak prompts (50,000+ characters) were filling the model's context window, leaving no room for output tokens. The model returned an empty string, `json.loads("")` threw `Expecting value: line 1 column 1 (char 0)`, and after 3 retries the prompt was silently marked as clean (`violation=False`).

**Fix:**
- Increased `MAX_TOKENS` from 2000 → 4096
- Added input truncation: prompts longer than 8000 characters are truncated before sending
- Added `finish_reason` check to distinguish token-limit failures from other errors

### 7. HuggingFace datasets required auth
`WildJailbreak` and `HackAPrompt` datasets were gated and required a HuggingFace token.

**Fix:** replaced with `deepset/prompt-injections` and `jackhhao/jailbreak-classification`, both public.

### 8. NSFW content in `toxic-chat` dataset
The `lmsys/toxic-chat` dataset contained graphic NSFW content that was inappropriate.

**Fix:** removed `toxic-chat` entirely. Added an NSFW keyword regex filter to `populate_user_prompts.py` that screens all prompts before insertion.

### 9. Packed batch mode — unreliable and slower
`batch_test.py` implements a "packed" strategy that sends multiple prompts in a single API call and expects a JSON array back. Benchmarking (60 items, both endpoints) showed:
- Best packed result: 1.7/s (pack=10, workers=8) — with 1 error
- Best concurrent result: 2.1/s (workers=16) — with 0 errors

Every packed configuration produced at least one empty/malformed response. vLLM already does continuous batching internally, so packing at the HTTP level adds complexity without GPU benefit.

**Result:** packed mode abandoned. Concurrent workers=16 is both faster and fully reliable.

### 10. Cloud Functions gen2 blocked by IAM permission
Attempted to deploy the endpoint lifecycle manager as a Cloud Functions gen2 function, which requires `iam.serviceaccounts.actAs` on the default compute service account for the deploying user.

**Fix:** switched to a Cloud Run Job (`endpoint-manager`) built from a pre-built container image via the existing Cloud Build pipeline. Cloud Run Jobs deployed from a pre-built image don't trigger this permission requirement, matching the pattern already working for `safeguard-classifier`.

### 11. Five orphaned Vertex AI endpoints burning GPU cost
At peak, six endpoints existed simultaneously — three with no deployed models (empty shells from abandoned deployment attempts), one misconfigured endpoint that only responded to the legacy `predict()` format and returned garbled output, the production endpoint, and the benchmark endpoint. The three GPU-backed non-production endpoints were costing ~$1.21/hr each around the clock.

**Fix:** audited all endpoints with live smoke tests, deleted the 3 empty shells and the misconfigured endpoint, leaving only production and benchmark. Then added the scheduled lifecycle manager (below) to stop overnight GPU burn.

### 12. Workers defaulted to 4 — half the available throughput
The `--workers` flag in `ai_test.py` defaulted to 4, and the Dockerfile's `ENTRYPOINT` calls `ai_test.py --bigquery` with no workers override, so the Cloud Run job was permanently running at 4 workers. Benchmarking showed 16 workers doubles throughput with no reliability cost.

**Fix:** changed `default=4` to `default=16` in the argparse definition. Also suppressed the urllib3 connection pool warning that appears at 16 workers via `logging.getLogger("urllib3.connectionpool").setLevel(logging.ERROR)`. Container rebuilt and redeployed.

### 13. 99.7% high confidence — calibration bias from all-high examples
All 43 few-shot examples in the original EXAMPLES list had `"confidence": "high"`. The model pattern-matched this and returned high for almost every prompt regardless of signal strength.

**Fix:** added 4 calibration examples showing medium and low confidence. Rule now taught:
- **high** = signal is unambiguous — no plausible innocent reading
- **medium** = two or more plausible interpretations (e.g. could be security education OR a probe)
- **low** = faint signal barely distinguishable from benign

### 14. Token limit exceeded — system prompt too large
After adding the `red_team` category with 4–5 examples, the full system prompt grew to ~2,900 tokens. With `MAX_TOKENS=4096` (output) and user prompts up to ~2,000 tokens, the total requested tokens (~9,000) far exceeded the model's 4,096-token context window. The endpoint returned `finish_reason: "length"` with empty or cut-off JSON.

**Fix:** trimmed EXAMPLES from 43 → 27 (removed duplicates and weaker anchors). System prompt now ~2,034 tokens. Reduced `MAX_TOKENS` to 1024 (output) and `MAX_INPUT_CHARS` to 3000 at the time — both later increased once the true context window (131,072 tokens) was confirmed. See current values in item 18.

### 15. MAX_TOKENS=512 caused output cutoff on legitimate responses
After reducing `MAX_TOKENS` to 512, the `trigger` field (a verbatim quote from the input) was being cut off mid-JSON for longer prompts, producing malformed output.

**Fix:** raised `MAX_TOKENS` from 512 → 1024. The trigger quote for a 3,000-character prompt is at most a few hundred characters — 1,024 output tokens is sufficient with headroom.

### 16. Resetting `claimed_by = NULL` did not trigger re-classification
After inserting new rows and wanting to re-classify already-processed prompts, `claimed_by` and `claimed_at` were reset to NULL in `user_prompts`. The scheduler still did not pick them up.

**Root cause:** `bigquery_io.fetch_unclassified()` uses a LEFT JOIN against `user_prompts_enriched` and skips any row that already has a result there:
```sql
LEFT JOIN `coeus-sorites.safeguard.user_prompts_enriched` e
    ON p.prompt_id = e.prompt_id
WHERE e.prompt_id IS NULL
```
Resetting `claimed_by` is not enough — the row must also be absent from `user_prompts_enriched`.

**Fix:** must delete rows from `user_prompts_enriched` before resetting `claimed_by`. See item 17 below for the complication that introduces.

### 18. Context window: actual limit is 4,096 tokens total (not 131,072)
During session 4, a web search reported 131,072 tokens as the context window for GPT-OSS-Safeguard-20b. This was **incorrect for this specific Vertex AI endpoint deployment**. Token usage logs from session 5 confirmed:
- `prompt: 3913  output: 183  finish: length` — 3913 + 183 = **exactly 4,096**
- `prompt: 2013  output: 80  finish: stop` — after prompt reduction, completions finish naturally

The Vertex AI endpoint for this model has a **4,096 total token context** (input + output combined). The web search result referred to a different version or configuration.

**Impact of the wrong assumption:** `MAX_INPUT_CHARS` was raised to 500,000 characters, vastly exceeding what the endpoint can handle. Any user message over ~2,000 characters would have pushed the total context over 4,096 tokens, leaving insufficient room for JSON output.

**Fix (session 5):** reduced `MAX_INPUT_CHARS` to 6,000 characters (~1,500 tokens). With a ~2,000-token system prompt and a 1,500-token user message, total = 3,500 tokens, leaving ~596 tokens for JSON output (which only needs ~80 tokens).

### 17. DELETE on `user_prompts_enriched` blocked by streaming buffer
`user_prompts_enriched` was originally written using `insert_rows_json()` (streaming inserts). BigQuery blocks DML (`DELETE`, `UPDATE`) on rows still in the streaming buffer — up to 90 minutes after insertion.

**Workaround (now superseded):** use `CREATE OR REPLACE TABLE` to rebuild the table excluding the unwanted rows:
```sql
CREATE OR REPLACE TABLE `coeus-sorites.safeguard.user_prompts_enriched` AS
SELECT * FROM `coeus-sorites.safeguard.user_prompts_enriched`
WHERE username NOT IN ('injection_user', 'jailbreak_user', 'red_team_user', 'benign_user')
```

**Root fix (session 5 — issue 20):** `bigquery_io.write_enriched()` was switched to `load_table_from_json` (batch load). Batch writes are not affected by the streaming buffer, so `DELETE`/`CREATE OR REPLACE TABLE` can follow immediately without the 90-minute wait. The CTAS workaround is still used to clear test data between evaluation runs.

### 19. System prompt too large for the 4,096-token context window
After the `red_team` category, subcategory examples, and jailbreak-vs-violence priority examples were added across sessions 4–5, the EXAMPLES list grew to 32 entries (~3,900 prompt tokens total including a short user message). With only ~183 tokens left for output, complex classification responses were truncated mid-JSON.

**The pattern was hard to diagnose because:**
- `response_format: json_object` (added to force JSON-only output) made the model use the tiny token budget on the JSON itself, causing immediate cutoffs at 183 tokens
- Without `response_format`, the model generated preamble reasoning text, consuming the 183 tokens before the JSON even started — producing even worse 65,536-token cutoffs (the error message showed max_tokens=65536 but the real limit was ~183)
- The `reasoning_effort: "low"` parameter is ignored by this model (reasoning_tokens = 0 in every response), so adjusting it had no effect

**Fix (session 5):** trimmed EXAMPLES from 32 → 15, reducing the system prompt from ~3,900 to ~2,000 tokens. With `response_format: json_object` and a 2,000-token system prompt, the typical total is ~2,093 tokens, leaving ~2,000 tokens for output. JSON output is ~50-120 tokens, so there is ample headroom with 0 errors across 200 prompts.

### 21. `g2-standard-24` capacity unavailable in europe-west2 (session 6)
Attempted to deploy a large-context endpoint (2× NVIDIA L4, `g2-standard-24`, 16K token context) to support user prompts of 20K+ tokens. Two attempts failed with:
```
google.api_core.exceptions.ServiceUnavailable: 503 Machine type temporarily unavailable.
Machine type: "g2-standard-24". Accelerator type: "nvidia-l4".
```
GCP recommended `asia-northeast1` — not acceptable due to org policy and data residency.

**Terraform discovery:** Inspecting the original `terraform_extracted/terraform/main.tf` revealed that multi-GPU vLLM deployments require `--tensor-parallel-size=N` to be passed explicitly as a serving container arg, otherwise vLLM will attempt to load the model on a single GPU. This was missing from the initial script and has been corrected in `deploy_endpoint.py`.

**Current state:** `deploy_endpoint.py` is correct and ready. Pending a decision on:
- **Option A:** Retry `g2-standard-24` in europe-west2 (capacity may free up)
- **Option B:** Switch to `a2-highgpu-1g` (single A100 40GB, europe-west2) — update machine_type and remove `--tensor-parallel-size=2`

### 20. `insert_rows_json` on enriched fails with "Table is truncated" after CTAS
After each `CREATE OR REPLACE TABLE` cleanup, streaming inserts (`insert_rows_json`) into `user_prompts_enriched` failed with:
```
google.api_core.exceptions.NotFound: 404 ... Table is truncated.
```
This is a BigQuery restriction: streaming inserts are blocked for an indeterminate period after a table is recreated via CTAS. The container would claim 200 rows, classify them all, then fail to write results — causing those rows to remain in a "claimed but not enriched" limbo for 30 minutes until the stale claim expired.

**Fix:** switched `bigquery_io.write_enriched()` from `client.insert_rows_json()` to `client.load_table_from_json()` (batch load job). Batch loads are not subject to the streaming buffer restriction and succeed immediately after CTAS.

---

## Next Steps

### Immediate — large-context endpoint (blocked on GCP capacity)
`deploy_endpoint.py` is ready and correct. Two attempts to deploy `g2-standard-24` (2× NVIDIA L4, 16K token context) in europe-west2 failed with 503 capacity errors (see issue 21). Two options to unblock:

- **Option A:** Retry `g2-standard-24` in europe-west2 — run `python deploy_endpoint.py` again, capacity may have freed up
- **Option B:** Switch to `a2-highgpu-1g` (single A100 40GB, europe-west2) — update `deploy_endpoint.py` machine_type and remove `--tensor-parallel-size=2`; costs ~$4–5/hr, same region, better availability

Once deployed, update `SAFEGUARD_ENDPOINT` in `ai_test.py` (line 37) or set the env var, then update `MAX_INPUT_CHARS` from 6,000 to ~80,000 to allow 20K+ token user prompts.

### If further classifier improvement is wanted
1. **Add encoding-detection example** — the one missed injection is a Morse-code encoded prompt. Add one example of encoded injection → `prompt_injection/encoded_injection`. Safe within the 4,096-token budget at current ~2,000 prompt tokens.
2. **MITRE ATLAS mapping** — map categories to MITRE ATLAS taxonomy (AML.T0051.000 direct injection, AML.T0051.001 indirect injection, AML.T0054 jailbreak) for SOC integration. Post-processing step or additional output field, no classifier schema change needed.

### Architecture evolution
3. **Inline tool call from AI agent** — `SafeguardClient` in `ai_test.py` can be imported directly. Call `safeguard.classify(user_message)` before forwarding to the main model. If `result.violation` is True, block the request. Still write results to `user_prompts_enriched` for audit.
4. **Pub/Sub for scale** — replace the BigQuery polling architecture with Pub/Sub. Prompts publish to a topic, Cloud Run Service subscribes and classifies, results write to BigQuery. Reduces latency from up to 5 minutes to ~2 seconds.

### Future
5. Alerting when violations are detected (email/Slack/webhook for high-confidence violations)
6. Looker Studio dashboard over `user_prompts_enriched` — category breakdown, subcategory heatmap, confidence distribution

---

## Google Cloud Locations

**Project:** `coeus-sorites` | **Region:** `europe-west2` (all resources)

| Service | Resource | Details |
|---|---|---|
| Vertex AI | Endpoint `3279942141702307840` | Production — GPT-OSS-Safeguard-20b, g2-standard-12 + NVIDIA L4, 4,096 token context |
| BigQuery | Dataset `safeguard` | Tables: `user_prompts`, `user_prompts_enriched` |
| Artifact Registry | `safeguard/classifier:latest` | `europe-west2-docker.pkg.dev/coeus-sorites/safeguard/classifier:latest` |
| Cloud Build | Staging bucket | `gs://coeus-sorites-cloudbuild-europe/source` |
| Cloud Run Jobs | `safeguard-classifier` | Entrypoint: `python ai_test.py --bigquery`, limit 200, 600s timeout |
| Cloud Scheduler | `safeguard-classifier-schedule` | `*/5 * * * *` — triggers the classifier job |

> **Note:** The benchmark endpoint (`6085684709554126848`) and endpoint lifecycle manager were decommissioned in session 6. Endpoints run 24/7 — the ~$2.42/hr idle cost is acceptable and the risk of a failed redeploy blocking the classifier is not worth it.

---

## Architecture Overview

### Classifier pipeline (runs every 5 minutes)

```
Every 5 minutes
      |
      v
Cloud Scheduler (safeguard-classifier-schedule)
      |  HTTP trigger
      v
Cloud Run Job (safeguard-classifier)
      |
      |-- 1. UPDATE user_prompts SET claimed_by = execution_id
      |        (atomic lock — prevents duplicate processing)
      |
      |-- 2. SELECT back claimed rows (up to 200)
      |        Skips rows already in user_prompts_enriched (LEFT JOIN filter)
      |
      |-- 3. Send each prompt to Vertex AI endpoint (3279942141702307840)
      |        16 concurrent threads
      |        System prompt: safety policy + 15 few-shot examples (~2,000 tokens of a 4,096-token window)
      |        Model returns: violation, category, confidence, trigger, rationale
      |
      +-- 4. Write results to user_prompts_enriched
                (batch load — load_table_from_json, immediately DML-claimable)
```

### BigQuery schema

**`user_prompts`** — raw input
```
prompt_id    STRING    PRIMARY
username     STRING
prompt_text  STRING
created_at   TIMESTAMP
claimed_by   STRING    (execution ID that has reserved this row)
claimed_at   TIMESTAMP (when it was claimed — stale after 30 min)
```

**`user_prompts_enriched`** — classification output
```
prompt_id    STRING
username     STRING
prompt_text  STRING
violation    BOOL
category     STRING    (prompt_injection / jailbreak / red_team / harassment / hate_speech / violence / illegal)
confidence   STRING    (high / medium / low)
trigger      STRING    (exact quote from input that triggered the flag)
rationale    STRING    (one-sentence explanation)
classified_at TIMESTAMP
```

> **Note on re-classification:** resetting `claimed_by = NULL` in `user_prompts` is NOT sufficient to trigger re-classification. The row must also be absent from `user_prompts_enriched` (see failures 16–17). Use the `CREATE OR REPLACE TABLE` workaround when clearing results for already-processed rows.

### Detection categories

| Category | What it flags |
|---|---|
| `prompt_injection` | Attempts to override or hijack system instructions |
| `jailbreak` | Attempts to bypass safety guidelines or adopt unrestricted personas |
| `red_team` | Adversarial reconnaissance — probing, mapping, or strategising around safety mechanisms without necessarily requesting harmful content yet |
| `harassment` | Targeted attacks, threats, encouragement of self-harm |
| `hate_speech` | Slurs or hostility toward protected groups |
| `violence` | Promoting or inciting physical harm |
| `illegal` | Instructions for crimes or dangerous acts |
