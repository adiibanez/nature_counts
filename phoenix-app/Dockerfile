FROM elixir:1.18-otp-27-slim AS build

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    nodejs \
    npm \
    build-essential \
    pkg-config \
    libsrtp2-dev \
    ca-certificates \
    libavcodec-dev \
    libavutil-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

ENV MIX_ENV=prod

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
RUN mix deps.get --only prod && mix deps.compile

COPY config config
COPY lib lib
COPY priv priv
COPY assets assets

RUN cd assets && npm install
RUN mix compile
RUN mix assets.deploy
RUN mix release

# --- Runtime (NVIDIA CUDA base for GPU inference) ---
FROM nvidia/cuda:12.2.2-runtime-ubuntu22.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    libstdc++6 \
    openssl \
    libncurses5 \
    libsrtp2-1 \
    locales \
    libgl1 \
    libglib2.0-0 \
    libxcb1 \
    libxext6 \
    libsm6 \
    curl \
    && rm -rf /var/lib/apt/lists/*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8

WORKDIR /app
COPY --from=build /app/_build/prod/rel/naturecounts ./

ENV PHX_SERVER=true
ENV PORT=4005

EXPOSE 4005

CMD ["bin/naturecounts", "start"]
