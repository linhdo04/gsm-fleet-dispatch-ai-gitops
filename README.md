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
infrastructure/cert-manager/       cluster-wide certificate issuers
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
4. cert-manager and its CRDs installed in the `cert-manager` namespace. Wait for
   its controller, webhook, and CA injector to become ready before syncing the
   child Applications.
5. A Cloudflare API token with `Zone:DNS:Edit` and `Zone:Zone:Read` permissions
   for `docker-linhdt.site`.
6. `kubectl` and `curl` installed on the machine running bootstrap.
7. A GitOps repository URL that Argo CD can read.

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

## Create the Cloudflare DNS secret

The ClusterIssuers reference `cloudflare-api-token-secret` in cert-manager's
cluster resource namespace, which is `cert-manager` for the standard
installation. Create it directly in the cluster before Argo CD syncs
`cert-manager-config`:

```bash
kubectl -n cert-manager create secret generic cloudflare-api-token-secret \
  --from-literal=api-token='REPLACE_WITH_CLOUDFLARE_API_TOKEN'
```

`infrastructure/cert-manager/cloudflare-api-token-secret.yaml.example` documents
the required Secret name and key but is deliberately excluded from the
Kustomization. Never replace its placeholder with a real token or commit a live
Secret manifest.

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

Run this only after the GitOps bundle has been pushed.

### 1. Install Argo CD

```bash
kubectl create namespace argocd
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.4.5/manifests/install.yaml
```

Wait for all controllers to become ready:

```bash
kubectl -n argocd wait --for=condition=Ready pods --all --timeout=120s
```

For a private Git repository, register the repository with Argo CD:

```bash
argocd repo add https://github.com/OWNER/REPO.git
```

### 2. Apply the AppProject and root Application

```bash
kubectl apply -f bootstrap/project.yaml
kubectl apply -f bootstrap/root-application.yaml
```

The root Application injects its repository URL and revision into every child
Application at render time, so the placeholders in `applications/*.yaml` are
not used at runtime. It syncs `cert-manager-config` before `fleet-dispatch`, but
cert-manager itself, its CRDs, the `cert-manager` namespace, and the Cloudflare
Secret must already exist. A first sync failure before repository registration
is expected for private repos.

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

## Domain and TLS

The Ingress serves `docker-linhdt.site` through Traefik and requests the
`docker-linhdt-tls` Secret from the `letsencrypt-prod` ClusterIssuer. Argo CD
manages the staging and production ClusterIssuers through the separate
`cert-manager-config` Application; it does not install cert-manager or manage
the Cloudflare API token.

Verify certificate issuance with:

```bash
kubectl get clusterissuer letsencrypt-staging letsencrypt-prod
kubectl -n fleet-dispatch get certificate,certificaterequest,challenge
kubectl -n fleet-dispatch get secret docker-linhdt-tls
curl --fail https://docker-linhdt.site/healthz
```

When changing the DNS-01 solver, temporarily set the Ingress annotation to
`letsencrypt-staging` and validate issuance before returning to
`letsencrypt-prod`; this avoids Let's Encrypt production rate limits. Inspect
`kubectl describe clusterissuer`, the Certificate resources, and cert-manager
controller logs when a DNS challenge does not become ready.

`APP_TRUSTED_HOSTS` in `apps/fleet-dispatch/base/configmap.yaml` is still a
wildcard and should be restricted to `docker-linhdt.site` in a separate
application configuration change.

## Horizontal Pod Autoscaler (backend)

The backend Deployment is configured with a HorizontalPodAutoscaler (HPA) using
`autoscaling/v2`:

| Field        | Value                        |
|--------------|------------------------------|
| Metric       | CPU utilization at 70%       |
| Min replicas | 1                            |
| Max replicas | 3                            |
| Scale-up     | Immediate (0s stabilization) |
| Scale-down   | 300s cooldown                |

The HPA target CPU utilization is calculated against the backend's
`requests.cpu` (100m). The frontend is **not** auto-scaled — its single replica
is managed by the Kustomize production overlay.

### Requirements

- The cluster must have a functional **Metrics API**. K3s ships with
  `metrics-server` disabled by default; enable it with:
  ```bash
  kubectl edit configmap -n kube-system metrics-server-config
  ```
  or check that `kubectl top nodes` returns data.
- The backend Deployment must have a CPU `request` set (100m in base).

### Verification

```bash
kubectl -n fleet-dispatch get hpa backend             # targets, current, min/max
kubectl -n fleet-dispatch describe hpa backend         # conditions and events
kubectl -n fleet-dispatch top pod backend-<hash>       # current CPU/Mem
```

### Argo CD integration

Because Argo CD manages `Deployment.spec.replicas` through Kustomize but HPA
needs to modify it at runtime, the `applications/fleet-dispatch.yaml` manifest
includes an `ignoreDifferences` rule that prevents Argo CD from detecting drift
on the `backend` Deployment's replica count. The sync option
`RespectIgnoreDifferences=true` ensures self-heal does not overwrite HPA-driven
changes.

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
