#!/usr/bin/env bash

set -euo pipefail

readonly ARGO_CD_VERSION="${ARGO_CD_VERSION:-v3.4.5}"
readonly ARGO_CD_NAMESPACE="argocd"
readonly INSTALL_URL="https://raw.githubusercontent.com/argoproj/argo-cd/${ARGO_CD_VERSION}/manifests/install.yaml"

GITOPS_REPO_URL="${GITOPS_REPO_URL:-}"
GITOPS_REVISION="${GITOPS_REVISION:-main}"

if [[ -z "${GITOPS_REPO_URL}" ]]; then
  printf 'GITOPS_REPO_URL is required.\n' >&2
  printf 'Example: GITOPS_REPO_URL=https://github.com/OWNER/REPO.git %s\n' "$0" >&2
  exit 1
fi

for command in kubectl curl; do
  if ! command -v "${command}" >/dev/null 2>&1; then
    printf 'Required command not found: %s\n' "${command}" >&2
    exit 1
  fi
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

kubectl create namespace "${ARGO_CD_NAMESPACE}" \
  --dry-run=client \
  --output=yaml \
  | kubectl apply -f -

curl --fail --silent --show-error --location "${INSTALL_URL}" \
  | kubectl apply --server-side --force-conflicts -n "${ARGO_CD_NAMESPACE}" -f -

kubectl rollout status deployment/argocd-server \
  -n "${ARGO_CD_NAMESPACE}" \
  --timeout=5m
kubectl rollout status statefulset/argocd-application-controller \
  -n "${ARGO_CD_NAMESPACE}" \
  --timeout=5m

render() {
  local file="$1"
  sed \
    -e "s|https://github.com/linhdo04/gsm-fleet-dispatch-ai-gitops|${GITOPS_REPO_URL}|g" \
    -e "s|main|${GITOPS_REVISION}|g" \
    "${file}"
}

render "${script_dir}/project.yaml" | kubectl apply -f -
render "${script_dir}/root-application.yaml" | kubectl apply -f -

printf '\nArgo CD bootstrap complete.\n'
printf 'UI: kubectl -n argocd port-forward svc/argocd-server 8080:443\n'
printf 'Root application: kubectl -n argocd get application fleet-dispatch-root\n'
