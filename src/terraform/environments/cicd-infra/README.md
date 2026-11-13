# cicd-infra

Root module for task 06 of automation / 01-cicd-infra: the self-hosted runners, as Terraform. It composes [`modules/cicd-runner`](../../modules/cicd-runner) into two pools:

| Pool | OS | Purpose | Jobs |
| --- | --- | --- | --- |
| `runners_linux` | Linux | `general` | ARM, Arc, Terraform, Ansible, OS configuration |
| `runners_ztp` | Windows | `ztp` | azurelocal-ztp Boot, Bootstrap, Vouchers (BMCs connect to it on TCP 445) |

The variables come from the `devops`, `azure`, `key_vaults`, `landing_zone` and `tags` sections of `infrastructure.yml`. Write them, and the backend settings, with the generator (it calls the function that task 06 uses, so the two are the same):

```powershell
pwsh config/variables/scripts/New-IacVariableFiles.ps1 -InfrastructureFile ./infrastructure.yml -OutputDirectory D:\work\iac -Target CicdInfra
Copy-Item terraform.tfvars.example D:\work\iac\extra.tfvars   # the settings the file has no key for; optional

cd src/terraform/environments/cicd-infra
terraform init -backend-config=D:\work\iac\terraform\cicd-infra\backend.hcl
terraform validate
terraform plan -var-file=D:\work\iac\terraform\cicd-infra\terraform.tfvars.json -out=cicd.tfplan
# review the plan, then:
terraform apply cicd.tfplan
```

The public key of the Linux runners is not in the file. Pass it as `TF_VAR_admin_ssh_public_key` (the generator names it in `not-written.txt`).

Offline check, no Azure sign-in: `terraform init -backend=false; terraform validate`.

The same flow runs from a pipeline: `pipelines/github-actions/cicd-infra.yml`, `pipelines/gitlab/stages/deploy-cicd-infra.yml`, `pipelines/azure-devops/cicd-infra.yml`. See [`docs/cicd-infra-deployment.md`](../../../../docs/cicd-infra-deployment.md).
