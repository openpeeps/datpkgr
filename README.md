<p align="center">
  <b>datpkgr</b>, app-agnostic package manager kit<br>
  Language-agnostic core for building package managers. Written in Nim.
</p>

<p align="center">
  <code>nimble install datpkgr</code>
</p>

<p align="center">
  <a href="https://openpeeps.github.io/datpkgr">API reference</a><br>
  <img src="https://github.com/openpeeps/pistachio/workflows/test/badge.svg" alt="Github Actions">  <img src="https://github.com/openpeeps/pistachio/workflows/docs/badge.svg" alt="Github Actions">
</p>

## Overview

`datpkgr` extracts the reusable package-manager logic from `clue` into a library. It owns filesystem, database, resolver, git, version discovery and high-level operations. Language specifics are injected via three callbacks so the same core can back Nim (`*.nimble`), Python (`pyproject.toml`) or any manifest.

Single `LocalDriver` rooted at `~/.<appName>` via `flysystem`. No global state. Every operation takes an explicit `DatpkgrConfig`.

## Key Features

- app and language agnostic package manager
- depth-first search resolver, no PhD required
- single filesystem root, safe by default
- git-first version discovery with local cache
- parallel installs and editable develop mode
- clean installs and automatic prune of orphans
- multiple registries with simple source handling
- hermetic, no network needed for tests

## Installation

```nim
requires "datpkgr >= 0.1.0"
```

```bash
nimble install datpkgr
# or develop mode
clue develop
```

Requires `nim >= 2.2.10`, `semver`, `boogie`, `openparser`, `sweetsyntax`, `malebolgia`, `threading`, `flysystem`.

## Quick Start

### 1. Create a config

```nim
import datpkgr/config
import datpkgr/types

let cfg = newDatpkgrConfig("myapp")
# optional: silence logs in tests
cfg.callbacks.log = proc(lvl: LogLevel, msg: string) {.gcsafe.} = discard
```

Custom manifest (example: Nimble):

```nim
import datpkgr/config
import myapp/nimbleparser  # your parser returning Manifest

let cfg = newDatpkgrConfig("clue")
cfg.manifestParser = nimbleManifestParser
cfg.manifestFinder = nimbleManifestFinder
cfg.manifestFileName = proc(pkg: string): string = pkg & ".nimble"
cfg.toolchainName = "nim"
cfg.defaultRegistryUrl = "https://raw.githubusercontent.com/nim-lang/packages/master/packages.json"
cfg.defaultSourceName = "nim-lang"
cfg.legacyRegistryPath = getHomeDir() / ".nimble/packages_official.json"
```

You can also set `cfg.callbacks.onFetch` to get live progress:

```nim
cfg.callbacks.onFetch = proc(name: string, versions: int, cached: bool) {.gcsafe.} =
  echo name, " -> ", versions, if cached: " (cached)" else: ""
```

### 2. Install a package

```nim
import datpkgr/operations

let ok = cfg.installPackage("semver", "", verbose = true)
if not ok:
  echo "install failed"

# with URL, refresh, features, constraint, source filter, build hook
let ok2 = cfg.installPackage("mypkg", "1.2.3", refresh = false,
  features = @["ssl"], url = "https://github.com/org/mypkg.git",
  constraint = parseConstraint(">= 1.0.0"),
  sourceFilter = "nim-lang",
  buildHook = proc(pkgName, preferRef, backend: string): bool =
    # call your builder here, return true on success
    true
)
```

### 3. Resolver only

```nim
import datpkgr/resolver
import pkg/semver

var registry: PackageRegistry
registry.addPackage("X", parseVersion("1.0.0"), @[])
registry.addPackage("X", parseVersion("2.0.0"), @[])

proc provider(name: string, version: Version, features: seq[string]): seq[Dependency] =
  @[]

let res = registry.resolveDetailed(
  @[Dependency(name: "X", constraint: parseConstraint(">= 1.0.0"))],
  provider
)
echo res.packages  # @[X@2.0.0]
```

Constraint syntax: `*`, `""` -> `vcAny`, `1.2.3`/`= 1.2.3`/`==1.2.3` -> `vcExact`, `>=`, `>`, `<=`, `<`, `~`/`~>` (tilge, `< next minor`), `^` (caret, `< next major`/`minor`/`patch`), `0.0.0` sentinel means `any`.

### 4. Develop mode and uninstall

```nim
# editable symlink in ~/.myapp/develop/mypkg -> /path/to/mypkg
discard cfg.developPackage("/path/to/mypkg")

# uninstall with confirm callback (return true to confirm)
proc confirm(msg: string): bool = true
discard cfg.uninstallPackage("mypkg", "1.0.0", confirm)

# prune orphans
cfg.prunePackages()

# versions available
let vers = cfg.versionsFor("semver")
for v in vers: echo v.version
```

### 5. Git helpers

```nim
import datpkgr/git

echo toGitSshUrl("https://github.com/org/repo") # git@github.com:org/repo.git
let env = gitEnv(nonInteractive = true)
let ok = cfg.clonePackage("https://github.com/org/repo.git", "/tmp/dest")
discard cfg.checkoutTag("/tmp/dest", "v1.0.0")
```

## Module Overview

| Module | Purpose |
|---|---|
| `types` | `Source`, `Package`, `PkgRef`, `PkgDependency`, `Manifest`, `DepEntry`, `ManifestParser`/`Finder`, re-exports `resolver` |
| `config` | `DatpkgrConfig`, `Callbacks`, `newDatpkgrConfig`, `manifestNameForPkg`/`findManifest*`/`parseManifest`, `dbPath`/`pkgsPath` etc., `isInsidePkgs`/`safeRemove*`, `log*` |
| `store` | `loadSources`/`saveSources`, `seedPackagesTable`, `initDatpkgr`, `fetchPkgMeta`, `withDatpkgrDB`, migrations |
| `git` | `toGitSshUrl`, `gitEnv`/`gitExec`, `clonePackage`, `checkout*`, `gitHeadInfo`, `failedClones` |
| `versions` | `tagForVersion`, `installCleanCopy`, `discoverVersions`/`discoverVersionsBatch`, `headVersion`, `getDeps`, `readManifestContent` |
| `install` | `recordInstall`, `resolveInstalledPath`, `isDevInstall`, `collectInstalledDepNames`, `pruneOrphans`, `allInstalledPaths` |
| `resolver` | `parseConstraint`, `satisfies`, `addPackage`, `resolve`/`resolveDetailed` |
| `operations` | `installPackage`, `updatePackage`/`updateAllPackages`, `developPackage`, `uninstallPackage`, `versionsFor`, pure helpers |

`src/datpkgr.nim` re-exports all eight.

## Testing

```bash
# run datpkgr suite (89 tests, no network)
nimble test
# or manually
for f in tests/test_*.nim; do nim c -r --hints:off --path:src --path:tests "$f"; done
```

Tests use `tests/helpers.nim` `tempCfg` (isolated `LocalDriver` in `getTempDir`) and avoid real `~/.myapp` or `curl`. Tier 1 pure resolver/git/helpers, Tier 2 isolated FS/DB, Tier 3 integration flagged out (local `file://` bare repos if needed).

### Made with Datpkgr
CLI apps that integrate with datpkgr:

- [clue](https://github.com/openpeeps/clue) &bullet; an alternative package manager for Nim development
- [tim engine](https://github.com/openpeeps/clue) &bullet; a DSL with built-in template engine, source-to-source transpialtion and more
- [bro Stylesheets](https://github.com/openpeeps/bro) &bullet; An alternative to Dart SASS/SCSS fully written in Nim
- [dfkup](https://github.com/dfkup/dfkup) &bullet; A scripting language made in Nim

## License

MIT. Made by Humans from [OpenPeeps](https://github.com/openpeeps). Copyright OpenPeeps and Contributors, All rights reserved.

### Contributions and Support

- Found a bug? [Create a new Issue](https://github.com/openpeeps/pistachio/issues)
- Want to help? [Fork it!](https://github.com/openpeeps/pistachio/fork)

|  |  |
|---|---|
| <a href="https://opencode.ai/go?ref=BHMEEK48QX"><img src="https://github.com/openpeeps/pistachio/blob/main/.github/opencode.png" alt="OpenCode"></a> | Switch to **Open-Source LLMs** via OpenCode GO, choosing from a variety of powerful models such as DeepSeek, Qwen, Kimi, GLM-5, MiniMax, MiMo. [Use our referral link to get started!](https://opencode.ai/go?ref=BHMEEK48QX)|
