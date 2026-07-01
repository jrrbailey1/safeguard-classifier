variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region (must be allowed by org policy)"
  type        = string
  default     = "europe-west2"
}

variable "model_name" {
  description = "Display name for the model and endpoint"
  type        = string
  default     = "gpt-oss-safeguard-20b"
}

variable "model_id" {
  description = "HuggingFace model ID to serve"
  type        = string
  default     = "openai/gpt-oss-safeguard-20b"
}

variable "vllm_image_uri" {
  description = "Vertex AI prebuilt vLLM container image"
  type        = string
  default     = "us-docker.pkg.dev/vertex-ai/vertex-vision-model-garden-dockers/pytorch-vllm-serve:20260622_0916_RC01"
}

variable "machine_type" {
  description = "Compute machine type"
  type        = string
  default     = "g2-standard-12"
}

variable "accelerator_type" {
  description = "GPU accelerator type"
  type        = string
  default     = "NVIDIA_L4"
}

variable "accelerator_count" {
  description = "Number of GPUs (also sets tensor-parallel-size)"
  type        = number
  default     = 1
}

variable "gpu_memory_utilization" {
  description = "Fraction of GPU memory to use"
  type        = string
  default     = "0.9"
}

variable "max_model_len" {
  description = "Maximum model context length"
  type        = string
  default     = "4096"
}

variable "dtype" {
  description = "Data type for inference"
  type        = string
  default     = "auto"
}

variable "max_num_seqs" {
  description = "Maximum number of sequences per batch"
  type        = string
  default     = "256"
}

variable "use_dedicated_endpoint" {
  description = "Enable dedicated endpoint"
  type        = bool
  default     = true
}

variable "min_replica_count" {
  description = "Minimum number of replicas (always-on)"
  type        = number
  default     = 1
}

variable "max_replica_count" {
  description = "Maximum number of replicas (autoscaling ceiling)"
  type        = number
  default     = 2
}
