#!/usr/bin/env bash

# This script runs Linkerd e2e tests for Canary initialization, analysis and promotion

set -o errexit

REPO_ROOT=$(git rev-parse --show-toplevel)
export KUBECONFIG="$(kind get kubeconfig-path --name="kind")"

echo '>>> Creating test namespace'
kubectl create namespace test
kubectl annotate namespace test linkerd.io/inject=enabled

echo '>>> Installing the load tester'
kubectl -n test apply -f ${REPO_ROOT}/artifacts/loadtester/
kubectl -n test rollout status deployment/flagger-loadtester

echo '>>> Initialising canary'
kubectl apply -f ${REPO_ROOT}/test/e2e-workload.yaml

cat <<EOF | kubectl apply -f -
apiVersion: flagger.app/v1alpha3
kind: Canary
metadata:
  name: podinfo
  namespace: test
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: podinfo
  progressDeadlineSeconds: 60
  service:
    port: 80
    targetPort: http
    portDiscovery: true
  canaryAnalysis:
    interval: 15s
    threshold: 15
    maxWeight: 50
    stepWeight: 10
    metrics:
    - name: request-success-rate
      threshold: 99
      interval: 1m
    - name: request-duration
      threshold: 500
      interval: 30s
    webhooks:
      - name: http-acceptance-test
        type: pre-rollout
        url: http://flagger-loadtester.test/
        timeout: 30s
        metadata:
          type: bash
          cmd: "curl -sd 'test' http://podinfo-canary/token | grep token"
      - name: grpc-acceptance-test
        type: pre-rollout
        url: http://flagger-loadtester.test/
        timeout: 5s
        metadata:
          type: bash
          cmd: "grpc_health_probe -connect-timeout=1s -addr=podinfo-canary:9999"
      - name: load-test
        url: http://flagger-loadtester.test/
        timeout: 5s
        metadata:
          type: cmd
          cmd: "hey -z 10m -q 10 -c 2 http://podinfo.test/"
          logCmdOutput: "true"
EOF

echo '>>> Waiting for primary to be ready'
retries=50
count=0
ok=false
until ${ok}; do
    kubectl -n test get canary/podinfo | grep 'Initialized' && ok=true || ok=false
    sleep 5
    count=$(($count + 1))
    if [[ ${count} -eq ${retries} ]]; then
        kubectl -n linkerd logs deployment/flagger
        echo "No more retries left"
        exit 1
    fi
done

echo '✔ Canary initialization test passed'

echo '>>> Triggering canary deployment'
kubectl -n test set image deployment/podinfo podinfod=stefanprodan/podinfo:3.1.1

echo '>>> Waiting for canary promotion'
retries=50
count=0
ok=false
until ${ok}; do
    kubectl -n test describe deployment/podinfo-primary | grep '3.1.1' && ok=true || ok=false
    sleep 10
    kubectl -n linkerd logs deployment/flagger --tail 1
    count=$(($count + 1))
    if [[ ${count} -eq ${retries} ]]; then
        kubectl -n linkerd logs deployment/flagger
        echo "No more retries left"
        exit 1
    fi
done

echo '>>> Waiting for canary finalization'
retries=50
count=0
ok=false
until ${ok}; do
    kubectl -n test get canary/podinfo | grep 'Succeeded' && ok=true || ok=false
    sleep 5
    count=$(($count + 1))
    if [[ ${count} -eq ${retries} ]]; then
        kubectl -n linkerd logs deployment/flagger
        echo "No more retries left"
        exit 1
    fi
done

echo '✔ Canary promotion test passed'

cat <<EOF | kubectl apply -f -
apiVersion: flagger.app/v1alpha3
kind: Canary
metadata:
  name: podinfo
  namespace: test
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: podinfo
  progressDeadlineSeconds: 60
  service:
    port: 80
    targetPort: 9898
  canaryAnalysis:
    interval: 15s
    threshold: 3
    maxWeight: 50
    stepWeight: 10
    metrics:
    - name: request-success-rate
      threshold: 99
      interval: 1m
    - name: request-duration
      threshold: 500
      interval: 30s
    webhooks:
      - name: http-acceptance-test
        type: pre-rollout
        url: http://flagger-loadtester.test/
        timeout: 30s
        metadata:
          type: bash
          cmd: "curl -sd 'test' http://podinfo-canary/token | grep token"
      - name: load-test
        url: http://flagger-loadtester.test/
        timeout: 5s
        metadata:
          type: cmd
          cmd: "hey -z 10m -q 10 -c 2 http://podinfo.test/status/500"
EOF

echo '>>> Triggering canary deployment'
kubectl -n test set image deployment/podinfo podinfod=stefanprodan/podinfo:3.1.2

echo '>>> Waiting for canary rollback'
retries=50
count=0
ok=false
until ${ok}; do
    kubectl -n test get canary/podinfo | grep 'Failed' && ok=true || ok=false
    sleep 10
    kubectl -n linkerd logs deployment/flagger --tail 1
    count=$(($count + 1))
    if [[ ${count} -eq ${retries} ]]; then
        kubectl -n linkerd logs deployment/flagger
        echo "No more retries left"
        exit 1
    fi
done

echo '✔ Canary rollback test passed'