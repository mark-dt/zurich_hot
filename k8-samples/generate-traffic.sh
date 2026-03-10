#!/usr/bin/env bash

#TARGET_URL="http://prometheus-demo:8080"
TARGET_URL="http://prometheus-demo.demo.svc.cluster.local:8080"
REQUESTS=50
SLEEP_SECONDS=1

echo "Generating traffic to ${TARGET_URL}"

for i in $(seq 1 $REQUESTS); do
  curl -s -o /dev/null "$TARGET_URL"
  echo "Request $i sent"
  sleep $SLEEP_SECONDS
done

echo "Done."

# check metrics
# curl http://localhost:8080/metrics | grep http

#
kubectl run curl-test \
 --rm -it --restart=Never \
 --image=curlimages/curl \
 -- http://prometheus-demo:8080/metrics
#
kubectl -n demo run curl-test --rm -it --restart=Never --image=curlimages/curl \
  -- http://prometheus-demo.demo.svc.cluster.local:8080/metrics


# go into the pod
  kubectl run loadgen --rm -it --restart=Never \
  --image=curlimages/curl \
  -- sh

  while true; do
  curl -s http://prometheus-demo:8080/
  sleep 1
done