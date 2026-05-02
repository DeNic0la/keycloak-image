# Keycloak Image

This image is an optimized Keycloak build that keeps secrets and trust material
out of the image. TLS and database trust settings are supplied at runtime by the
deployment environment.

It now also supports bundling custom themes during the image build:

- the upstream `shadcn-ui-tailwind` Keycloakify starter theme from
  `https://docs.keycloakify.dev/starter-themes/shadcn-ui-tailwind`
- an additional theme repository, defaulting to
  `https://github.com/DeNic0la/keycloak-theme-image`

The image also bundles the SMS authenticator from
`https://github.com/netzbegruenung/keycloak-mfa-plugins` so realms can add SMS
OTP as a second authentication factor.

It follows the official Keycloak guidance for:

- optimized container builds:
  `https://www.keycloak.org/server/containers`
- production configuration:
  `https://www.keycloak.org/server/configuration-production`
- startup optimization:
  `https://www.keycloak.org/server/configuration#_optimize_the_keycloak_startup`
- update compatibility:
  `https://www.keycloak.org/server/update-compatibility#_supported_update_strategies`
- provider configuration:
  `https://www.keycloak.org/server/all-provider-config`

## Runtime contract

Provide these environment variables at runtime:

- `KC_HOSTNAME`
- `KC_DB_URL`
- `KC_DB_USERNAME`
- `KC_DB_PASSWORD`
- `KC_BOOTSTRAP_ADMIN_USERNAME`
- `KC_BOOTSTRAP_ADMIN_PASSWORD`

The image defaults to:

- `KC_DB=postgres`
- `KC_HEALTH_ENABLED=true`
- `KC_METRICS_ENABLED=true`

## Implemented optimizations

The Dockerfile applies the container and startup optimizations that are safe to
 bake into the image:

- multi-stage build
- `kc.sh build` during image creation
- `start --optimized` at runtime
- PostgreSQL selected as the build-time database vendor
- health and metrics enabled at build time and runtime
- no certificates, passwords, tokens, or trust stores copied into the image

These are the relevant image-level optimizations from the Keycloak container and
configuration guides. Other production settings are runtime and infrastructure
concerns and are documented below instead of being hardcoded into the image.

## Theme builds

The Dockerfile contains two theme builder stages before the final Keycloak
optimization step:

- `shadcn-theme-builder` clones the Keycloakify `shadcn-ui-tailwind` starter
  repository, runs its `build-keycloak-theme` script, and copies the generated
  JAR files into `/opt/keycloak/providers/`
- `theme-repo-builder` clones a second theme repository and tries to collect
  `dist_keycloak/*.jar` from it

The default second theme repository is
`https://github.com/DeNic0la/keycloak-theme-image`. Its current source of truth
is the sibling repo README at `/home/g/repos/keycloak-theme-image/README.md`.
That repo is a Keycloakify-based Keycloak 26 theme with `login`, `account`, and
`email` theme scopes. It exposes `pnpm build-keycloak-theme` and is expected to
emit `dist_keycloak/keycloak-theme-for-kc-all-other-versions.jar`.

The builder auto-detects the `build-keycloak-theme` script and copies any
generated `dist_keycloak/*.jar` files. The second theme remains optional by
default, so clone, install, build, or packaging failures in that external repo
do not block image builds. Make it mandatory with build arguments like:

```bash
docker build -t secure-keycloak \
  --build-arg THEME_REPO_OPTIONAL=false \
  --build-arg THEME_REPO_BUILD_CMD="pnpm run build-keycloak-theme" .
```

For reproducible CI builds, both external theme repositories are pinned to
known-good commits by default. Override `THEME_REPO_COMMIT` or
`SHADCN_THEME_REPO_COMMIT` only when intentionally updating those upstream
dependencies.

Available build arguments:

- `KEYCLOAK_VERSION`
- `NODE_IMAGE`
- `THEME_REPO_ENABLED`
- `THEME_REPO_OPTIONAL`
- `THEME_REPO_URL`
- `THEME_REPO_REF`
- `THEME_REPO_COMMIT`
- `THEME_REPO_BUILD_CMD`
- `SHADCN_THEME_ENABLED`
- `SHADCN_THEME_REPO_URL`
- `SHADCN_THEME_REPO_REF`
- `SHADCN_THEME_REPO_COMMIT`
- `SMS_AUTHENTICATOR_ENABLED`
- `SMS_AUTHENTICATOR_VERSION`
- `SMS_AUTHENTICATOR_SHA256`

## SMS MFA provider

The Dockerfile downloads the SMS authenticator release JAR from
`netzbegruenung/keycloak-mfa-plugins`, verifies its SHA-256 digest, and copies it
into `/opt/keycloak/providers/` before `kc.sh build`.

Defaults:

- `SMS_AUTHENTICATOR_ENABLED=true`
- `SMS_AUTHENTICATOR_VERSION=v26.6.1`
- `SMS_AUTHENTICATOR_SHA256=c2d4ceb3f2b1f14392f6e468b1d922081d12971bc9efe50113759d2e52686dd7`

Keep this plugin version aligned with the Keycloak version whenever possible.
Changing the plugin JAR is a compatibility-relevant image change, so validate the
rollout strategy with Keycloak's `update-compatibility` flow before production
rollouts.

### Realm setup

After deploying the image, configure each realm that should use SMS MFA:

1. Go to `Realm` > `Authentication` > `Required actions`.
2. Enable `Phone Validation` and `Update Mobile Number`.
3. Duplicate the built-in `Browser` authentication flow, for example as
   `browser_sms_flow`.
4. In the copied flow, add the `SMS Authentication (2FA)` authenticator.
5. Name the authenticator execution alias `sms-2fa`.
6. Set the execution to `Required` when every login must use SMS MFA, or
   `Alternative` when it should sit beside another second factor such as OTP.
7. Open the flow actions and bind the copied flow as the realm `Browser flow`.

The Medium walkthrough removes the copied `Conditional OTP` form and marks the
SMS step as required when SMS MFA should apply to all users in the realm. Keep
that behavior only if SMS is intended to be mandatory for the whole browser
login flow.

### SMS provider configuration

Configure the `sms-2fa` execution for the HTTP API of the SMS provider used by
the deployment. The plugin sends the SMS request as an HTTP POST and exposes
generic fields for common SMS APIs:

- `SMS API URL`
- `URL encode data`
- `Put API Secret Token in Authorization Header`
- `API Secret Token Attribute`
- `API Secret`
- `Basic Auth Username`
- `Message Attribute`
- `Receiver Phone Number Attribute`
- `Sender Phone Number Attribute`
- `SenderId`
- `Use message UUID`
- `UUID attribute`
- `Request JSON template`

SMS API credentials, tokens, provider URLs, sender IDs, and role exclusions are
realm or deployment configuration. Do not bake them into this image.

For local or non-production testing, enable the authenticator's simulation mode.
In that mode no real SMS is sent and the OTP can be read from Keycloak server
logs. Disable simulation mode before production use.

Users can register or update their phone number in the account console under
`/realms/<realm>/account/#/account-security/signing-in`. On first login after
SMS MFA is required, users without a phone number are prompted to add and verify
one before completing login.

SMS OTP is weaker than WebAuthn or authenticator-app OTP. Use it only when the
realm's risk model accepts SMS as a second factor.

## CI and publishing

GitHub Actions builds this image on pull requests and pushes. On pushes to
`main` and on version tags, the workflow publishes the image to:

- `ghcr.io/<owner>/<repo>`

The workflow uses only the built-in `GITHUB_TOKEN`. No repository secret is
required for image publishing or secret scanning.

The pipeline also runs a secret scan so commits containing private keys, tokens,
or plaintext credential files fail before publish.

## Production notes

The Keycloak production guide includes several settings that depend on the
deployment environment and therefore are not baked into the image:

- public hostname:
  provide `KC_HOSTNAME` at runtime
- TLS model:
  either terminate TLS at ingress/reverse proxy or mount HTTPS material into the
  container
- reverse proxy behavior:
  set `KC_PROXY_HEADERS` when Keycloak is behind a proxy
- request queue protection:
  set `KC_HTTP_MAX_QUEUED_REQUESTS` only after choosing a threshold that matches
  the environment
- bootstrap behavior:
  keep the default async bootstrap when the platform can probe `/health/ready`;
  use `start --optimized --server-async-bootstrap=false` only when the platform
  cannot wait on readiness
- admin/API exposure:
  prefer separating admin exposure at the proxy layer instead of hardcoding one
  public topology into the image
- database trust:
  prefer full server certificate verification at runtime rather than storing CA
  material in the image

## Upgrade compatibility

This image is built to support Keycloak's recommended update-compatibility flow,
but the image alone does not decide whether a rollout may be rolling or must be
recreated.

Before changing any of the following, determine the update strategy with
Keycloak's `update-compatibility` command:

- Keycloak version
- enabled or disabled features
- cache-related settings
- custom providers or themes
- other runtime configuration that may affect compatibility

Important constraints from the Keycloak guide:

- patch upgrades in the same `major.minor` line may support rolling updates
- version or feature changes can require recreate updates
- automation should use the `update-compatibility check` exit code rather than
  parsing metadata details
- using `start --optimized` is the correct baseline for this flow

In this repo, custom themes may be included at build time. Treat theme changes
the same way as other compatibility-relevant image changes and validate the
rollout strategy when theme contents, theme JARs, or enabled theme features
change.

## Provider configuration

This image ships the SMS authenticator provider JAR from
`netzbegruenung/keycloak-mfa-plugins`. It does not hardcode SPI overrides beyond
the normal image-level settings for database vendor, health, and metrics.

That is intentional:

- Keycloak does not require every provider listed in `all-provider-config` to be
  explicitly configured
- provider options should be set only when a non-default provider behavior is
  actually required
- unnecessary SPI overrides create rollout risk and increase the amount of
  configuration that must be checked with `update-compatibility`

Current provider posture for this image:

- SMS Authentication (2FA) provider is baked into the optimized image
- custom theme JARs may be baked into the image during the Docker build
- no provider-specific build-time SPI overrides
- provider-specific runtime overrides are expected to live in the deployment
  repo, not the image, when they are needed by a real environment

## IPv4 and IPv6

The production guide documents JVM-level network stack selection through
`JAVA_OPTS_APPEND`. This image does not force either mode because that depends on
the target cluster or host network.

Examples:

- prefer IPv4:
  `JAVA_OPTS_APPEND=-Djava.net.preferIPv4Stack=true`
- prefer IPv6:
  `JAVA_OPTS_APPEND=-Djava.net.preferIPv4Stack=false -Djava.net.preferIPv6Addresses=true`

## Current Kubernetes deployment

The current infra in `/home/g/repos/keycloak-infra` terminates TLS at ingress
with cert-manager and runs Keycloak behind the ingress controller using
`KC_HTTP_ENABLED=true`. In that model:

- ingress owns the public certificate and private key
- this image does not need mounted HTTPS key material
- database TLS should still be configured separately
- the deployment can also set `JAVA_OPTS_APPEND` if it needs IPv4-only or
  IPv6-only behavior

## Optional: Keycloak serves HTTPS itself

If you want Keycloak to terminate TLS inside the container, mount:

- `/run/secrets/tls.crt`
- `/run/secrets/tls.key`
- `/run/secrets/database-ca.crt`

and provide:

- `KC_HTTPS_CERTIFICATE_FILE=/run/secrets/tls.crt`
- `KC_HTTPS_CERTIFICATE_KEY_FILE=/run/secrets/tls.key`
- `KC_DB_TLS_MODE=verify-server`
- `KC_DB_TLS_TRUST_STORE_FILE=/run/secrets/database-ca.crt`

## Example

```bash
docker build -t secure-keycloak .

docker run --rm -p 8443:8443 -p 9000:9000 \
  -e KC_HOSTNAME=keycloak.example.com \
  -e KC_DB_URL=jdbc:postgresql://db.example.com:5432/keycloak \
  -e KC_DB_USERNAME=keycloak \
  -e KC_DB_PASSWORD='change-me' \
  -e KC_BOOTSTRAP_ADMIN_USERNAME=admin \
  -e KC_BOOTSTRAP_ADMIN_PASSWORD='change-me-too' \
  -e KC_HTTPS_CERTIFICATE_FILE=/run/secrets/tls.crt \
  -e KC_HTTPS_CERTIFICATE_KEY_FILE=/run/secrets/tls.key \
  -e KC_DB_TLS_MODE=verify-server \
  -e KC_DB_TLS_TRUST_STORE_FILE=/run/secrets/database-ca.crt \
  -v /path/to/tls.crt:/run/secrets/tls.crt:ro \
  -v /path/to/tls.key:/run/secrets/tls.key:ro \
  -v /path/to/database-ca.crt:/run/secrets/database-ca.crt:ro \
  secure-keycloak
```

## Notes

- `tls.key` must be a PEM private key matching `tls.crt`. An OpenSSH private key
  is not a valid replacement.
- If your database CA is already trusted by the JVM, you can override or unset
  `KC_DB_TLS_TRUST_STORE_FILE` as needed for your deployment.
- This repo intentionally does not install extra RPM packages or custom
  entrypoint scripts, which keeps the final image closer to the hardened
  Keycloak base image and avoids extra container attack surface.
