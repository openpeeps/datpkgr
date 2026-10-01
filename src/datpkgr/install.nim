# datpkgr - An app/language agnostic package manager kit
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/datpkgr

import std/[os, strutils, tables, sets, sequtils, json, times, options, terminal]
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
    var existingRoot = false
    var existingPk = ""
    for (pk, row) in tbl.where("name", newTextValue(name)).toSeq():
      if row["version"].strVal == version:
        if row.hasKey("root") and row["root"].boolVal:
          existingRoot = true
        existingPk = pk
        break
    if existingPk.len > 0:
      discard cfg.stores.db.deleteRow("installed", existingPk)
    let newRoot = root or existingRoot
    var depsArr = newJArray()
    for (dn, dv) in deps:
      depsArr.add(%*{"name": dn, "version": dv})
    discard cfg.stores.db.insertRow("installed", row({
      "name": newTextValue(name),
      "version": newTextValue(version),
      "root": newBoolValue(newRoot),
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

proc developRecordPath*(cfg: DatpkgrConfig, name: string): string =
  ## The develop checkout path for `name` (symlink-expanded) when in develop
  ## mode, else "". An explicit editable checkout beats version ordering.
  if cfg.isDevelopAvailable(name):
    var p = cfg.developPath() / name
    try: p = expandSymlink(p) except: discard
    return p
  ""

proc resolveInstalledPath*(cfg: DatpkgrConfig, name, preferRef: string): string =
  ## The recorded `--path` for an installed package, preferring the explicit ref
  ## (branch/tag) when given, else the latest semver version.
  ## This is a pure lookup of what the manifest recorded: a row whose directory
  ## was removed behind our back (a `prune`, a manual `rm -rf`, a moved
  ## checkout) still resolves here. Callers that care must check the path
  ## themselves — `clue` does, before treating a dependency as usable.
  ## A develop-mode checkout always wins unpinned lookups: an explicit editable
  ## source beats version ordering. An explicit `preferRef` pin is still honored
  ## when it names a registry version the develop checkout does not satisfy.
  var chosen = ""
  cfg.withDatpkgrDB do:
    let tbl = cfg.stores.db.getTable("installed").get()
    let devPath = cfg.developRecordPath(name)
    var devVer = ""
    if devPath.len > 0:
      for (pk, row) in tbl.where("name", newTextValue(name)).toSeq():
        let p = row["path"].strVal
        if p.len > 0 and not cfg.isInsidePkgs(p):
          devVer = row["version"].strVal
          break
    if devPath.len > 0 and (preferRef.len == 0 or devVer == preferRef):
      chosen = devPath
    else:
      var bestVer = newVersion(0, 0, 0)
      for (pk, row) in tbl.where("name", newTextValue(name)).toSeq():
        let p = row["path"].strVal
        let ver = row["version"].strVal
        if ver.len > 0 and ver == preferRef:
          chosen = p
          break
        try:
          let v = parseVersion(ver)
          if v > bestVer:
            bestVer = v
            chosen = p
        except CatchableError:
          # Non-semver version (e.g. git ref like "head") — use as fallback
          # when no semver match has been found yet.
          if chosen.len == 0:
            chosen = p
  if chosen.len > 0:
    cfg.warnDevShadow(name, chosen)
    return chosen
  ""

type
  InstalledRecord* = object
    version*: string
    path*: string
    root*: bool

  InstalledSnapshot* = object
    ## The whole installed manifest read in a single table scan and DB scope.
    ## Prefer this over per-name lookups whenever more than a package or two is
    ## needed; see `installedSnapshot`.
    records*: Table[string, seq[InstalledRecord]]
    depsOf*: Table[string, seq[string]]
      ## Package name -> dependency names recorded on its rows (deduped).
    depsOfRec*: Table[string, seq[tuple[name, version: string]]]
      ## "name@version" -> that row's dependency edges, versions unexpanded.
      ## `pruneOrphans` qualifies these with the install graph; `depsOf` is
      ## the name-only view used for closure walks.
    featuresOf*: Table[string, seq[string]]
      ## Package name -> union of the features its rows were installed with.
    roots*: seq[string]
      ## "name@version" keys of rows flagged `root`, in table order. Versioned
      ## (not bare names) so a prune seed identifies exactly one install.

proc installedSnapshot*(cfg: DatpkgrConfig): InstalledSnapshot =
  ## Read the entire installed manifest once.
  ##
  ## Every per-name accessor opens the stores (taking an exclusive cross-process
  ## lock, replaying the WAL) and fsyncs them again on close, so a project with
  ## n dependencies that is inspected per name costs n store open/close cycles
  ## — the dominant cost of an install. One scan here, shared by the closure
  ## walk, the feature map, the root list and the prune sweep.
  ##
  ## Also reads each row's `deps`/`features` JSON once, instead of
  ## deserialising the column (`jsonVal`) and re-parsing it (`parseJson`) as the
  ## per-row consumers used to.
  cfg.withDatpkgrDB do:
    let tbl = cfg.stores.db.getTable("installed").get()
    for (pk, row) in tbl.allRows():
      let name = row["name"].strVal
      if name.len == 0: continue
      if not result.records.hasKey(name):
        result.records[name] = @[]
        result.depsOf[name] = @[]
        result.featuresOf[name] = @[]
        result.depsOfRec[name & "@" & row["version"].strVal] = @[]
      result.records[name].add(InstalledRecord(
        version: row["version"].strVal,
        path: row["path"].strVal,
        root: row.hasKey("root") and row["root"].boolVal
      ))
      if row.hasKey("root") and row["root"].boolVal:
        result.roots.add(name & "@" & row["version"].strVal)
      try:
        for dep in parseJson(row["deps"].jsonVal):
          let dn = dep["name"].getStr
          let dv = dep["version"].getStr
          if dn.len == 0: continue
          if dn notin result.depsOf[name]:
            result.depsOf[name].add(dn)
          result.depsOfRec[name & "@" & row["version"].strVal].add((dn, dv))
      except CatchableError:
        discard
      try:
        if row.hasKey("features"):
          for f in parseJson(row["features"].jsonVal):
            let fs = f.getStr
            if fs.len > 0 and fs notin result.featuresOf[name]:
              result.featuresOf[name].add(fs)
      except CatchableError:
        discard

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

proc installedRecordsAll*(cfg: DatpkgrConfig): Table[string, seq[InstalledRecord]] =
  ## Every installed record, keyed by package name, in one table scan and one
  ## DB scope. Callers that need many packages (a dependency closure walk, a
  ## reuse check over a project's whole manifest) must take one snapshot and
  ## read from it: `installedRecords` per name re-opens the store, replays the
  ## WAL and fsyncs on close, which dominates an install once a project has
  ## more than a handful of dependencies.
  cfg.withDatpkgrDB do:
    let tbl = cfg.stores.db.getTable("installed").get()
    for (pk, row) in tbl.allRows():
      let name = row["name"].strVal
      if name.len == 0: continue
      result[name].add(InstalledRecord(
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
  for key in cfg.installedSnapshot().roots:
    let atPos = key.rfind('@')
    if atPos > 0: result.add(key[0 ..< atPos]) else: result.add(key)

var warnedDevShadows = initHashSet[string]()
var devShadowWarningsEnabled* = false
  ## Build commands enable this when `--verbose` is passed; the shadow warning
  ## would otherwise interleave with the live spinner line on a plain build.

var devShadowNotesOnly* = false
  ## When set, `warnDevShadow` records its message in `devShadowNotes` instead
  ## of printing it, so the caller can attach the detail to a warning line it
  ## prints itself. `clue build --verbose` uses this to render one warning per
  ## dependency rather than two.

var devShadowNotes* = initTable[string, LogSpan]()
  ## Package name -> shadow detail slice, populated while `devShadowNotesOnly`.
  ## The detail is a slice rather than plain text so the host can render it in
  ## the color this kit picked.

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
  if devVer.len == 0:
    # No versioned dev-install record — read the version from the live
    # checkout's manifest so the warning never prints a bare "?".
    let devPath = cfg.developPath() / name
    var realDev = devPath
    try: realDev = expandSymlink(devPath)
    except: discard
    var mf = cfg.findManifestInDir(realDev)
    if mf.len == 0:
      mf = cfg.findManifestForDir(realDev)
    if mf.len == 0:
      mf = cfg.findManifestInDir(devPath)
    if mf.len > 0:
      try:
        let m = cfg.parseManifest(readFile(mf), mf)
        if m.version.len > 0:
          devVer = m.version
      except CatchableError: discard
  if registryVer.len > 0:
    warnedDevShadows.incl(name)
    let dev = if devVer.len > 0: devVer else: "?"
    let detail = "Using devel source " & dev &
      " that shadows installed version " & registryVer
    if devShadowNotesOnly:
      # The caller already printed "dep <name> → <path>", so the live source
      # needs no path of its own on this line.
      devShadowNotes[name] = (fg: fgCyan, bg: bgDefault, text: detail)
    else:
      cfg.logWarn((fg: fgDefault, bg: bgDefault, text: name & ": "),
        (fg: fgCyan, bg: bgDefault, text: detail),
        (fg: fgDefault, bg: bgDefault,
          text: " — building against live source (" & chosenPath & ")"))

proc collectInstalledDepNames*(cfg: DatpkgrConfig, rootNames: seq[string]): seq[string] =
  ## BFS over the installed manifest graph to collect every reachable
  ## dependency name, so the compiler gets `--path` for the whole tree.
  ## Returns the whole reachable set for *all* `rootNames` in one pass.
  let depsOf = cfg.installedSnapshot().depsOf
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

proc isInstalledOnDisk*(cfg: DatpkgrConfig, name: string): bool =
  ## Any installed-manifest row for `name` whose install dir exists on disk.
  ## Matches semver rows, `HEAD`/ref rows and develop rows alike — a db entry
  ## for an existing dir means the bits are reusable as-is.
  for rec in cfg.installedRecords(name):
    if rec.version.len == 0:
      continue
    let verDir = cfg.pkgsPath() / name / rec.version
    var onDisk = false
    try: onDisk = cfg.driver.exists(relativePath(verDir, cfg.rootPath))
    except: onDisk = dirExists(verDir)
    if onDisk or (rec.path.len > 0 and dirExists(rec.path)):
      return true
  false

proc installedVersionForReuse*(cfg: DatpkgrConfig, name, refStr: string): string =
  ## Installed version of `name` reusable as-is (record exists and the install
  ## dir is on disk), else "". A non-empty `refStr` (exact version, tag or
  ## branch) must match the record exactly; an empty `refStr` returns the
  ## newest installed semver version. Rolling `HEAD`/ref-only rows never
  ## satisfy an empty ref — they track moving upstream and must re-resolve.
  var bestVer = newVersion(0, 0, 0)
  for rec in cfg.installedRecords(name):
    if rec.version.len == 0:
      continue
    if refStr.len > 0:
      if rec.version != refStr:
        continue
    else:
      var v: Version
      try: v = parseVersion(rec.version)
      except CatchableError: continue
      if result.len > 0 and cmp(v, bestVer) <= 0:
        continue
      bestVer = v
    let verDir = cfg.pkgsPath() / name / rec.version
    var onDisk = false
    try: onDisk = cfg.driver.exists(relativePath(verDir, cfg.rootPath))
    except: onDisk = dirExists(verDir)
    if onDisk or (rec.path.len > 0 and dirExists(rec.path)):
      result = rec.version

proc closureOnDisk*(cfg: DatpkgrConfig, name: string): bool =
  ## Every package in `name`'s recorded closure (roots included —
  ## `collectInstalledDepNames` returns them) has an installed-manifest row
  ## with an existing dir.
  for n in cfg.collectInstalledDepNames(@[name]):
    if not cfg.isInstalledOnDisk(n):
      return false
  true

proc markInstalledRoot*(cfg: DatpkgrConfig, name, version: string) =
  ## Promote an installed record to a root (explicitly installed) without
  ## touching files — so a package first pulled as a dep survives pruning
  ## after the user installs it directly. All other columns are preserved.
  cfg.withDatpkgrDB do:
    let tbl = cfg.stores.db.getTable("installed").get()
    var targetPk = ""
    var deps: seq[DepEntry] = @[]
    var features: seq[string] = @[]
    var path = ""
    var installedAt = ""
    for (pk, row) in tbl.where("name", newTextValue(name)).toSeq():
      if row["version"].strVal == version:
        if row.hasKey("root") and row["root"].boolVal:
          targetPk = ""  # already a root — nothing to do
          break
        targetPk = pk
        try:
          for dep in parseJson(row["deps"].jsonVal):
            deps.add((dep["name"].getStr, dep["version"].getStr))
        except CatchableError: discard
        try:
          if row.hasKey("features"):
            for f in parseJson(row["features"].jsonVal):
              features.add(f.getStr)
        except CatchableError: discard
        path = row["path"].strVal
        if row.hasKey("installed_at"):
          installedAt = row["installed_at"].strVal
        break
    if targetPk.len > 0:
      discard cfg.stores.db.deleteRow("installed", targetPk)
      var depsArr = newJArray()
      for (dn, dv) in deps:
        depsArr.add(%*{"name": dn, "version": dv})
      discard cfg.stores.db.insertRow("installed", row({
        "name": newTextValue(name),
        "version": newTextValue(version),
        "root": newBoolValue(true),
        "features": newJSONValue(%features),
        "deps": newJSONValue(depsArr),
        "path": newTextValue(path),
        "installed_at": newTextValue(installedAt)
      }))
      cfg.stores.db.checkpoint()

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
  var bestRolling = false
  try:
    for meta in cfg.driver.list(relBase):
      if not meta.isDir: continue
      let entryPath = cfg.rootPath / meta.path
      try:
        let v = parseVersion(entryPath.extractFilename)
        if not bestRolling and v > bestVer:
          bestVer = v
          best = entryPath
      except CatchableError:
        # Rolling dir (HEAD, branch): newest upstream state — wins over semver.
        if not bestRolling:
          bestRolling = true
          best = entryPath
  except:
    for entry in walkDir(base):
      if entry.kind == pcDir:
        try:
          let v = parseVersion(entry.path.extractFilename)
          if not bestRolling and v > bestVer:
            bestVer = v
            best = entry.path
        except CatchableError:
          if not bestRolling:
            bestRolling = true
            best = entry.path
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
  ## Non-semver records (HEAD for tagless repos, branch pins) track moving
  ## upstream, so they rank above any fixed semver version. Without this,
  ## tagless packages (sole `HEAD` record) vanish from every `--path` list and
  ## dependents fail with `cannot open file` even though they are installed.
  ## A develop-mode checkout always wins for its package: an explicit editable
  ## source beats version ordering (rolling or semver).
  var bestBy: Table[string, tuple[ver: Version, path: string, rolling: bool]]
  var devPaths = initTable[string, string]()
  cfg.withDatpkgrDB do:
    for (pk, row) in cfg.stores.db.getTable("installed").get().allRows():
      let name = row["name"].strVal
      if not devPaths.hasKey(name):
        devPaths[name] = cfg.developRecordPath(name)
      if devPaths[name].len > 0:
        var dv = newVersion(0, 0, 0)
        try: dv = parseVersion(row["version"].strVal) except CatchableError: discard
        bestBy[name] = (dv, devPaths[name], false)
        continue
      let verStr = row["version"].strVal
      try:
        let v = parseVersion(verStr)
        if not bestBy.hasKey(name) or (not bestBy[name].rolling and v > bestBy[name].ver):
          bestBy[name] = (v, row["path"].strVal, false)
      except CatchableError:
        # Rolling ref (HEAD, branch): newest upstream state — wins over semver.
        # First rolling record wins ties; empty versions stay dropped (legacy).
        if verStr.len == 0: continue
        if not bestBy.hasKey(name) or not bestBy[name].rolling:
          bestBy[name] = (newVersion(0, 0, 0), row["path"].strVal, true)
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
  cfg.installedSnapshot().featuresOf

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
  ## Reads the manifest through one snapshot (a single table scan) and only
  ## opens the store again to delete the orphans it decides on.
  let snap = cfg.installedSnapshot()
  let explicitRoots: HashSet[string] = snap.roots.toHashSet()
  var installed: seq[(string, string)]              # (name, ver), table order
  var installedByName: Table[string, seq[string]]  # name -> versions
  for name, recs in snap.records:
    for rec in recs:
      installed.add((name, rec.version))
      if not installedByName.hasKey(name):
        installedByName[name] = @[]
      installedByName[name].add(rec.version)
  # Qualify dep edges with the install graph. Second pass over the snapshot
  # (not the table) because empty-version edges resolve via `installedByName`.
  var depsOf: Table[string, seq[string]]  # "name@ver" -> deps
  for name, recs in snap.records:
    for rec in recs:
      var deps: seq[string]
      for (dn, dv) in snap.depsOfRec.getOrDefault(name & "@" & rec.version, @[]):
        if dv.len == 0:
          if installedByName.hasKey(dn) and installedByName[dn].len > 0:
            deps.add(dn & "@" & installedByName[dn][0])
          else:
            deps.add(dn & "@")
        else:
          deps.add(dn & "@" & dv)
      depsOf[name & "@" & rec.version] = deps
  # roots = packages the user explicitly installed (not transitive deps).
  # Without this, orphaned transitive deps would become pseudo-roots and
  # survive pruning after their parent is removed.
  var roots: seq[string]
  for key in explicitRoots:
    roots.add(key)

  # BFS from roots -> reachable set (with wildcard fallback for empty-version deps)
  var reachable: HashSet[string]
  var queue = roots
  while queue.len > 0:
    let key = queue.pop()
    if key in reachable: continue
    reachable.incl(key)
    if depsOf.hasKey(key):
      for d in depsOf[key]:
        if d in reachable: continue
        if depsOf.hasKey(d) or d in reachable:
          queue.add(d)
        elif d.endsWith("@"):
          # wildcard: any installed version of that name
          let n = d[0 ..< d.len-1]
          if installedByName.hasKey(n):
            for v in installedByName[n]:
              let cand = n & "@" & v
              if cand notin reachable:
                queue.add(cand)
        else:
          # exact miss: try name fallback if version mismatch (e.g. HEAD vs semver)
          let atPos = d.rfind('@')
          if atPos >= 0:
            let n = d[0 ..< atPos]
            if installedByName.hasKey(n):
              var foundExact = false
              for v in installedByName[n]:
                if n & "@" & v == d:
                  foundExact = true
                  break
              if not foundExact and installedByName[n].len > 0:
                # fallback to any installed version of that name
                for v in installedByName[n]:
                  let cand = n & "@" & v
                  if cand notin reachable:
                    queue.add(cand)
                continue
          queue.add(d)

  # Collect the orphans first, then reopen the store once to drop their rows.
  # Filesystem removal stays outside the DB scope so other processes can use
  # the databases while it runs.
  var orphans: seq[(string, string)]  # (name, ver)
  for (name, ver) in installed:
    let key = name & "@" & ver
    if key in reachable: continue
    # also consider reachable by name fallback (legacy empty deps may have added wildcard)
    var isReachableByName = false
    if installedByName.hasKey(name):
      for v in installedByName[name]:
        if (name & "@" & v) in reachable:
          isReachableByName = true
          break
    if isReachableByName: continue
    orphans.add((name, ver))

  for (name, ver) in orphans:
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

  if orphans.len > 0:
    var removed = 0
    cfg.withDatpkgrDB do:
      let tbl = cfg.stores.db.getTable("installed").get()
      for (name, ver) in orphans:
        for (pk, row) in tbl.where("name", newTextValue(name)).toSeq():
          if row["version"].strVal == ver:
            discard cfg.stores.db.deleteRow("installed", pk)
            inc removed
            if verbose:
              cfg.logInfo("  removed " & name & "@" & ver)
            break
    if removed > 0:
      if verbose:
        cfg.logInfo("Pruned " & $removed & " orphaned package(s)")
    elif verbose:
      cfg.logInfo("No orphaned packages to prune")
  elif verbose:
    cfg.logInfo("No orphaned packages to prune")

proc installedCount*(cfg: DatpkgrConfig, ): int =
  cfg.withDatpkgrDB do:
    var n = 0
    for (pk, row) in cfg.stores.db.getTable("installed").get().allRows():
      inc n
    result = n
