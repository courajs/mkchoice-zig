source $stdenv/setup

global_cache=`mktemp -d`

zig build install \
  --global-cache-dir "$global_cache" \
  --cache-dir . \
  --prefix "$out" \
  --build-file "$src/build.zig"
