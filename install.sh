#!/bin/bash

set -xeuo pipefail

REV=v2.3.1

IMMICH_PATH=/var/lib/immich
APP=$IMMICH_PATH/app

if ! command -v pnpm >/dev/null 2>&1; then
  echo "pnpm is not activated, please follow README's Node.js setup"
  exit 1
fi

# Prevent Javascript OOM
export NODE_OPTIONS="--max-old-space-size=4096"

if [[ "$USER" != "immich" ]]; then
  # Disable systemd services, if installed
  (
    systemctl list-unit-files --type=service | grep "^immich" | while read i unused; do
      systemctl stop $i && \
        systemctl disable $i && \
        rm /*/systemd/system/$i &&
        systemctl daemon-reload
    done
  ) || true

  mkdir -p $IMMICH_PATH
  chown immich:immich $IMMICH_PATH

  mkdir -p /var/log/immich
  chown immich:immich /var/log/immich

  echo "Forking the script as user immich"
  sudo -u immich $0 $*

  echo "Starting systemd services"
  cp immich*.service /lib/systemd/system/
  systemctl daemon-reload
  for i in immich*.service; do
    systemctl enable $i
    systemctl start $i
  done
  exit 0
fi

# Sanity check, users should have VectorChord enabled
if psql -U immich -c "SELECT 1;" > /dev/null 2>&1; then
  # Immich is installed, check VectorChord
  if ! psql -U immich -c "SELECT * FROM pg_extension;" | grep "vchord" > /dev/null 2>&1; then
    echo "VectorChord is not enabled for Immich."
    echo "Please read https://github.com/immich-app/immich/blob/main/docs/docs/administration/postgres-standalone.md"
    exit 1
  fi
fi
if [ -e "$IMMICH_PATH/env" ]; then
  if grep -q DB_VECTOR_EXTENSION "$IMMICH_PATH/env"; then
    echo "Please remove DB_VECTOR_EXTENSION from your env file"
    exit 1
  fi
fi

BASEDIR=$(dirname "$0")
umask 077

rm -rf $APP $APP/../i18n
mkdir -p $APP

# Wipe pnpm, uv, etc
# This expects immich user's home directory to be on $IMMICH_PATH/home
rm -rf $IMMICH_PATH/home
mkdir -p $IMMICH_PATH/home
mkdir -p $IMMICH_PATH/home/.local/bin
echo 'umask 077' > $IMMICH_PATH/home/.bashrc
export PATH="$HOME/.local/bin:$PATH"

TMP=/tmp/immich-$(uuidgen)
if [[ $REV =~ ^[0-9A-Fa-f]+$ ]]; then
  # REV is a full commit hash, full clone is required
  git clone https://github.com/immich-app/immich $TMP
else
  git clone https://github.com/immich-app/immich $TMP --depth=1 -b $REV
fi
cd $TMP
git reset --hard $REV
rm -rf .git

# Replace /usr/src
grep -Rl /usr/src | xargs -n1 sed -i -e "s@/usr/src@$IMMICH_PATH@g"
mkdir -p $IMMICH_PATH/cache
grep -RlE "\"/build\"|'/build'" | xargs -n1 sed -i -e "s@\"/build\"@\"$APP\"@g" -e "s@'/build'@'$APP'@g"

# Setup pnpm
corepack use pnpm@latest

# Install extism/js-pdk for extism-js
curl -O https://raw.githubusercontent.com/extism/js-pdk/main/install.sh
sed -i \
  -e 's@sudo@@g' \
  -e "s@/usr/local/binaryen@$HOME/binaryen@g" \
  -e "s@/usr/local/bin@$HOME/.local/bin@g" \
    install.sh
./install.sh
rm install.sh

# immich-server
cd server
pnpm install --frozen-lockfile --force
pnpm run build
pnpm prune --prod --no-optional --config.ci=true
cd -

cd open-api/typescript-sdk
pnpm install --frozen-lockfile --force
pnpm run build
cd -

cd web
pnpm install --frozen-lockfile --force
pnpm run build
cd -

cd plugins
pnpm install --frozen-lockfile --force
pnpm run build
cd -

cp -aL server/node_modules server/dist server/bin $APP/
cp -a web/build $APP/www
cp -a server/resources server/package.json pnpm-lock.yaml $APP/
mkdir -p $APP/corePlugin
cp -a plugins/dist $APP/corePlugin/
cp -a plugins/manifest.json $APP/corePlugin/
cp -a LICENSE $APP/
cp -a i18n $APP/../
cd $APP
pnpm store prune
cd -

# Cleanup
rm -rf \
  $TMP \
  $IMMICH_PATH/home/.wget-hsts \
  $IMMICH_PATH/home/.pnpm \
  $IMMICH_PATH/home/.local/share/pnpm \
  $IMMICH_PATH/home/.cache

echo
echo "Done."
echo
