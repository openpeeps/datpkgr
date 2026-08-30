# datpkgr - An app/language agnostic package manager kit
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/datpkgr

import std/[os, strutils, tables, sets, sequtils, json, times, options]
import pkg/semver
import pkg/flysystem
import pkg/boogie/stores/rdbms
import pkg/openparser/json

import ./config
import ./store
import ./types
import ./resolver

proc recordInstall*(cfg: DatpkgrConfig, name, version: string, deps: seq[DepEntry], root = false,
    features: seq[string] = @[], installPath = "") =
  ## Record an installed package version with its resolved dependencies.
  ## `root` marks packages the user explicitly installed (vs. pulled as deps);
  ## only roots survive pruning. `features` are the active feature set the
  ## package was resolved with (used to emit `-d:features.<pkg>.<feat>`).
  ## `installPath` is the directory the compiler gets via `--path`.
  cfg.withDatpkgrDB do:
    let tbl = cfg.stores.db.getTable("installed").get()
    for (pk, row) in tbl.where("name", newTextValue(name)).toSeq():
      if row["version"].strVal == version:
        discard cfg.stores.db.deleteRow("installed", pk)
    var depsArr = newJArray()
    for (dn, dv) in deps:
      depsArr.add(%*{"name": dn, "version": dv})
    discard cfg.stores.db.insertRow("installed", row({
      "name": newTextValue(name),
      "version": newTextValue(version),
      "root": newBoolValue(root),
      "features": newJSONValue(%features),
      "deps": newJSONValue(depsArr),
      "path": newTextValue(installPath),
      "installed_at": newTextValue(now().format("yyyy-MM-dd'T'HH:mm:sszzz"))
    }))
    cfg.stores.db.checkpoint()

proc installedPath*(cfg: DatpkgrConfig, name, version: string): string =
  ## The recorded `--path` for an installed package version ("" if unknown).
  cfg.withDatpkgrDB do:
    let tbl = cfg.stores.db.getTable("installed").get()
    for (pk, row) in tbl.where("name", newTextValue(name)).toSeq():
      if row["version"].strVal == version:
        return row["path"].strVal
  ""

proc warnDevShadow(cfg: DatpkgrConfig, name, chosenPath: string)

proc resolveInstalledPath*(cfg: DatpkgrConfig, name, preferRef: string): string =
  ## The recorded `--path` for an installed package, preferring the explicit ref
  ## (branch/tag) when given, else the latest semver version.
  var chosen = ""
  cfg.withDatpkgrDB do:
    let tbl = cfg.stores.db.getTable("installed").get()
    var bestVer = newVersion(0, 0, 0)
    for (pk, row) in tbl.where("name", newTextValue(name)).toSeq():
      let ver = row["version"].strVal
      if ver.len > 0 and ver == preferRef:
        chosen = row["path"].strVal
        break
      try:
        let v = parseVersion(ver)
        if v > bestVer:
          bestVer = v
          chosen = row["path"].strVal
      except CatchableError:
        # Non-semver version (e.g. git ref like "head") — use as fallback
        # when no semver match has been found yet.
        if chosen.len == 0:
          chosen = row["path"].strVal
  if chosen.len > 0:
    cfg.warnDevShadow(name, chosen)
    return chosen
  ""

type
  InstalledRecord* = object
    version*: string
    path*: string
    root*: bool

proc installedRecords*(cfg: DatpkgrConfig, name: string): seq[InstalledRecord] =
  ## All installed records for `name` from the installed manifest. This is the
  ## source of truth for uninstall/prune — records can exist without any files
  ## on disk (develop-mode installs point at the user's source tree).
  cfg.withDatpkgrDB do:
    let tbl = cfg.stores.db.getTable("installed").get()
    for (pk, row) in tbl.where("name", newTextValue(name)).toSeq():
      result.add(InstalledRecord(
        version: row["version"].strVal,
        path: row["path"].strVal,
        root: row.hasKey("root") and row["root"].boolVal
      ))

proc isDevInstall*(cfg: DatpkgrConfig, rec: InstalledRecord): bool =
  ## True for develop-mode (editable) installs whose path points outside the
  ## package registry — i.e. at the user's own source tree. Such installs have
  ## no files under ~/.clue/packages; only their DB entry exists, and only the
  ## entry may ever be deleted.
  rec.path.len > 0 and not cfg.isInsidePkgs(rec.path)

proc installedRoots*(cfg: DatpkgrConfig): seq[string] =
  ## Names of every installed root package (top-level `clue install`s), in
  ## insertion order. Used by `clue update` with no argument.
  cfg.withDatpkgrDB do:
    let tbl = cfg.stores.db.getTable("installed").get()
    for (pk, row) in tbl.allRows():
      if row.hasKey("root") and row["root"].boolVal:
        result.add(row["name"].strVal)

var warnedDevShadows = initHashSet[string]()
var devShadowWarningsEnabled* = false
  ## Build commands enable this when `--verbose` is passed; the shadow warning
  ## would otherwise interleave with the live spinner line on a plain build.

proc warnDevShadow(cfg: DatpkgrConfig, name, chosenPath: string) =
  ## Warn when a build resolves `name` to its develop-mode source (a path
  ## outside the package registry) while a registry version is also installed —
  ## the live source silently shadows the pinned version. Only emitted on
  ## verbose builds. Warns once per package per process (`clue install --build`
  ## resolves deps through several paths).
  if not devShadowWarningsEnabled:
    return
  if name in warnedDevShadows:
    return
  if cfg.isInsidePkgs(chosenPath):
    return
  var registryVer = ""
  var devVer = ""
  for rec in cfg.installedRecords(name):
    if cfg.isDevInstall(rec):
      if devVer.len == 0:
        devVer = rec.version
    elif registryVer.len == 0:
      registryVer = rec.version
  if registryVer.len > 0:
    warnedDevShadows.incl(name)
    let dev = if devVer.len > 0: devVer else: "?"
    cfg.logWarn(name & ": using develop-mode source " & dev &
      " that shadows installed version " & registryVer &
      " — building against live source (" & chosenPath & ")")

proc collectInstalledDepNames*(cfg: DatpkgrConfig, rootNames: seq[string]): seq[string] =
  ## BFS over the installed manifest graph to collect every reachable
  ## dependency name, so the compiler gets `--path` for the whole tree.
  var depsOf: Table[string, seq[string]]
  cfg.withDatpkgrDB do:
    let tbl = cfg.stores.db.getTable("installed").get()
    for (pk, row) in tbl.allRows():
      let name = row["name"].strVal
      var deps: seq[string]
      try:
        for dep in parseJson(row["deps"].jsonVal):
          deps.add(dep["name"].getStr)
      except CatchableError:
        discard
      if deps.len == 0: continue
      if not depsOf.hasKey(name):
        depsOf[name] = @[]
      for d in deps:
        if d notin depsOf[name]:
          depsOf[name].add(d)
  var visited = initHashSet[string]()
  var queue = rootNames
  while queue.len > 0:
    let name = queue.pop()
    if name in visited:
      continue
    visited.incl(name)
    if depsOf.hasKey(name):
      for d in depsOf[name]:
        if d notin visited:
          queue.add(d)
  toSeq(visited)

proc resolveDepPathLike*(cfg: DatpkgrConfig, name: string): string =
  ## Locate the latest installed version dir for a package on disk (fallback
  ## for legacy installs that predate the recorded `path` column).
  let base = cfg.pkgsPath() / name
  let relBase = relativePath(base, cfg.rootPath)
  var hasBase = false
  try: hasBase = cfg.driver.exists(relBase)
  except: hasBase = dirExists(base)
  if not hasBase: return ""
  var best = ""
  var bestVer = newVersion(0, 0, 0)
  try:
    for meta in cfg.driver.list(relBase):
      if not meta.isDir: continue
      let entryPath = cfg.rootPath / meta.path
      try:
        let v = parseVersion(entryPath.extractFilename)
        if v > bestVer:
          bestVer = v
          best = entryPath
      except CatchableError: discard
  except:
    for entry in walkDir(base):
      if entry.kind == pcDir:
        try:
          let v = parseVersion(entry.path.extractFilename)
          if v > bestVer:
            bestVer = v
            best = entry.path
        except CatchableError: discard
  best

proc pathForImports*(cfg: DatpkgrConfig, p: string): string =
  let mf = cfg.findManifestInDir(p)
  if mf.len > 0:
    try:
      let content =
        if mf.startsWith(cfg.rootPath & DirSep):
          try: cfg.driver.read(relativePath(mf, cfg.rootPath))
          except: readFile(mf)
        else: readFile(mf)
      let m = cfg.parseManifest(content, mf)
      var srcDir = ""
      if m.extra != nil and m.extra.hasKey("srcDir"):
        srcDir = m.extra["srcDir"].getStr
      let src = if srcDir.len > 0: srcDir else: "src"
      let srcAbs = p / src
      var hasSrc = false
      if srcAbs.startsWith(cfg.rootPath & DirSep):
        try: hasSrc = cfg.driver.exists(relativePath(srcAbs, cfg.rootPath))
        except: hasSrc = dirExists(srcAbs)
      else: hasSrc = dirExists(srcAbs)
      if hasSrc:
        return srcAbs
    except CatchableError:
      discard
  p

proc allInstalledPaths*(cfg: DatpkgrConfig, ): seq[string] =
  ## One `--path` (install dir) per installed package — the latest version each —
  ## so `import xyz` / `import pkg/xyz` resolves for any clue-installed package.
  ## One path per package avoids Nim's ambiguity error from multiple versions.
  var bestBy: Table[string, tuple[ver: Version, path: string]]
  cfg.withDatpkgrDB do:
    for (pk, row) in cfg.stores.db.getTable("installed").get().allRows():
      let name = row["name"].strVal
      try:
        let v = parseVersion(row["version"].strVal)
        if not bestBy.hasKey(name) or v > bestBy[name].ver:
          bestBy[name] = (v, row["path"].strVal)
      except CatchableError:
        discard
  for name, entry in bestBy:
    var p = entry.path
    if p.len == 0:
      # legacy install without a recorded path — locate it on disk
      p = cfg.resolveDepPathLike(name)
    if p.len > 0:
      cfg.warnDevShadow(name, p)
      let src = cfg.pathForImports(p)
      if src notin result:
        result.add(src)

proc installedFeatures*(cfg: DatpkgrConfig, ): Table[string, seq[string]] =
  ## Map of installed package name -> the features it was resolved with.
  ## Features are unioned across the package's install records (a develop-mode
  ## record has none, so it must not hide a registry record's features).
  cfg.withDatpkgrDB do:
    let tbl = cfg.stores.db.getTable("installed").get()
    for (pk, row) in tbl.allRows():
      let name = row["name"].strVal
      if not result.hasKey(name):
        result[name] = @[]
      try:
        if row.hasKey("features"):
          for f in parseJson(row["features"].jsonVal):
            if f.getStr notin result[name]:
              result[name].add(f.getStr)
      except CatchableError:
        discard
  result

proc unrecordInstall*(cfg: DatpkgrConfig, name, version: string) =
  ## Remove an installed record (dirs removed separately by the caller).
  cfg.withDatpkgrDB do:
    let tbl = cfg.stores.db.getTable("installed").get()
    for (pk, row) in tbl.where("name", newTextValue(name)).toSeq():
      if version.len == 0 or row["version"].strVal == version:
        discard cfg.stores.db.deleteRow("installed", pk)
    cfg.stores.db.checkpoint()

proc pruneOrphans*(cfg: DatpkgrConfig, verbose = true) =
  ## Remove installed packages that are no longer reachable from any root,
  ## or whose resolved version no longer matches the current dependency graph.
  cfg.withDatpkgrDB do:
    let tbl = cfg.stores.db.getTable("installed").get()

    var depsOf: Table[string, seq[string]]  # "name@ver" -> deps
    var installed: seq[(string, string)]    # (name, ver)
    var explicitRoots: HashSet[string]      # name@ver the user installed directly
    for (pk, row) in tbl.allRows():
      let name = row["name"].strVal
      let ver = row["version"].strVal
      installed.add((name, ver))
      if row.hasKey("root") and row["root"].boolVal:
        explicitRoots.incl(name & "@" & ver)
      var deps: seq[string]
      try:
        for dep in parseJson(row["deps"].jsonVal):
          deps.add(dep["name"].getStr & "@" & dep["version"].getStr)
      except CatchableError:
        discard
      depsOf[name & "@" & ver] = deps

    # roots = packages the user explicitly installed (not transitive deps).
    # Without this, orphaned transitive deps would become pseudo-roots and
    # survive pruning after their parent is removed.
    var roots: seq[string]
    for key in explicitRoots:
      roots.add(key)

    # BFS from roots -> reachable set
    var reachable: HashSet[string]
    var queue = roots
    while queue.len > 0:
      let key = queue.pop()
      if key in reachable: continue
      reachable.incl(key)
      if depsOf.hasKey(key):
        for d in depsOf[key]:
          if d notin reachable:
            queue.add(d)

    var removed = 0
    for (name, ver) in installed:
      let key = name & "@" & ver
      if key in reachable: continue
      let dir = cfg.pkgsPath() / name / ver
      cfg.safeRemoveDir(dir)
      let parentDir = cfg.pkgsPath() / name
      let relParent = relativePath(parentDir, cfg.rootPath)
      var hasParent = false
      try: hasParent = cfg.driver.exists(relParent)
      except: hasParent = dirExists(parentDir)
      if hasParent:
        var hasEntries = false
        try:
          for meta in cfg.driver.list(relParent):
            hasEntries = true
            break
        except:
          for e in walkDir(parentDir):
            hasEntries = true
            break
        if not hasEntries:
          cfg.safeRemoveDir(parentDir)
      for (pk, row) in tbl.where("name", newTextValue(name)).toSeq():
        if row["version"].strVal == ver:
          discard cfg.stores.db.deleteRow("installed", pk)
          inc removed
          if verbose:
            cfg.logInfo("  removed " & name & "@" & ver)
          break
    if removed > 0:
      cfg.stores.db.checkpoint()
      if verbose:
        cfg.logInfo("Pruned " & $removed & " orphaned package(s)")
    else:
      if verbose:
        cfg.logInfo("No orphaned packages to prune")

proc installedCount*(cfg: DatpkgrConfig, ): int =
  cfg.withDatpkgrDB do:
    var n = 0
    for (pk, row) in cfg.stores.db.getTable("installed").get().allRows():
      inc n
    result = n
