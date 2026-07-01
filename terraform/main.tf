terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# Ensure Vertex AI API is enabled
resource "google_project_service" "aiplatform" {
  service            = "aiplatform.googleapis.com"
  disable_on_destroy = false
}

# Upload the model to Vertex AI Model Registry
resource "google_vertex_ai_model" "gpt_oss_safeguard" {
  name         = var.model_name
  display_name = var.model_name
  location     = var.region
  description  = "OpenAI gpt-oss-safeguard-20b served via vLLM"

  container_spec {
    image_uri = var.vllm_image_uri
    args = [
      "python",
      "-m",
      "vllm.entrypoints.api_server",
      "--host=0.0.0.0",
      "--port=8080",
      "--model=${var.model_id}",
      "--tensor-parallel-size=${var.accelerator_count}",
      "--gpu-memory-utilization=${var.gpu_memory_utilization}",
      "--max-model-len=16384",
      "--dtype=${var.dtype}",
      "--max-num-seqs=${var.max_num_seqs}",
      "--disable-log-stats",
    ]

    env {
      name  = "MODEL_ID"
      value = var.model_id
    }

    env {
      name  = "DEPLOY_SOURCE"
      value = "terraform"
    }

    predict_route  = "/generate"
    health_route   = "/ping"
    grpc_ports { container_port = 8080 }
  }

  depends_on = [google_project_service.aiplatform]
}

# Create a dedicated endpoint
resource "google_vertex_ai_endpoint" "gpt_oss_safeguard" {
  name                        = var.model_name
  display_name                = var.model_name
  location                    = var.region
  dedicated_endpoint_enabled  = var.use_dedicated_endpoint

  depends_on = [google_project_service.aiplatform]
}

# Deploy the model to the endpoint (no native TF resource — use gcloud)
resource "null_resource" "deploy_model" {
  triggers = {
    model_id      = google_vertex_ai_model.gpt_oss_safeguard.id
    endpoint_id   = google_vertex_ai_endpoint.gpt_oss_safeguard.id
    machine_type  = var.machine_type
    accelerator   = var.accelerator_type
    replica_count = var.accelerator_count
  }

  provisioner "local-exec" {
    command = <<-EOT
      gcloud ai endpoints deploy-model ${google_vertex_ai_endpoint.gpt_oss_safeguard.name} \
        --region=${var.region} \
        --project=${var.project_id} \
        --model=${google_vertex_ai_model.gpt_oss_safeguard.name} \
        --display-name=${var.model_name}-deployed \
        --machine-type=${var.machine_type} \
        --accelerator=type=${var.accelerator_type},count=${var.accelerator_count} \
        --min-replica-count=${var.min_replica_count} \
        --max-replica-count=${var.max_replica_count} \
        --traffic-split=0=100 \
        --quiet
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      gcloud ai endpoints undeploy-model ${google_vertex_ai_endpoint.gpt_oss_safeguard.name} \
        --region=${var.region} \
        --project=${var.project_id} \
        --deployed-model-id=${var.model_name}-deployed \
        --quiet || true
    EOT
  }

  depends_on = [
    google_vertex_ai_model.gpt_oss_safeguard,
    google_vertex_ai_endpoint.gpt_oss_safeguard,
  ]
}
