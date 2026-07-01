output "endpoint_id" {
  description = "Vertex AI endpoint ID"
  value       = google_vertex_ai_endpoint.gpt_oss_safeguard.name
}

output "model_id" {
  description = "Vertex AI model ID"
  value       = google_vertex_ai_model.gpt_oss_safeguard.name
}

output "region" {
  description = "Deployment region"
  value       = var.region
}
