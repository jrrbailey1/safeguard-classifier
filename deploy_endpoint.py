"""
Redeploy GPT-OSS-Safeguard-20b to the existing production endpoint.

Endpoint ID: 3279942141702307840
Model ID:    4790875627429298176
Hardware:    g2-standard-12 (1x NVIDIA L4, 24GB VRAM)
Context:     4,096 tokens

Use this to bring the production endpoint back up after undeploying.
The endpoint ID is preserved so ai_test.py requires no changes.
"""

from google.cloud import aiplatform

PROJECT   = "coeus-sorites"
REGION    = "europe-west2"
ENDPOINT_ID = "3279942141702307840"
MODEL_ID    = "4790875627429298176"

aiplatform.init(project=PROJECT, location=REGION)

endpoint = aiplatform.Endpoint(
    endpoint_name=f"projects/{PROJECT}/locations/{REGION}/endpoints/{ENDPOINT_ID}"
)

model = aiplatform.Model(
    model_name=f"projects/196719958324/locations/{REGION}/models/{MODEL_ID}"
)

print(f"Redeploying model to endpoint {ENDPOINT_ID} — this takes ~10 minutes...")

endpoint.deploy(
    model=model,
    machine_type="g2-standard-12",
    accelerator_type="NVIDIA_L4",
    accelerator_count=1,
    min_replica_count=1,
    max_replica_count=1,
    traffic_percentage=100,
    deploy_request_timeout=1800,
)

print(f"\nEndpoint {ENDPOINT_ID} is back online.")
print(f"No changes needed in ai_test.py — endpoint ID is unchanged.")
