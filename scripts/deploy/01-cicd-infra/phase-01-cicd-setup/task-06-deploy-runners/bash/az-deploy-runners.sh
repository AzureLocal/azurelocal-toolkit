#!/usr/bin/env bash
# ==============================================================================
# Script:  az-deploy-runners.sh
# Purpose: Bootstrap script for on-premises CI/CD runner installation
# Usage:   ./az-deploy-runners.sh --platform github|gitlab|azdo --token <token> --url <url>
# Prereqs: Ubuntu 22.04 LTS, outbound HTTPS to SCM platform and Azure APIs
# ==============================================================================

set -euo pipefail

PLATFORM=""
REGISTRATION_TOKEN=""
ORG_URL=""
RUNNER_NAME="onprem-runner-01"
RUNNER_LABELS="onprem,terraform,ansible"
AGENT_POOL="OnPremRunners"

usage() {
  echo "Usage: $0 --platform github|gitlab|azdo --token <token> --url <org-url> [--name <runner-name>]"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --platform) PLATFORM="$2"; shift 2 ;;
    --token)    REGISTRATION_TOKEN="$2"; shift 2 ;;
    --url)      ORG_URL="$2"; shift 2 ;;
    --name)     RUNNER_NAME="$2"; shift 2 ;;
    *) usage ;;
  esac
done

[[ -z "$PLATFORM" || -z "$REGISTRATION_TOKEN" || -z "$ORG_URL" ]] && usage

# ── Install required tools ────────────────────────────────────────────────────
install_tools() {
  echo "Installing required tools..."

  # Terraform
  sudo apt-get update && sudo apt-get install -y gnupg software-properties-common
  wget -O- https://apt.releases.hashicorp.com/gpg | gpg --dearmor | \
    sudo tee /usr/share/keyrings/hashicorp-archive-keyring.gpg > /dev/null
  echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
    https://apt.releases.hashicorp.com $(lsb_release -cs) main" | \
    sudo tee /etc/apt/sources.list.d/hashicorp.list
  sudo apt-get update && sudo apt-get install -y terraform

  # Azure CLI
  curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

  # Ansible
  sudo apt-get install -y python3-pip
  pip3 install ansible

  # PowerShell
  sudo apt-get install -y powershell

  echo "Tools installed."
}

# ── GitHub Actions runner ─────────────────────────────────────────────────────
install_github_runner() {
  mkdir -p actions-runner && cd actions-runner
  curl -o actions-runner-linux-x64.tar.gz -L \
    https://github.com/actions/runner/releases/latest/download/actions-runner-linux-x64-2.321.0.tar.gz
  tar xzf actions-runner-linux-x64.tar.gz

  ./config.sh \
    --url "$ORG_URL" \
    --token "$REGISTRATION_TOKEN" \
    --name "$RUNNER_NAME" \
    --labels "$RUNNER_LABELS" \
    --work "_work" \
    --runasservice

  sudo ./svc.sh install
  sudo ./svc.sh start
  echo "GitHub Actions runner installed and started."
}

# ── GitLab runner ─────────────────────────────────────────────────────────────
install_gitlab_runner() {
  curl -L https://packages.gitlab.com/install/repositories/runner/gitlab-runner/script.deb.sh | sudo bash
  sudo apt-get install -y gitlab-runner

  sudo gitlab-runner register \
    --non-interactive \
    --url "$ORG_URL" \
    --token "$REGISTRATION_TOKEN" \
    --executor "shell" \
    --description "$RUNNER_NAME" \
    --tag-list "onprem,terraform,ansible"

  sudo gitlab-runner start
  echo "GitLab runner installed and started."
}

# ── Azure DevOps agent ────────────────────────────────────────────────────────
install_azdo_agent() {
  mkdir -p azagent && cd azagent
  curl -o vsts-agent-linux-x64.tar.gz -L \
    https://vstsagentpackage.azureedge.net/agent/4.248.0/vsts-agent-linux-x64-4.248.0.tar.gz
  tar xzf vsts-agent-linux-x64.tar.gz

  ./config.sh \
    --unattended \
    --url "$ORG_URL" \
    --auth pat \
    --token "$REGISTRATION_TOKEN" \
    --pool "$AGENT_POOL" \
    --agent "$RUNNER_NAME" \
    --acceptTeeEula

  sudo ./svc.sh install
  sudo ./svc.sh start
  echo "Azure DevOps agent installed and started."
}

# ── Main ──────────────────────────────────────────────────────────────────────
install_tools

case "$PLATFORM" in
  github) install_github_runner ;;
  gitlab) install_gitlab_runner ;;
  azdo)   install_azdo_agent ;;
  *) echo "Unknown platform: $PLATFORM"; usage ;;
esac

echo ""
echo "Runner deployment complete."
echo "Verify runner is online in your SCM platform before proceeding."
