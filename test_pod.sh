#!/bin/bash

set -euxo pipefail

curl -fsSL https://chezmoi.io/get | sh -s -- init felipecrs --force

bin/chezmoi apply "${HOME}/.local/bin/helm-upgrade-logs" "${HOME}/.local/bin/kpfd"

helm-upgrade-logs --install --debug --wait \
    jenkins --repo https://charts.jenkins.io jenkins --version 3.11.4 \
    --set persistence.enabled=false
