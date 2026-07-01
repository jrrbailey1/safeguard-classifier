# Architecture — AI Prompt Safety Classifier

## End-to-End Pipeline

```mermaid
flowchart TD
    subgraph INPUT ["Input"]
        USER["User / AI Agent"]
        APP["Application"]
        UP[("BigQuery\nuser_prompts\n───────────\nprompt_id\nusername\nprompt_text\ncreated_at\nclaimed_by · claimed_at")]
    end

    subgraph ORCH ["Orchestration"]
        CS["Cloud Scheduler\ncron: every 5 minutes"]
    end

    subgraph CRJ ["Cloud Run Job — safeguard-classifier\n(europe-west2 · 600s timeout)"]
        CLAIM["① Atomic row claim\nUPDATE claimed_by = execution_id\nPrevents duplicate processing across concurrent executions"]
        FETCH["② Fetch claimed rows\nLEFT JOIN filter — skips already-enriched rows\nUp to 200 rows per execution"]
        POOL["③ ThreadPoolExecutor — 16 concurrent workers\nOne HTTP request to Vertex AI per worker"]
    end

    subgraph VAI ["Vertex AI — europe-west2"]
        EP["Endpoint 3279942141702307840\nModel: openai/gpt-oss-safeguard-20b\nHardware: g2-standard-12 · NVIDIA L4 GPU\nContext window: 4,096 tokens total"]
        SYS["System prompt\n15 few-shot examples\n~2,000 tokens\nresponse_format: json_object"]
    end

    subgraph OUTPUT ["Output"]
        UPE[("BigQuery\nuser_prompts_enriched\n─────────────────────\nviolation  · category · subcategory\nconfidence · trigger  · rationale\nclassified_at")]
    end

    USER --> APP
    APP -->|"Write prompt\nload_table_from_json\nbatch load — immediately DML-claimable"| UP

    CS -->|"HTTP trigger"| CLAIM
    UP --> CLAIM
    CLAIM --> FETCH
    FETCH --> POOL

    SYS -..->|"Injected into every request"| EP
    POOL -->|"POST /chat/completions\njson_object · max_tokens=65536"| EP
    EP -->|"violation · category · confidence\ntrigger · rationale"| POOL

    POOL -->|"load_table_from_json\nbatch write"| UPE

```

---

## Token Budget (4,096 total context window)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  4,096 tokens total                                                          │
├──────────────────────────────┬──────────────────────┬───────────────────────┤
│  System prompt               │  User input          │  JSON output          │
│  ~2,000 tokens               │  up to ~1,500 tokens │  ~80–120 tokens       │
│  (15 few-shot examples +     │  (6,000 char cap     │  violation · category │
│   safety policy)             │   enforced in code)  │  confidence · trigger │
└──────────────────────────────┴──────────────────────┴───────────────────────┘
```

---

## Data Flow — Step by Step

| Step | Component | What happens |
|------|-----------|--------------|
| 1 | Application | User prompt written to `user_prompts` via batch load |
| 2 | Cloud Scheduler | Fires an HTTP trigger every 5 minutes |
| 3 | Cloud Run Job | `UPDATE user_prompts SET claimed_by = execution_id` — atomic lock prevents two workers processing the same row |
| 4 | Cloud Run Job | `SELECT` back only the claimed rows; skip any already present in `user_prompts_enriched` |
| 5 | Vertex AI | Each of 16 workers sends one prompt as an OpenAI-compatible chat request; system prompt + user message fit within 4,096-token window |
| 6 | Vertex AI | Model returns structured JSON: `violation`, `category`, `subcategory`, `confidence`, `trigger`, `rationale` |
| 7 | Cloud Run Job | Results written to `user_prompts_enriched` via batch load (`load_table_from_json`) |

---

## Detection Categories

| Category | What it flags |
|---|---|
| `prompt_injection` | Instructions embedded in external content (documents, emails, data) attempting to override the AI |
| `jailbreak` | Attempts to bypass safety guidelines via personas, fictional framing, or mode activation |
| `red_team_recon` | Mapping the AI's refusal limits and safety boundaries |
| `red_team_bypass` | Soliciting advice on how to circumvent the AI's content policy |
| `red_team_probe` | Systematic threshold testing — escalating questions to find where refusals begin |
| `red_team_vuln` | Probing for known weaknesses in the model's safety training |
| `harassment` | Threats or targeted attacks against individuals |
| `hate_speech` | Slurs or hostility toward protected groups |
| `violence` | Content promoting or inciting physical harm |
| `illegal` | Requests for instructions relating to crimes or dangerous acts |

---

## Google Cloud Resources

| Resource | ID / Name | Details |
|---|---|---|
| Vertex AI Endpoint | `3279942141702307840` | Production — GPT-OSS-Safeguard-20b, g2-standard-12 + NVIDIA L4 |
| BigQuery Dataset | `coeus-sorites.safeguard` | Tables: `user_prompts`, `user_prompts_enriched` |
| Cloud Run Job | `safeguard-classifier` | `python ai_test.py --bigquery --limit 200`, 600s timeout |
| Cloud Scheduler | `safeguard-classifier-schedule` | `*/5 * * * *`, europe-west2 |
| Artifact Registry | `safeguard/classifier:latest` | `europe-west2-docker.pkg.dev/coeus-sorites/safeguard/classifier:latest` |
| Cloud Build | Staging bucket | `gs://coeus-sorites-cloudbuild-europe/source` |
| Cloud Run Job | `endpoint-manager` | Reads `ACTION` env var (`deploy`/`undeploy`), 1200s timeout |
