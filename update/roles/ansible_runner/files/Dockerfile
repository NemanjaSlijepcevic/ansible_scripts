FROM python:3.12-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        git \
        openssh-client \
        rsync \
        sshpass \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir ansible-core passlib

# Collections used across client/ and update/ playbooks.
RUN ansible-galaxy collection install \
    community.docker \
    community.general \
    community.postgresql \
    community.crypto \
    ansible.posix

# Ephemeral container — no persistent known_hosts.
ENV ANSIBLE_HOST_KEY_CHECKING=False

WORKDIR /workspace

CMD ["ansible-playbook", "--version"]
