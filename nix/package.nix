{
  lib,
  stdenv,
  zig,
}:
let
  zonContents = builtins.readFile ../build.zig.zon;
  versionMatch = builtins.match ".*\\.version = \"([^\"]+)\".*" zonContents;
  version = if versionMatch != null then builtins.elemAt versionMatch 0 else "0.0.0";
in
stdenv.mkDerivation (finalAttrs: {
  pname = "shgit";
  version = version;

  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../build.zig
      ../build.zig.zon
      ../src
      ../asset
      ../test
    ];
  };

  zigDeps = zig.fetchDeps {
    inherit (finalAttrs) src pname version;
    hash = "sha256-6DJn5XwbgqZvs+dUsp5fJLQQaaW3mA2L1PzKQTQQQgs=";
  };

  nativeBuildInputs = [ zig.hook ];

  postConfigure = ''
    ln -s ${finalAttrs.zigDeps} "$ZIG_GLOBAL_CACHE_DIR/p"
  '';

  zigBuildFlags = [ "-Doptimize=ReleaseFast" ];

  doCheck = true;
  zigCheckFlags = [ "-Doptimize=ReleaseFast" ];

  meta = {
    description = "Personal project overlay manager for git";
    homepage = "https://github.com/0byte-coding/shgit";
    license = lib.licenses.mit;
    mainProgram = "shgit";
    platforms = lib.platforms.unix;
  };
})
