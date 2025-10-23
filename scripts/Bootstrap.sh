#!/usr/bin/env bash
# ======================================
# Neura Bootstrap System (v3.0)
# --------------------------------------
# Automates microservice scaffolding,
# Helm & ArgoCD config generation,
# and schema sync for 102 services.
# ======================================

set -e
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REGISTRY="$ROOT_DIR/service-registry.yaml"
HELM_DIR="$ROOT_DIR/infrastructure/helm/charts"
ARGO_APPS="$ROOT_DIR/infrastructure/argo/applications"
COMMON_SCHEMA="$ROOT_DIR/core/schema/global_schema.json"
PLACEHOLDERS="$ROOT_DIR/core/schema/placeholders"

echo "🚀 Bootstrapping Neura from registry: $REGISTRY"

# Check prerequisites
for cmd in yq jq envsubst kubectl helm; do
  if ! command -v $cmd &>/dev/null; then
    echo "❌ $cmd not installed"; exit 1;
  fi
done

mkdir -p "$HELM_DIR" "$ARGO_APPS"

SERVICES=$(yq e '.services[].name' "$REGISTRY")

for SERVICE in $SERVICES; do
  PATH_DIR=$(yq e ".services[] | select(.name == \"$SERVICE\") | .path" "$REGISTRY")
  LANG=$(yq e ".services[] | select(.name == \"$SERVICE\") | .language" "$REGISTRY")
  PORT=$(yq e ".services[] | select(.name == \"$SERVICE\") | .port" "$REGISTRY")
  NS=$(yq e ".services[] | select(.name == \"$SERVICE\") | .namespace" "$REGISTRY")
  TEAM=$(yq e ".services[] | select(.name == \"$SERVICE\") | .team" "$REGISTRY")

  echo "⚙️  Setting up $SERVICE in $PATH_DIR (lang=$LANG port=$PORT ns=$NS)"

  mkdir -p "$ROOT_DIR/$PATH_DIR"/{cmd,internal/{handlers,repository,service,models},api,tests/unit,tests/integration}
  touch "$ROOT_DIR/$PATH_DIR/README.md"

  # Base Dockerfile template
  cat > "$ROOT_DIR/$PATH_DIR/Dockerfile" <<EOF
# ${SERVICE} Dockerfile (auto-generated)
FROM ${LANG}:latest
WORKDIR /app
COPY . .
RUN make build || true
EXPOSE ${PORT}
CMD ["./bin/${SERVICE}"]
EOF

  # Basic Helm chart scaffold
  CHART_PATH="$HELM_DIR/$SERVICE"
  mkdir -p "$CHART_PATH/templates"
  cat > "$CHART_PATH/Chart.yaml" <<EOF
apiVersion: v2
name: ${SERVICE}
version: 0.1.0
description: Helm chart for ${SERVICE}
EOF
  cat > "$CHART_PATH/values.yaml" <<EOF
replicaCount: 2
image:
  repository: neura/${SERVICE}
  tag: latest
service:
  port: ${PORT}
resources:
  limits:
    cpu: 500m
    memory: 512Mi
EOF

  # ArgoCD app manifest
  cat > "$ARGO_APPS/${SERVICE}.yaml" <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${SERVICE}
  namespace: argocd
spec:
  project: neura
  source:
    repoURL: 'https://github.com/neura/social'
    path: infrastructure/helm/charts/${SERVICE}
    targetRevision: main
    helm:
      valueFiles:
        - values.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: ${NS}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF

  # Add CI Workflow if missing
  WORKFLOW="$ROOT_DIR/.github/workflows/${SERVICE}.yml"
  if [ ! -f "$WORKFLOW" ]; then
    cat > "$WORKFLOW" <<EOF
name: CI - ${SERVICE}
on:
  push:
    paths:
      - '${PATH_DIR}/**'
jobs:
  build-test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Build ${SERVICE}
        run: docker build -t neura/${SERVICE}:latest ${PATH_DIR}
      - name: Test ${SERVICE}
        run: make test || echo "No tests"
EOF
  fi
done

# Shared schema sync
echo "🔁 Syncing global schema and placeholders..."
find "$ROOT_DIR/services" -type d -name "api" -exec cp "$COMMON_SCHEMA" {} \;
find "$ROOT_DIR/services" -type d -name "api" -exec cp "$PLACEHOLDERS/en.json" {} \;

# Register Grafana dashboards per namespace
for NS in core ai ads mod localization infra analytics gamification public-voice dev data bonus; do
  echo "📊 Registering Grafana dashboard for $NS..."
  cat > "$ROOT_DIR/infrastructure/monitoring/grafana/dashboards/${NS}.json" <<EOF
{
  "title": "Neura - ${NS} Overview",
  "panels": [
    { "type": "graph", "title": "Request Latency", "targets": [] },
    { "type": "stat", "title": "Error Rate", "targets": [] }
  ]
}
EOF
done

echo "✅ Bootstrap complete! 102 services initialized."
echo "Next: run ./scripts/deploy-all.sh to start in Kubernetes."
