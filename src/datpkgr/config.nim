# datpkgr - An app/language agnostic package manager kit
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/datpkgr

import std/[os, strutils, tables, json]
import pkg/flysystem
import pkg/boogie/stores/rdbms
import ./types

type
  LogLevel* = enum
    lvlDebug
    lvlInfo
    lvlWarn
    lvlError

  Callbacks* = object
    log*: proc(level: LogLevel, msg: string) {.gcsafe.}
    onFetch*: proc(name: string, versions: int, cached: bool) {.gcsafe.}

  DatpkgrStores* = object
    db*: Store
    versionsDB*: Store
    initialized*: bool

  DatpkgrConfig* = ref object
    appName*: string
    rootPath*: string
    fs*: Filesystem
    driver*: LocalDriver
    callbacks*: Callbacks
    debugEnabled*: bool
    stores*: DatpkgrStores
    defaultRegistryUrl*: string
    defaultSourceName*: string
    toolchainName*: string
    legacyRegistryPath*: string
    manifestParser*: ManifestParser
    manifestFinder*: ManifestFinder
    manifestFileName*: proc(pkgName: string): string

type Config* = DatpkgrConfig

proc defaultLog(level: LogLevel, msg: string) =
  case level
  of lvlDebug: stderr.writeLine("[datpkgr] " & msg)
  of lvlInfo: echo msg
  of lvlWarn: stderr.writeLine("Warning: " & msg)
  of lvlError: stderr.writeLine("Error: " & msg)

proc defaultManifestFileName(pkgName: string): string =
  ## Generic default: language-agnostic manifest. Apps override via
  ## `cfg.manifestFileName` (e.g. `proc(pkg: string): string = pkg & ".manifest"`).
  "manifest.json"

proc defaultManifestFinder(dir: string): string =
  ## Generic finder: walk up looking for `manifest.json`.
  var cur = dir
  var depth = 0
  while depth < 15:
    let cand = cur / "manifest.json"
    if fileExists(cand):
      return cand
    for f in walkFiles(cur / "*.json"):
      if f.extractFilename == "manifest.json":
        return f
    let parent = cur.parentDir()
    if parent == cur: break
    cur = parent
    inc depth
  ""

proc defaultManifestParser(content: string, path: string): Manifest =
  Manifest(path: path, name: path.splitFile.name, version: "", extra: newJObject())

proc newDatpkgrConfig*(appName: string, rootPath = "", debugEnabled = false,
    callbacks = Callbacks()): DatpkgrConfig =
  let app = appName.strip()
  let root = if rootPath.len > 0: rootPath else: getHomeDir() / ("." & app)
  let drv = newLocalDriver(root)
  let fs = newFilesystem("local")
  fs.addDisk("local", drv)
  var cbs = callbacks
  if cbs.log == nil:
    cbs.log = defaultLog
  result = DatpkgrConfig(
    appName: app,
    rootPath: drv.root,
    fs: fs,
    driver: drv,
    callbacks: cbs,
    debugEnabled: debugEnabled or getEnv("DATPKG_DEBUG") == "1" or defined(datpkgDebug),
    defaultRegistryUrl: "",
    defaultSourceName: "default",
    toolchainName: "",
    legacyRegistryPath: "",
    manifestParser: defaultManifestParser,
    manifestFinder: defaultManifestFinder,
    manifestFileName: defaultManifestFileName
  )

proc manifestNameForPkg*(cfg: DatpkgrConfig, pkgName: string): string =
  if cfg.manifestFileName != nil: cfg.manifestFileName(pkgName)
  else: defaultManifestFileName(pkgName)

proc findManifestForDir*(cfg: DatpkgrConfig, dir: string): string =
  if cfg.manifestFinder != nil: cfg.manifestFinder(dir) else: defaultManifestFinder(dir)

proc findManifestInDir*(cfg: DatpkgrConfig, dir: string): string =
  ## Only checks `dir` itself (no walk-up), used for cache/install dirs.
  ## Skips the toolchain's own entry file when `toolchainName` is configured.
  let pattern = cfg.manifestNameForPkg("*")
  let toolchainEntry =
    if cfg.toolchainName.len > 0: cfg.manifestNameForPkg(cfg.toolchainName)
    else: ""
  if "*" in pattern:
    for f in walkFiles(dir / pattern):
      if toolchainEntry.len > 0 and f.extractFilename == toolchainEntry:
        continue
      return f
  else:
    let cand = dir / pattern
    if fileExists(cand):
      return cand
  ""

proc parseManifest*(cfg: DatpkgrConfig, content: string, path: string): Manifest =
  if cfg.manifestParser != nil: cfg.manifestParser(content, path)
  else: defaultManifestParser(content, path)

proc logDebug*(cfg: DatpkgrConfig, msg: string) =
  if cfg.debugEnabled and cfg.callbacks.log != nil:
    cfg.callbacks.log(lvlDebug, msg)

proc logInfo*(cfg: DatpkgrConfig, msg: string) =
  if cfg.callbacks.log != nil:
    cfg.callbacks.log(lvlInfo, msg)

proc logWarn*(cfg: DatpkgrConfig, msg: string) =
  if cfg.callbacks.log != nil:
    cfg.callbacks.log(lvlWarn, msg)

proc logError*(cfg: DatpkgrConfig, msg: string) =
  if cfg.callbacks.log != nil:
    cfg.callbacks.log(lvlError, msg)

proc dbPath*(cfg: DatpkgrConfig): string = cfg.rootPath / (cfg.appName & ".db")
proc versionsDBPath*(cfg: DatpkgrConfig): string = cfg.rootPath / "versions.db"
proc pkgsPath*(cfg: DatpkgrConfig): string = cfg.rootPath / "packages"
proc pkgsCachePath*(cfg: DatpkgrConfig): string = cfg.rootPath / "packages" / "_cache"
proc binPath*(cfg: DatpkgrConfig): string = cfg.rootPath / "bin"
proc buildTempPath*(cfg: DatpkgrConfig): string = cfg.rootPath / "buildtemp"
proc developPath*(cfg: DatpkgrConfig): string = cfg.rootPath / "develop"
proc sourcesPath*(cfg: DatpkgrConfig): string = "sources.json"
proc registriesDir*(cfg: DatpkgrConfig): string = "registries"

proc isInsidePkgs*(cfg: DatpkgrConfig, dir: string): bool =
  let pkgs = cfg.pkgsPath()
  dir == pkgs or dir.startsWith(pkgs & DirSep)

proc isInsideDevelop*(cfg: DatpkgrConfig, p: string): bool =
  let dev = cfg.developPath()
  p.startsWith(dev & DirSep)

proc safeRemoveDir*(cfg: DatpkgrConfig, dir: string) =
  if not cfg.isInsidePkgs(dir):
    cfg.logDebug("refusing to remove outside packages: " & dir)
    return
  if dirExists(dir):
    try: removeDir(dir) except: discard

proc safeRemoveSymlink*(cfg: DatpkgrConfig, p: string) =
  if not cfg.isInsideDevelop(p):
    cfg.logDebug("refusing to remove outside develop: " & p)
    return
  if symlinkExists(p):
    try: removeFile(p) except: discard
