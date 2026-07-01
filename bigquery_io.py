"""BigQuery I/O helpers for the safeguard pipeline.

Provides two functions used by cmd_bigquery():
  - fetch_unclassified: atomically claims and returns rows from user_prompts not yet enriched
  - write_enriched:     inserts classification results into user_prompts_enriched

Row claiming prevents race conditions when multiple Cloud Run Job executions overlap:
each execution claims its own batch via a DML UPDATE before reading, so two concurrent
executions can never process the same row.
"""

from __future__ import annotations

import logging
import os
from datetime import datetime, timezone

from google.cloud import bigquery

log = logging.getLogger(__name__)

PROJECT = os.environ.get("SAFEGUARD_PROJECT", "coeus-sorites")
DATASET = os.environ.get("SAFEGUARD_DATASET", "safeguard")

# Rows claimed this many minutes ago but still not in enriched are considered stale
# and eligible for reclaiming by a new execution (handles crashed/timed-out runs)
CLAIM_TIMEOUT_MINUTES = 30


def fetch_unclassified(client: bigquery.Client, execution_id: str, limit: int = 500) -> list[dict]:
    """Atomically claims up to `limit` unclassified rows and returns them.

    Uses a BigQuery DML UPDATE to mark rows with this execution's ID before reading.
    Because BigQuery serialises DML writes, two concurrent executions cannot claim
    the same row.

    Rows that were claimed more than CLAIM_TIMEOUT_MINUTES ago but never written to
    user_prompts_enriched are treated as stale and re-eligible for claiming.
    """

    # Step 1: atomically claim unclaimed (or stale) rows for this execution
    claim_sql = f"""
        UPDATE `{PROJECT}.{DATASET}.user_prompts`
        SET claimed_by = @execution_id,
            claimed_at = CURRENT_TIMESTAMP()
        WHERE prompt_id IN (
            SELECT p.prompt_id
            FROM `{PROJECT}.{DATASET}.user_prompts` p
            LEFT JOIN `{PROJECT}.{DATASET}.user_prompts_enriched` e
                ON p.prompt_id = e.prompt_id
            WHERE e.prompt_id IS NULL
              AND (
                p.claimed_at IS NULL
                OR TIMESTAMP_DIFF(CURRENT_TIMESTAMP(), p.claimed_at, MINUTE) > {CLAIM_TIMEOUT_MINUTES}
              )
            LIMIT {limit}
        )
    """
    job_config = bigquery.QueryJobConfig(
        query_parameters=[bigquery.ScalarQueryParameter("execution_id", "STRING", execution_id)]
    )
    claim_job = client.query(claim_sql, job_config=job_config)
    claim_job.result()
    rows_claimed = claim_job.num_dml_affected_rows
    log.info("Claimed %d row(s) for execution %s", rows_claimed, execution_id)

    if rows_claimed == 0:
        return []

    # Step 2: read back only the rows this execution claimed
    select_sql = f"""
        SELECT prompt_id, username, prompt_text, created_at
        FROM `{PROJECT}.{DATASET}.user_prompts`
        WHERE claimed_by = @execution_id
          AND prompt_id NOT IN (
              SELECT prompt_id FROM `{PROJECT}.{DATASET}.user_prompts_enriched`
          )
        ORDER BY created_at ASC
    """
    rows = list(client.query(select_sql, job_config=job_config).result())
    log.info("Fetched %d unclassified prompt(s) from BigQuery", len(rows))
    return [dict(row) for row in rows]


def write_enriched(client: bigquery.Client, prompts: list[dict], results: list) -> int:
    """Inserts classification results into user_prompts_enriched.

    Args:
        client:  BigQuery client
        prompts: list of prompt dicts returned by fetch_unclassified
        results: list of Classification objects in the same order as prompts

    Returns:
        Number of rows successfully written.
    """

    # Stamp all rows in this batch with the same classified_at time
    classified_at = datetime.now(timezone.utc).isoformat()

    rows = [
        {
            "prompt_id":     prompt["prompt_id"],
            "username":      prompt["username"],
            "prompt_text":   prompt["prompt_text"],
            "violation":     result.violation,
            "category":      result.category.value if result.category else None,
            "subcategory":   result.subcategory,
            "confidence":    result.confidence.value,
            "trigger":       result.trigger,
            "rationale":     result.rationale,
            "classified_at": classified_at,
        }
        for prompt, result in zip(prompts, results)
    ]

    # Use load_table_from_json (batch load) rather than insert_rows_json (streaming) so
    # that writes succeed even after a CREATE OR REPLACE TABLE on user_prompts_enriched.
    # Streaming inserts throw "Table is truncated" for an indeterminate period after CTAS.
    job_config = bigquery.LoadJobConfig(
        write_disposition=bigquery.WriteDisposition.WRITE_APPEND,
    )
    load_job = client.load_table_from_json(
        rows,
        f"{PROJECT}.{DATASET}.user_prompts_enriched",
        job_config=job_config,
    )
    load_job.result()  # raises GoogleAPICallError on failure

    log.info("Wrote %d enriched result(s) to BigQuery", len(rows))
    return len(rows)
