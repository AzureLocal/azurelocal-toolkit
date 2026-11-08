# cicd-infra

Root module for task 06 of automation / 01-cicd-infra: the self-hosted runners, as Terraform. It composes [`modules/cicd-runner`](../../modules/cicd-runner) into two pools:

| Pool | OS | Purpose | Jobs |
| --- | --- | --- | --- |
| `runners_linux` | Linux | `general` | ARM, Arc, Terraform, Ansible, OS configuration |
| `runners_ztp` | Windows | `ztp` | azurelocal-ztp Boot, Bootstrap, Vouchers (BMCs connect to it on TCP 445) |

```powershell
cd src/terraform/environments/cicd-infra
Copy-Item terraform.tfvars.example ../../../../../cicd-terraform.tfvars   # edit; keep it outside the repository
Copy-Item backend.hcl.example     ../../../../../cicd-backend.hcl        # edit

terraform init -backend-config=../../../../../cicd-backend.hcl
terraform validate
terraform plan -var-file=../../../../../cicd-terraform.tfvars -out=cicd.tfplan
# review the plan, then:
terraform apply cicd.tfplan
```

Offline check, no Azure sign-in: `terraform init -backend=false; terraform validate`.

The same flow runs from a pipeline: `pipelines/github-actions/cicd-infra.yml`, `pipelines/gitlab/stages/deploy-cicd-infra.yml`, `pipelines/azure-devops/cicd-infra.yml`. See [`docs/cicd-infra-deployment.md`](../../../../docs/cicd-infra-deployment.md).
