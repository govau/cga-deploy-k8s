# Installer files for contour

There is a helm chart [in progress being added](https://github.com/helm/charts/pull/7385), so this is a bit hacky for now and we just install using yaml files.

If there is a new release of contour and you want to refresh these files:

1. Clone the Contour repository, cd into the repo and checkout the latest release.

2. Run `rm deploment/ds-hostnet/02-service.yaml` to remove the service (we dont need it as we are BYO nlb)

3. Edit `deploment/ds-hostnet/02-contour.yaml`, add hostPort as below:

```yml
spec:
    ...
      containers:
      ...
      - image: docker.io/envoyproxy/envoy-alpine:v1.7.0
        name: envoy
        ports:
        - containerPort: 8080
          hostPort: 8080 # add this
          name: http
        - containerPort: 8443
          hostPort: 8443 # add this
          name: https
          ...
```

This configuration ensures that contour is running on each eks worker node listening on ports 8080 and 8443 using a DaemonSet.

4. Copy the files from deployment/ds-hostnet into this directory.
