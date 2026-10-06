# datpkgr - An app/language agnostic package manager kit
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/datpkgr

import std/[os, osproc, strutils, tables, json, terminal, sequtils]
import pkg/flysystem
import pkg/boogie/stores/rdbms
import ./types

type
  LogLevel* = enum
    lvlDebug
    lvlInfo
    lvlSuccess
    lvlWarn
    lvlError

  LogSpan* = tuple
    fg: ForegroundColor
    bg: BackgroundColor
    text: string
      ## One styled slice of a single log line. Uses `std/terminal`'s color
      ## enums so hosts can hand them straight to their own display layer
      ## without a translation table, and no terminal is touched here.

  Callbacks* = object
    log*: proc(level: LogLevel, msg: string) {.gcsafe.}
    logStyled*: proc(level: LogLevel, spans: seq[LogSpan]) {.gcsafe.}
      ## Optional styled sink for the span overloads. When nil, spans are
      ## flattened into a plain `log` call so hosts with no color support
      ## still get the whole message.
    onFetch*: proc(name: string, versions: int, cached: bool) {.gcsafe.}
    onCloneStart*: proc(name, url: string) {.gcsafe.}
      ## Fired the moment a package clone/fetch starts (inside the
      ## parallel worker, before any network). Used for immediate mode
      ## output so a run never looks hung. Optional; nil = silent.
    onFetchStart*: proc(name: string) {.gcsafe.}
      ## Fired when version discovery for `name` starts (cache miss path).
      ## Optional; nil = silent.
    onInstallStart*: proc(label: string) {.gcsafe.}
      ## Fired when installation of one resolved package starts
      ## (`label` is e.g. `name@1.2.3`). Optional; nil = silent.
    onSubmodules*: proc(name, dest: string) {.gcsafe.}
      ## Fired once a package is installed whose checkout carries git
      ## submodules (`name` is the package, `dest` its cache checkout).
      ## When nil, operations fall back to an indented log line.

  DatpkgrStores* = object
    db*: Store
    versionsDB*: Store
    initialized*: bool
      ## True while the stores are open (cross-process lock held).
    setupDone*: bool
      ## One-time dirs/tables/migrations/seed ran for this config.
    dbDepth*: int
      ## Re-entrant `withDatpkgrDB` scope depth; 0 = closed, lock released.

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
    allowSubmodules*: bool

type Config* = DatpkgrConfig

proc defaultLog(level: LogLevel, msg: string) =
  case level
  of lvlDebug: stderr.writeLine("[datpkgr] " & msg)
  of lvlInfo: echo msg
  of lvlSuccess: echo msg
  of lvlWarn: stderr.writeLine("Warning: " & msg)
  of lvlError: stderr.writeLine("Er ror: " & msg)

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
    callbacks = Callbacks(), allowSubmodules = false): DatpkgrConfig =
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
    manifestFileName: defaultManifestFileName,
    allowSubmodules: allowSubmodules
  )

proc manifestNameForPkg*(cfg: DatpkgrConfig, pkgName: string): string =
  if cfg.manifestFileName != nil: cfg.manifestFileName(pkgName)
  else: defaultManifestFileName(pkgName)

proc alternateManifestName*(name: string): string =
  ## YAML spelling alternate for a manifest filename: `.yml` <-> `.yaml`.
  ## Returns "" when the name uses neither extension, so non-YAML
  ## toolchains (e.g. `pkg.nimble`, `manifest.json`) are unaffected.
  let lower = name.toLowerAscii()
  if lower.endsWith(".yml"):
    result = name[0 ..< name.len-3] & "yaml"
  elif lower.endsWith(".yaml"):
    result = name[0 ..< name.len-4] & "yml"

proc manifestNameCandidates*(cfg: DatpkgrConfig, pkgName = "*"): seq[string] =
  ## Manifest entry filenames to try, in order: the configured name plus the
  ## YAML spelling alternate when it differs. Lets YAML-based toolchains
  ## consume package repos regardless of which extension they use, with the
  ## configured (canonical) name always winning when both exist.
  let primary = cfg.manifestNameForPkg(pkgName)
  result = @[primary]
  if "*" notin primary:
    let alt = alternateManifestName(primary)
    if alt.len > 0 and alt != primary:
      result.add(alt)

proc findManifestForDir*(cfg: DatpkgrConfig, dir: string): string =
  if cfg.manifestFinder != nil: cfg.manifestFinder(dir) else: defaultManifestFinder(dir)

proc findManifestInDir*(cfg: DatpkgrConfig, dir: string): string =
  ## Only checks `dir` itself (no walk-up), used for cache/install dirs.
  ## Skips the toolchain's own entry file when `toolchainName` is configured.
  ## Tries each name from `manifestNameCandidates` in order, so a
  ## `tim.config.yaml` checkout is found even when the canonical name is
  ## `tim.config.yml` (and vice versa).
  ## Uses flysystem when `dir` is inside the driver root, otherwise raw.
  let toolchainEntry =
    if cfg.toolchainName.len > 0: cfg.manifestNameForPkg(cfg.toolchainName)
    else: ""
  # Inside-driver paths use flysystem; outside (e.g. /tmp, user project) use raw
  let inside = dir.startsWith(cfg.rootPath & DirSep) or dir == cfg.rootPath
  for pattern in cfg.manifestNameCandidates():
    if inside:
      let relDir = relativePath(dir, cfg.rootPath)
      if "*" in pattern:
        try:
          let relPattern = relDir / pattern
          for rel in cfg.driver.search(relPattern):
            let f = cfg.rootPath / rel
            if toolchainEntry.len > 0 and f.extractFilename == toolchainEntry:
              continue
            return f
        except CatchableError: discard
      else:
        let cand = dir / pattern
        let relCand = relativePath(cand, cfg.rootPath)
        try:
          if cfg.driver.exists(relCand):
            return cand
        except CatchableError: discard
    else:
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

proc logStyled*(cfg: DatpkgrConfig, level: LogLevel, spans: varargs[LogSpan]) =
  ## Emit one line made of styled slices. Prefers the host's styled sink and
  ## falls back to the plain one by concatenating the slice texts.
  let parts = spans.toSeq()
  if cfg.callbacks.logStyled != nil:
    cfg.callbacks.logStyled(level, parts)
  elif cfg.callbacks.log != nil:
    var msg = ""
    for s in parts:
      msg.add(s.text)
    cfg.callbacks.log(level, msg)

proc logWarn*(cfg: DatpkgrConfig, spans: varargs[LogSpan]) =
  if cfg.callbacks.log != nil or cfg.callbacks.logStyled != nil:
    cfg.logStyled(lvlWarn, spans)

proc logSuccess*(cfg: DatpkgrConfig, msg: string) =
  if cfg.callbacks.log != nil:
    cfg.callbacks.log(lvlSuccess, msg)

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
  let rel = relativePath(dir, cfg.rootPath)
  try:
    if cfg.driver.exists(rel):
      cfg.driver.deleteDir(rel, force = true)
  except CatchableError as e:
    cfg.logDebug("safeRemoveDir failed: " & e.msg)

proc safeRemoveSymlink*(cfg: DatpkgrConfig, p: string) =
  if not cfg.isInsideDevelop(p):
    cfg.logDebug("refusing to remove outside develop: " & p)
    return
  when defined(windows):
    # Windows links in develop/ are either true symlinks (admin/Developer
    # Mode) or NTFS junctions (privilege-free fallback from createDevelopLink).
    # Both report symlinkExists=true (any reparse point) with dirExists=true,
    # so reparse-tag sniffing is unnecessary — but removal MUST NOT go through
    # driver.delete: its removeDir fallback would recurse into the link
    # target. `rmdir` (no /S) removes symlinks-to-dirs and junctions as links
    # only, never traversing; it fails on real non-empty dirs (safe).
    try:
      if symlinkExists(p) and dirExists(p):
        let (_, code) = execCmdEx("cmd /c rmdir " & quoteShell(p))
        if code == 0:
          return
        cfg.logDebug("safeRemoveSymlink rmdir failed for: " & p)
        return
      elif symlinkExists(p):
        # File symlink (or broken link): unlink the entry itself.
        try:
          removeFile(p)
          return
        except CatchableError:
          let (_, code) = execCmdEx("cmd /c rmdir " & quoteShell(p))
          if code == 0:
            return
          cfg.logDebug("safeRemoveSymlink failed for: " & p)
          return
      elif dirExists(p):
        # A real directory (not a link) — never touch it.
        cfg.logDebug("refusing to remove real directory in develop: " & p)
        return
    except CatchableError as e:
      cfg.logDebug("safeRemoveSymlink failed: " & e.msg)
      return
  let rel = relativePath(p, cfg.rootPath)
  try:
    if cfg.driver.isSymlink(rel) or cfg.driver.exists(rel):
      cfg.driver.delete(rel)
  except CatchableError as e:
    cfg.logDebug("safeRemoveSymlink failed: " & e.msg)

proc createDevelopLink*(cfg: DatpkgrConfig, target, link: string): bool =
  ## Create the develop-mode entry `link` → `target` (both absolute).
  ## POSIX uses a symlink. On Windows a symlink needs admin/Developer Mode,
  ## so fall back to an NTFS junction (`mklink /J`, privilege-free for
  ## directories). Junctions traverse transparently and `expandSymlink` is a
  ## noop on Windows, so readers need no changes; removal goes through
  ## `safeRemoveSymlink`, which unlinks junctions without touching targets.
  when defined(windows):
    try:
      createSymlink(target, link)
      return true
    except OSError:
      cfg.logDebug("symlink needs privilege, falling back to junction for: " & link)
    except CatchableError as e:
      cfg.logDebug("symlink failed: " & e.msg)
    try:
      let (_, code) = execCmdEx("cmd /c mklink /J " & quoteShell(link) &
        " " & quoteShell(target))
      if code == 0 and dirExists(link):
        return true
    except CatchableError as e:
      cfg.logDebug("junction failed: " & e.msg)
    return false
  else:
    try:
      createSymlink(target, link)
      return true
    except CatchableError as e:
      cfg.logDebug("symlink failed: " & e.msg)
      return false
