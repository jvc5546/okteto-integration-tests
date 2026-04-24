#!/usr/bin/env sh
# entrypoint.sh
#
# Runs the platform health checks first. If they pass, runs the Okteto
# end-to-end tests. Either script exiting non-zero stops the chain and
# fails the Job/CronJob.
 
set -e
 
echo ">>> Starting platform health checks..."
/usr/local/bin/run-integration-tests.sh
 
echo ">>> Platform checks passed. Starting Okteto end-to-end tests..."
/usr/local/bin/run-okteto-e2e.sh