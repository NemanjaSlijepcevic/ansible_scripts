FROM python:3.12-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        git \
        openssh-client \
        rsync \
        sshpass \
    && rm -rf /var/lib/apt/lists/*

# hvac backs the community.hashi_vault lookups the kestra role runs at deploy
# time to read its own flow secrets out of OpenBao.
RUN pip install --no-cache-dir ansible-core passlib hvac

# Collections used across client/ and update/ playbooks.
RUN ansible-galaxy collection install \
    community.docker \
    community.general \
    community.postgresql \
    community.crypto \
    community.hashi_vault \
    ansible.posix

# Ephemeral container — no persistent known_hosts.
ENV ANSIBLE_HOST_KEY_CHECKING=False

WORKDIR /workspace

CMD ["ansible-playbook", "--version"]
