ARG KEYCLOAK_VERSION=26.6.1
ARG NODE_IMAGE=node:22-alpine

FROM alpine:3.21 AS sms-authenticator-provider

ARG SMS_AUTHENTICATOR_ENABLED=true
ARG SMS_AUTHENTICATOR_VERSION=v26.6.1
ARG SMS_AUTHENTICATOR_SHA256=c2d4ceb3f2b1f14392f6e468b1d922081d12971bc9efe50113759d2e52686dd7

WORKDIR /work

RUN apk add --no-cache ca-certificates curl
RUN mkdir -p /out/providers

RUN set -eux; \
    if [ "${SMS_AUTHENTICATOR_ENABLED}" != "true" ]; then \
        exit 0; \
    fi; \
    SMS_AUTHENTICATOR_JAR="netzbegruenung.sms-authenticator-${SMS_AUTHENTICATOR_VERSION}.jar"; \
    curl -fsSL \
        "https://github.com/netzbegruenung/keycloak-mfa-plugins/releases/download/${SMS_AUTHENTICATOR_VERSION}/${SMS_AUTHENTICATOR_JAR}" \
        -o "/out/providers/${SMS_AUTHENTICATOR_JAR}"; \
    echo "${SMS_AUTHENTICATOR_SHA256}  /out/providers/${SMS_AUTHENTICATOR_JAR}" | sha256sum -c -

FROM ${NODE_IMAGE} AS theme-repo-builder

ARG THEME_REPO_ENABLED=true
ARG THEME_REPO_OPTIONAL=true
ARG THEME_REPO_URL=https://github.com/DeNic0la/keycloak-theme-image.git
ARG THEME_REPO_REF=main
ARG THEME_REPO_BUILD_CMD=

WORKDIR /work

RUN apk add --no-cache bash git openjdk17-jdk maven
RUN npm install -g pnpm
RUN mkdir -p /out/providers

RUN set -eux; \
    if [ "${THEME_REPO_ENABLED}" != "true" ]; then \
        exit 0; \
    fi; \
    git clone --depth 1 --branch "${THEME_REPO_REF}" "${THEME_REPO_URL}" /work/theme; \
    cd /work/theme; \
    if [ -f pnpm-lock.yaml ]; then \
        pnpm install --frozen-lockfile; \
    elif [ -f yarn.lock ]; then \
        yarn install --frozen-lockfile; \
    elif [ -f package-lock.json ]; then \
        npm ci; \
    elif [ -f package.json ]; then \
        npm install; \
    fi; \
    if [ -n "${THEME_REPO_BUILD_CMD}" ]; then \
        sh -lc "${THEME_REPO_BUILD_CMD}"; \
    elif [ -f package.json ] && grep -q '"build-keycloak-theme"' package.json; then \
        if [ -f pnpm-lock.yaml ]; then \
            pnpm run build-keycloak-theme; \
        elif [ -f yarn.lock ]; then \
            yarn build-keycloak-theme; \
        else \
            npm run build-keycloak-theme; \
        fi; \
    fi; \
    if [ -d dist_keycloak ] && find dist_keycloak -maxdepth 1 -name '*.jar' | grep -q .; then \
        cp dist_keycloak/*.jar /out/providers/; \
    elif [ "${THEME_REPO_OPTIONAL}" != "true" ]; then \
        echo "No Keycloak theme JAR was produced by ${THEME_REPO_URL}."; \
        echo "Set THEME_REPO_BUILD_CMD to your theme build command or make the repo emit dist_keycloak/*.jar."; \
        exit 1; \
    else \
        echo "Skipping optional theme repo ${THEME_REPO_URL}: no dist_keycloak/*.jar output."; \
    fi

FROM ${NODE_IMAGE} AS shadcn-theme-builder

ARG SHADCN_THEME_ENABLED=true
ARG SHADCN_THEME_REPO_URL=https://github.com/Oussemasahbeni/keycloakify-shadcn-starter.git
ARG SHADCN_THEME_REPO_REF=main

WORKDIR /work

RUN apk add --no-cache bash git openjdk17-jdk maven
RUN npm install -g pnpm
RUN mkdir -p /out/providers

RUN set -eux; \
    if [ "${SHADCN_THEME_ENABLED}" != "true" ]; then \
        exit 0; \
    fi; \
    git clone --depth 1 --branch "${SHADCN_THEME_REPO_REF}" "${SHADCN_THEME_REPO_URL}" /work/theme; \
    cd /work/theme; \
    if [ -f pnpm-lock.yaml ]; then \
        pnpm install --frozen-lockfile; \
        pnpm run build-keycloak-theme; \
    elif [ -f yarn.lock ]; then \
        yarn install --frozen-lockfile; \
        yarn build-keycloak-theme; \
    elif [ -f package-lock.json ]; then \
        npm ci; \
        npm run build-keycloak-theme; \
    else \
        npm install; \
        npm run build-keycloak-theme; \
    fi; \
    cp dist_keycloak/*.jar /out/providers/

FROM quay.io/keycloak/keycloak:${KEYCLOAK_VERSION} AS builder

ENV KC_HEALTH_ENABLED=true
ENV KC_METRICS_ENABLED=true
ENV KC_DB=postgres

WORKDIR /opt/keycloak

COPY --from=theme-repo-builder /out/providers/ /opt/keycloak/providers/
COPY --from=shadcn-theme-builder /out/providers/ /opt/keycloak/providers/
COPY --from=sms-authenticator-provider /out/providers/ /opt/keycloak/providers/

RUN /opt/keycloak/bin/kc.sh build

FROM quay.io/keycloak/keycloak:${KEYCLOAK_VERSION}

COPY --from=builder /opt/keycloak/ /opt/keycloak/

ENV KC_DB=postgres
ENV KC_HEALTH_ENABLED=true
ENV KC_METRICS_ENABLED=true

ENTRYPOINT ["/opt/keycloak/bin/kc.sh"]
CMD ["start", "--optimized"]
