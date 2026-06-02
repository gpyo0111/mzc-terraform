variable "cluster_name" {
  type    = string
  default = "securevoice-dev-cluster"
}

variable "free_worker_service_name" {
  type    = string
  default = "securevoice-dev-free-worker-service"
}

variable "paid_worker_service_name" {
  type    = string
  default = "securevoice-dev-paid-worker-service"
}

variable "free_queue_name" {
  type    = string
  default = "free-queue"
}

variable "paid_queue_name" {
  type    = string
  default = "paid-queue"
}
