FROM node:22-bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        jq \
        procps \
        python3 \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code

# Sandbox tasks run as the unprivileged node user (uid 1000); OAuth
# credentials persist in the /home/node volume mounted at runtime.
USER node
WORKDIR /workspace

ENTRYPOINT []
CMD ["claude", "--help"]
