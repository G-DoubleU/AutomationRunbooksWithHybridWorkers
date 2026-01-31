# Azure Automation Hybrid Worker with Private Endpoints

Terraform project demonstrating secure Azure infrastructure with a hybrid runbook worker accessing Key Vault through a private endpoint.

## Features

- Secure Key Vault access via private endpoint (no public internet)
- Cost-optimized with scheduled VM start/stop (~80% cost reduction)
- RBAC-based authentication with managed identities
- Infrastructure as Code using Terraform

## Quick Start
```bash
# Clone and navigate
git clone https://github.com/G-DoubleU/AutomationRunbooksWithHybridWorkers.git
cd AutomationRunbooksWithHybridWorkers

# Deploy
terraform init
terraform apply
```

## Architecture

- Azure Automation Account with hybrid worker VM
- Private endpoint for network-isolated Key Vault access
- Scheduled runbooks for automated VM lifecycle management
- RBAC roles for secure service-to-service authentication

## Cleanup
```bash
terraform destroy
```

## Blog Post

Read more:

## License

MIT
