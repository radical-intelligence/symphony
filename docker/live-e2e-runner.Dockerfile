FROM elixir:1.19

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    docker-cli \
    docker-compose \
    git \
    make \
    nodejs \
    npm \
    openssh-client \
  && rm -rf /var/lib/apt/lists/*

RUN npm install --global @openai/codex
