terraform {
  required_version = ">= 1.5"

  required_providers {
    ferriskey = {
      source  = "ferriskey/ferriskey"
      version = "~> 0.2.0"
    }
  }
}
