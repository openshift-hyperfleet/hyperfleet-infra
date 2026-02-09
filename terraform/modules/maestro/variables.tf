variable "namespace" {
  description = "Namespace for Maestro components"
  type        = string
  default     = "maestro"
}

variable "consumer_name" {
  description = "Consumer/cluster name for the Maestro agent"
  type        = string
  default     = "cluster1"
}

variable "server_replicas" {
  description = "Number of Maestro server replicas"
  type        = number
  default     = 1
}

variable "enable_postgres" {
  description = "Deploy embedded PostgreSQL database"
  type        = bool
  default     = true
}

variable "enable_mqtt_broker" {
  description = "Deploy embedded MQTT broker (Mosquitto)"
  type        = bool
  default     = true
}

variable "labels" {
  description = "Common labels to apply to resources"
  type        = map(string)
  default     = {}
}
