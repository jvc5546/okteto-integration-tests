# okteto-integration-tests
Image to use for the CronJob that will run checks and integrations tests in an Okteto cluster

To build and push to my local github registry:
```
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -t ghcr.io/<github username>/okteto-integration-tests:latest \
  --push \
  ~/repositories/okteto-integration-tests/
```