## datpkgr — app-agnostic package manager library
##
## Single `LocalDriver` rooted at `~/.<appName>` (via `DatpkgrConfig`).
## Filesystem abstracted via `flysystem`. Language-agnostic manifest:
## configure the main entry via
## `cfg.manifestParser` / `cfg.manifestFinder` / `cfg.manifestFileName`.

import ./datpkgr/types
import ./datpkgr/config
import ./datpkgr/store
import ./datpkgr/git
import ./datpkgr/versions
import ./datpkgr/install
import ./datpkgr/resolver
import ./datpkgr/operations

export types, config, store, git, versions, install, resolver, operations
