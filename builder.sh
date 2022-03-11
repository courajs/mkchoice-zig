source $stdenv/setup
build_dir=`pwd`

# https://github.com/ziglang/zig/issues/6810
mkdir -p NIX_LOCAL_CACHE_HOME
export XDG_CACHE_HOME="$build_dir/NIX_LOCAL_CACHE_HOME"

cd "$src"

zig build install --prefix "$out" --cache-dir "$build_dir/zig-cache"
