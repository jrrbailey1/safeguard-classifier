"""
Deploy GPT-OSS-Safeguard-20b to a BRAND NEW Vertex AI endpoint.

Use this when you need an additional endpoint (e.g. benchmark, large-context upgrade).
For redeploying to the existing production endpoint, use deploy_endpoint.py instead.

Current configuration: g2-standard-24 (2x NVIDIA L4, 48GB VRAM)
Context window: 16,384 tokens — supports longer user prompts than the production endpoint.

After deployment the script prints the new endpoint ID.
Set SAFEGUARD_ENDPOINT=<new_id> or update ai_test.py line 37 to use it.
"""

import vertexai
from vertexai import model_garden

PROJECT = "coeus-sorites"
REGION  = "europe-west2"

vertexai.init(project=PROJECT, location=REGION)

model = model_garden.OpenModel("hf-openai/gpt-oss-safeguard-20b@001")

print("Deploying to a new endpoint — this takes ~10 minutes...")

endpoint = model.deploy(
    accept_eula=True,
    machine_type="g2-standard-24",
    accelerator_type="NVIDIA_L4",
    accelerator_count=2,
    use_dedicated_endpoint=True,
    reservation_affinity_type="ANY_RESERVATION",
    endpoint_display_name="gpt-oss-safeguard-20b-large-context",
    model_display_name="gpt-oss-safeguard-20b-large-context",
    deploy_request_timeout=1800,
    fast_tryout_enabled=False,
    serving_container_args=[
        "--tensor-parallel-size=2",
        "--max-model-len=16384",
        "--gpu-memory-utilization=0.9",
        "--max-num-seqs=256",
        "--dtype=auto",
    ],
)

print(f"\nEndpoint deployed successfully.")
print(f"Endpoint ID: {endpoint.name.split('/')[-1]}")
print(f"\nTo use this endpoint:")
print(f"  Set SAFEGUARD_ENDPOINT={endpoint.name.split('/')[-1]}")
print(f"  Or update ENDPOINT_ID in ai_test.py line 37.")
