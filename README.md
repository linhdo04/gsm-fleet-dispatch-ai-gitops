# Fleet Dispatch GitOps

This directory is a self-contained Argo CD repository for the Fleet Dispatch
application. Copy its **contents** to the root of a dedicated Git repository
when that repository is ready.

## What it deploys

- Argo CD `v3.4.5`, installed from the pinned upstream manifest.
- An `AppProject` and root Application (app-of-apps).
- Stateless backend and frontend Deployments on K3s.
- ClusterIP Services and a host-neutral Traefik Ingress:
  - `/api` routes to the backend on port `8000`.
  - `/` routes to the frontend on port `8080`.
- No PostgreSQL workload or Cloud SQL proxy. The current backend does not use a
  database connection yet.

Argo CD itself remains a ClusterIP service. Use port-forwarding for its admin UI
instead of exposing it over unauthenticated HTTP.

## Layout

```text
bootstrap/                         one-time Argo CD installation and root app
applications/                      child Argo CD Applications
apps/fleet-dispatch/base/          reusable Kubernetes resources
apps/fleet-dispatch/overlays/production/
                                   production image tags and replica counts
```

All paths in the Argo CD Applications are relative to this directory as a
repository root.

## Prerequisites

1. A reachable K3s cluster with Traefik enabled and a working `kubectl` context.
2. Ports 80/443 allowed to the K3s node if public access is required.
3. The K3s node can pull from
   `asia-southeast1-docker.pkg.dev/c2-app-501203/fleet-dispatch-images`.
   The accompanying Terraform/Ansible configuration grants the VM identity
   `roles/artifactregistry.reader`. A kubelet exec credential provider obtains
   short-lived access tokens from the GCE metadata server when images are pulled.
4. `kubectl` and `curl` installed on the machine running bootstrap.
5. A GitOps repository URL that Argo CD can read.

The image tags in
`apps/fleet-dispatch/overlays/production/kustomization.yaml` are immutable
Git SHAs already built by the current application workflows. Update each tag
only after its matching image exists in Artifact Registry; do not use `latest`.

## Create the application secret

The Google API keys are optional. Without a Routes API key, the backend falls
back to Haversine routing. Geocoding returns 503 when its key is absent.

Create the secret directly in the cluster so no plaintext value enters Git:

```bash
cp apps/fleet-dispatch/overlays/production/app-secrets.env.example \
  apps/fleet-dispatch/overlays/production/app-secrets.env
# Edit app-secrets.env locally, then:
kubectl create namespace fleet-dispatch \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n fleet-dispatch create secret generic fleet-dispatch-api-keys \
  --from-env-file=apps/fleet-dispatch/overlays/production/app-secrets.env \
  --dry-run=client -o yaml | kubectl apply -f -
```

The real `app-secrets.env` is ignored. The Secret is deliberately absent from
Kustomize, so Argo CD does not own or prune it. Empty keys may be omitted.

## Move this bundle to its own repository

From a clone of the application repository:

```bash
mkdir ../fleet-dispatch-gitops
cp -R argocd/. ../fleet-dispatch-gitops/
cd ../fleet-dispatch-gitops
git init
git add .
git commit -m "chore: bootstrap Fleet Dispatch GitOps"
git remote add origin https://github.com/OWNER/fleet-dispatch-gitops.git
git push -u origin main
```

Before bootstrap, confirm the production image tags and commit any changes.
If the repository is private, register it with Argo CD using a GitHub App,
deploy key, or short-lived credential. Never commit repository credentials to
this bundle. For example, after Argo CD is available, use `argocd repo add` from
a trusted operator machine.

## Bootstrap

Run this only after the GitOps bundle has been pushed:

```bash
kubectl apply -f bootstrap/project.yaml
kubectl apply -f bootstrap/root-application.yaml
```

The script is idempotent. It creates the `argocd` namespace, server-side applies
the pinned upstream installation, waits for controllers, and applies the
project/root Application. The root Application injects its repository URL and
revision into every child Application at render time, so the placeholder in
`applications/fleet-dispatch.yaml` is not used at runtime.

For a private Git repository, install Argo CD, register the repository, then
rerun the script. A first sync failure before registration is expected.

## Access and verify

Argo CD UI:

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:443
kubectl -n argocd get applications
```

The initial admin password can be read once from the upstream-generated Secret:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 --decode; printf '\n'
```

Delete that Secret and rotate/disable the local admin account after configuring
SSO or another operator account.

Application rollout and health:

```bash
kubectl -n fleet-dispatch rollout status deployment/backend
kubectl -n fleet-dispatch rollout status deployment/frontend
kubectl -n fleet-dispatch get pods,services,ingress

curl --fail http://VM_PUBLIC_IP/healthz
curl --fail http://VM_PUBLIC_IP/api/v1/health/live
curl --fail http://VM_PUBLIC_IP/api/v1/health/ready
```

## Validate before pushing

```bash
kubectl kustomize apps/fleet-dispatch/base >/dev/null
kubectl kustomize apps/fleet-dispatch/overlays/production >/dev/null
kubectl kustomize applications >/dev/null
```

The repository CI also runs Kustomize rendering, `kubeconform`, and ShellCheck.

## Updating an application image

The application CI currently pushes images tagged with the source commit SHA.
Promote a build through Git instead of calling `kubectl set image`:

1. Confirm both required image tags exist in GAR.
2. Update `newTag` for the relevant image in the production overlay.
3. Open and merge a pull request in the GitOps repository.
4. Observe the Argo CD Application become `Synced` and `Healthy`.

A later CI improvement can open this pull request automatically. It should not
write directly to the cluster and should not replace immutable tags with
`latest`.

## Domain and TLS later

The current Ingress has no `host`, so Traefik accepts the node IP/any Host
header over HTTP. To add a domain, patch `spec.rules[0].host` in the production
overlay and configure `spec.tls`. Store certificates outside Git or use a
certificate controller such as cert-manager.

## Troubleshooting and rollback

- `ImagePullBackOff`: check the VM service account role/scope, verify
  `/var/lib/rancher/credentialprovider/config.yaml` and the provider executable
  exist on every node, then inspect `journalctl -u k3s` or
  `journalctl -u k3s-agent` for credential-provider errors.
- Argo CD `ComparisonError`: verify the repository URL, revision, and private
  repository registration.
- Backend probe failures: the valid paths include the `/api/v1` prefix.
- Ingress unavailable: check that the K3s Traefik HelmChart is healthy and that
  the VM firewall/public IP configuration matches the intended access model.

Rollback by reverting the GitOps commit that changed an image tag or manifest.
Argo CD will reconcile to that Git state. Avoid manual cluster changes because
self-heal intentionally overwrites drift.
