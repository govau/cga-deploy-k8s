# Installer files for contour

There is a helm chart [in progress being added](https://github.com/helm/charts/pull/7385), so this is a bit hacky for now and we just install using yaml files.

If there is a new release of contour and you want to refresh these files:

1. Clone the [Contour repository](https://github.com/heptio/contour), cd into the repo and checkout the latest release.

2. Run `rm examples/ds-hostnet/02-service.yaml` to remove the service (we dont need it as we are using an nlb defined in terraform)

3. Copy the files from examples/ds-hostnet into this directory.
