#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
if [ ! -f .demo.env ]; then
  password=$(openssl rand -base64 24 | tr -d '\n')
  secret=$(openssl rand -hex 32)
  umask 077
  {
    printf 'DEMO_PASSWORD=%s\n' "$password"
    printf 'JWT_SECRET_KEY=%s\n' "$secret"
  } > .demo.env
  printf 'Demo login: adult-a@example.invalid\nDemo password: %s\n' "$password"
fi
docker compose up --build -d
printf 'HausKlar demo: http://localhost:8001\n'
