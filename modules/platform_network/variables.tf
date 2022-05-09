variable "environment" {
  description = "Environment to deploy in"
  type        = string
}
variable "stage" {
  description = "Stage to deploy in"
  type        = string
}
variable "prefix" {
  description = "prefix"
  type        = string
}
variable "project" {
  description = "Full project or product name, to be used in tags or descriptions"
}
