# Terraform State & Worker Refactor

## State Decoupling

Previously, all infrastructure; MySQL, Keycloak, the KenyaEMR hub, and every tenant lived in a single, bundled Terraform state file. This meant any change to a single tenant carried the shared infrastructure in the same blast radius as that tenant's own resources, and a plan/apply cycle always had to reason about the entire fleet at once. State has now been split into two tiers, both backed by S3: an **infrastructure state** holding MySQL, Keycloak, and the KenyaEMR hub, and **individual per-tenant states**, one S3 key per tenant (`terraform/tenants/<id>/terraform.tfstate`). Existing tenants were migrated out of the bundled state into their own state files using `terraform state mv`, which only moves Terraform's internal bookkeeping no infrastructure was created, changed, or destroyed during the migration itself.

## Worker Script Changes

The worker previously generated a single `tenants.auto.tfvars.json` covering every enabled tenant, then ran `init`/`plan`/`apply` once against the shared root Terraform directory for any tenant action, meaning an ENABLE, DISABLE, or DELETE for one tenant caused Terraform to plan and potentially apply changes across the entire tenant fleet in a single run. The worker now scaffolds an isolated working directory per tenant (`backend.tf`, `variables.tf`, `main.tf`, `terraform.tfvars`, generated fresh from that tenant's row in Postgres), pointing at that tenant's own S3 state key. Terraform `init`/`plan`/`apply` now run scoped to exactly one tenant's directory and state file, so an action on one tenant can no longer affect any other tenant's infrastructure, and state for new or newly-migrated tenants lands directly in its dedicated S3 location as a normal part of that run.

## State Backend Locations

All state now lives in the same S3 bucket, split by key prefix:

| State | Bucket | Region | Key |
|---|---|---|---|
| Infrastructure (MySQL, Keycloak, KenyaEMR hub) | `<county-name>-wal-archive-prod` | `af-south-1` | `terraform/infrastructure/terraform.tfstate` |
| Per-tenant (one per tenant) | `<county-name>-wal-archive-prod` | `af-south-1` | `terraform/tenants/<tenant_id>/terraform.tfstate` |
