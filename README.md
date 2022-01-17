pandoc-ghcjs is a project to make ghcjs builds of
[pandoc](https://github.com/jgm/pandoc/) possible and reproducible.

Reproducibility is ensured via Nix flakes. Previous versions of pandoc-ghcjs
were attempted with vanilla Nix, then
[reflex-platform](https://github.com/reflex-frp/reflex-platform), but was
unable to get either to fully work.

## Rough summary of changes

- removed non-library modules
  - the main pandoc binary seems to stack overflow during linking, and can't get around it
- removed anything that transiently depends on the following
  - lua
  - conduit (which depends on network)

## Related links

- [markup.rocks](https://github.com/osener/markup.rocks): The original
  inspiration for this project. I was unable to build a working copy of this
  for use in my personal projects, which was why I started working on
  pandoc-ghcjs.
- <https://github.com/jgm/pandoc/issues/4535>: Discussion around removing C
  dependencies in pandoc.
- [configuration-ghcjs.nix](https://github.com/NixOS/nixpkgs/blob/master/pkgs/development/haskell-modules/configuration-ghcjs.nix):
  Nix code that deals with various issues with haskell packages when compiling
  with ghcjs.
- [Using Nix to build multi-package, full stack Haskell apps](https://jade.fyi/blog/nix-and-haskell):
  Blog post describing a large-scale ghcjs project that was instrumental in
  understanding Nix's Haskell infrastructure.

## TODO

- Try building example project that depends on pandoc-ghcjs
- Write build instructions
- Build using cabal (inside Nix) for shorter feedback cycle
- For now I'm only thinking of getting this running on the browser, but in
  general seems useful to be able to use via node as well. Benchmarking should
  probably be done here as well.
- Currently, large swathes of pandoc has been stripped out, which is pretty
  sad. Gradually adding back functionality by either implementing things in
  pure Haskell or switching out dependencies based on whether we're on ghcjs
  and is one goal.
  - Try compiling C dependencies to emscripten? There seems to be some prior
    work here:
    - <https://github.com/k0001/hs-foreign-emscripten>
    - [ccall import of emscripten export in GHCJS](https://stackoverflow.com/questions/46868261/ccall-import-of-emscripten-export-in-ghcjs)
- Believe it or not, [asterius](https://github.com/tweag/asterius) actually
  successfully seems to build pandoc as-is (there's even a demo). Naively
  writing a demo for this resulted in very large wasm sizes (<40MB) which I
  couldn't reduce. Regardless, it'll be nice to be able to seamlessly build
  pandoc using asterius via a Nix flake as well.
  - The [official demo](https://asterius.netlify.app/demo/pandoc/pandoc.html)
    and what looks like an
    [app similar to markup.rocks](https://github.com/y-taka-23/wasm-pandoc)
    weigh in at 87.19MB and 60.47MB, respectively.
- Wondering what sort of breakage will occur when (if?) ghcjs is unified with
  ghc as mentioned here: [Is GHCJS stuck on GHC
  8.6.5?](https://www.reddit.com/r/haskell/comments/msmv4l/is_ghcjs_stuck_on_ghc_865/gutn13h/).
  Hopefully the build process can be made simpler/easier.

## Work getting stuff into upstream

- <https://github.com/osener/markup.rocks/issues/21>
  - <https://github.com/mt-caret/bench-url-encode>
