#! /bin/sh -xe
cd /srv/gluon-<%= @community %>

if [ "$1" = "clean" ]; then
  make GLUON_TARGET="ar71xx-generic" clean
  make GLUON_TARGET="mpc85xx-generic" clean
  exit 0
fi

if [ "$1" = "dirclean" ]; then
  make dirclean
  exit 0
fi

[ -d .git ] || git init

if [ "$1" = "" ]; then
  branch=stable
else
  branch="$1"; shift
fi

git remote rm origin || true
git remote add origin https://github.com/freifunk-gluon/gluon.git

git fetch origin
git checkout v<%= @gluon_version %>

make update
make GLUON_BRANCH="$branch" GLUON_TARGET="ar71xx-generic"  $*
make GLUON_BRANCH="$branch" GLUON_TARGET="mpc85xx-generic" $*

./propagate.sh "$branch"

