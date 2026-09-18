# Gateway Operator — GitOps via ArgoCD

Kubernetes manifests for running the WSO2 API Platform Gateway via its
native Operator/CRD deployment mode, managed by ArgoCD instead of manual
`kubectl apply` / `curl` calls against the management REST API.

## Prerequisites (once per cluster)

```bash
# cert-manager — the operator's admission webhook needs it
helm upgrade --install cert-manager oci://quay.io/jetstack/charts/cert-manager \
  --version v1.19.1 --namespace cert-manager --create-namespace \
  --set crds.enabled=true --wait --timeout 5m

# Gateway Operator itself
helm install my-gateway-operator oci://ghcr.io/wso2/api-platform/helm-charts/gateway-operator --version 0.6.0

# The AES-256 encryption key Secret -- NOT managed by ArgoCD/Git, see
# 02-aesgcm-key-secret.yaml.example for why and how to create it.
```

Confirm the CRDs actually installed, and which API version they serve
(chart `0.6.0` currently only serves `v1alpha1`, not the `v1` shown in
WSO2's own docs samples -- a real version-drift issue hit while setting
this up):

```bash
kubectl get crd apigateways.gateway.api-platform.wso2.com \
  -o jsonpath='{range .spec.versions[*]}{.name}{" served="}{.served}{"\n"}{end}'
```

## What's in this folder

| File | Purpose |
|---|---|
| `00-apigateway.yaml` | Bootstraps the whole gateway (controller + router + policy engine) |
| `01-gateway-custom-config.yaml` | Helm values override, with two real chart bugs patched (see comments in the file) |
| `02-aesgcm-key-secret.yaml.example` | Template only -- the real Secret is created out-of-band, never committed |
| `03-restapi-demo.yaml` | A minimal API (`GET /demo/info` -> `https://httpbin.org/anything`) to prove the pipeline end to end without needing our own backend |

## ArgoCD Application

```bash
kubectl apply -n argocd -f - <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: gateway-operator-demo
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/<org>/API_Platform_Demo.git
    targetRevision: main
    path: gitops/gateway-operator
  destination:
    server: https://kubernetes.default.svc
    namespace: default
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF
```

From here: edit `03-restapi-demo.yaml` (add an operation, change the
upstream, whatever), `git push`, and watch ArgoCD pick up the diff and
re-apply it -- no manual `kubectl apply` or `curl` against the management
API needed. `selfHeal: true` also means any manual `kubectl edit` against
these resources gets reverted back to what's in Git automatically.

Note: `02-aesgcm-key-secret.yaml.example` uses a `.example` extension
specifically so ArgoCD's default `*.yaml` glob does NOT pick it up --
the real secret must exist in the cluster before this Application first
syncs, created via the command in that file's header comment.
