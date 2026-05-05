# Pre-baked SSH OTP target image for the Vault tutorials.
#
# Bakes everything that previously required apt-get / curl inside the lab:
#   - openssh-server, ca-certificates
#   - vault-ssh-helper binary
#   - vaultlab + ubuntu users (no password; PAM auth via vault-ssh-helper)
#   - sshd_config + /etc/pam.d/sshd configured for keyboard-interactive OTP
#   - host keys generated at build time
#
# Runtime configuration is supplied through environment variables and written
# into /etc/vault-ssh-helper.d/config.hcl by the entrypoint.

FROM ubuntu:24.04

ARG VAULT_SSH_HELPER_VERSION=0.2.1

ENV DEBIAN_FRONTEND=noninteractive

# Avoid transient noble-backports 5xx errors during build; we don't need that pocket.
RUN sed -i '/noble-backports/d' /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null || true \
    && rm -f /etc/apt/sources.list.d/ubuntu.sources.bak \
    && if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then \
         sed -i '/noble-backports/,/^$/d' /etc/apt/sources.list.d/ubuntu.sources; \
       fi

RUN set -eux; \
    for attempt in 1 2 3 4 5; do \
        echo "apt attempt $attempt"; \
        if apt-get update \
                -o Acquire::Retries=5 \
                -o Acquire::http::Timeout=30 \
            && apt-get install -y --no-install-recommends \
                -o Acquire::Retries=5 \
                -o Acquire::http::Timeout=30 \
                openssh-server unzip curl ca-certificates; then \
            rm -rf /var/lib/apt/lists/*; \
            exit 0; \
        fi; \
        echo "apt attempt $attempt failed, retrying in 10s..."; \
        sleep 10; \
    done; \
    echo "apt failed after retries" >&2; \
    exit 1

RUN curl --connect-timeout 10 --max-time 120 -fsSL \
        "https://releases.hashicorp.com/vault-ssh-helper/${VAULT_SSH_HELPER_VERSION}/vault-ssh-helper_${VAULT_SSH_HELPER_VERSION}_linux_amd64.zip" \
        -o /tmp/vault-ssh-helper.zip \
    && unzip -o -q /tmp/vault-ssh-helper.zip -d /usr/local/bin/ \
    && chmod +x /usr/local/bin/vault-ssh-helper \
    && rm -f /tmp/vault-ssh-helper.zip

RUN useradd -m -s /bin/bash vaultlab && passwd -d vaultlab \
    && useradd -m -s /bin/bash ubuntu && passwd -d ubuntu

RUN mkdir -p /var/run/sshd && ssh-keygen -A

RUN printf '%s\n' \
        'auth requisite pam_exec.so quiet expose_authtok log=/tmp/vault-ssh.log /usr/local/bin/vault-ssh-helper -dev -config=/etc/vault-ssh-helper.d/config.hcl' \
        'auth optional  pam_unix.so not_set_pass use_first_pass nodelay' \
        'account required pam_unix.so' \
        'session required pam_unix.so' \
        > /etc/pam.d/sshd

RUN printf '%s\n' \
        'Port 22' \
        'PermitRootLogin no' \
        'PasswordAuthentication no' \
        'PubkeyAuthentication no' \
        'ChallengeResponseAuthentication yes' \
        'KbdInteractiveAuthentication yes' \
        'UsePAM yes' \
        > /etc/ssh/sshd_config

COPY entrypoint.sh /usr/local/bin/vault-ssh-otp-entrypoint
RUN chmod +x /usr/local/bin/vault-ssh-otp-entrypoint

EXPOSE 22

ENTRYPOINT ["/usr/local/bin/vault-ssh-otp-entrypoint"]
