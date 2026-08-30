# datpkgr - operations (extracted from clue/commands/manager.nim)
#
# (c) 2026 George Lemon | MIT License
# App-agnostic package operations. No kapsis dependency.
# Language specifics via cfg.manifestParser / manifestFinder / manifestFileName
# and Manifest.extra. Parallelism via malebolgia.

import std/[sequtils, options, tables, sets, strformat, strutils,
          times, os, osproc, terminal, strtabs]

import pkg/semver
import pkg/openparser/json
import pkg/malebolgia

import ./types
import ./config
import ./store
import ./git
import ./versions
import ./install
import ./resolver

# ----------------------------------------------------------------------
# helpers (from manager.nim)
# ----------------------------------------------------------------------

proc pkgNameFromUrl*(url: string): string =
  var u = url.strip()
  for sep in ['#', '?']:
    let pos = u.find(sep)
    if pos >= 0:
      u = u[0 ..< pos]
  if u.startsWith("git+"):
    u = u[4 .. ^1]
  u = u.replace("://", "/")
  u = u.replace("git@", "")
  u = u.replace(":", "/")
  for part in u.split('/'):
    if part.len > 0:
      result = part
  if result.endsWith(".git"):
    result = result[0 ..< ^4]

proc depName*(d: PkgDependency): string =
  if d.name.len > 0: d.name
  elif d.url.len > 0: pkgNameFromUrl(d.url)
  else: ""

proc parseFeatureFlags*(s: string): seq[string] =
  for f in s.split(','):
    let ff = f.strip()
    if ff.len > 0:
      result.add(ff)

proc isGitUrl*(s: string): bool =
  s.startsWith("https://") or s.startsWith("http://") or
  s.startsWith("git@") or s.startsWith("git+") or
  s.startsWith("ssh://")

proc pluralize*(n: int, singular: string): string =
  singular & (if n == 1: "" else: "s")

proc fetchEventText(name: string, count: int, cached: bool): string =
  if cached:
    result = name & " (cached)"
  elif count == 0:
    result = "fetched " & name & " using HEAD"
  else:
    result = "fetched " & name & " (" & $count & " " & pluralize(count, "version") & ")"

# ----------------------------------------------------------------------
# install helpers
# ----------------------------------------------------------------------

type
  InstallJob = object
    name: string
    cacheDir: string
    verDir: string
    refStr: string
    verStr: string
    refresh: bool
    label: string
    manifestPath: string
    srcDir: string
    installDirs: seq[string]
    installFiles: seq[string]
    installExt: seq[string]
    skipDirs: seq[string]
    skipFiles: seq[string]

proc manifestForJob(job: InstallJob): Manifest =
  var extra = newJObject()
  extra["srcDir"] = newJString(job.srcDir)
  var arrDirs = newJArray()
  for s in job.installDirs: arrDirs.add(newJString(s))
  extra["installDirs"] = arrDirs
  var arrFiles = newJArray()
  for s in job.installFiles: arrFiles.add(newJString(s))
  extra["installFiles"] = arrFiles
  var arrExt = newJArray()
  for s in job.installExt: arrExt.add(newJString(s))
  extra["installExt"] = arrExt
  var arrSkipDirs = newJArray()
  for s in job.skipDirs: arrSkipDirs.add(newJString(s))
  extra["skipDirs"] = arrSkipDirs
  var arrSkipFiles = newJArray()
  for s in job.skipFiles: arrSkipFiles.add(newJString(s))
  extra["skipFiles"] = arrSkipFiles
  result = Manifest(path: job.manifestPath, extra: extra)

proc installResolvedPkg(job: InstallJob): bool {.gcsafe.} =
  if job.refStr.len > 0:
    if not checkoutRefRaw(job.cacheDir, job.refStr, job.refresh):
      return false
  elif job.verStr != "0.0.0":
    let tag = tagForVersion(job.cacheDir, job.verStr)
    if tag.len > 0:
      discard checkoutTagRaw(job.cacheDir, tag)
  try:
    let m = manifestForJob(job)
    installCleanCopy(job.cacheDir, job.verDir, m)
    return true
  except CatchableError:
    return false

proc manifestCanonicalName(cfg: DatpkgrConfig, manifestPath: string): string =
  try:
    let content = readFile(manifestPath)
    let m = cfg.parseManifest(content, manifestPath)
    if m.name.len > 0:
      return m.name
  except CatchableError:
    discard
  result = manifestPath.extractFilename.changeFileExt("")
  if result == "manifest":
    result = ""

# ----------------------------------------------------------------------
# core install
# ----------------------------------------------------------------------

proc installPackage*(cfg: DatpkgrConfig, pkgName: string, pkgRef: string = "",
    refresh = false, features: seq[string] = @[], verbose = true, url = "",
    doBuild = false, buildRelease = true, buildDebug = false,
    constraint: VersionConstraint = VersionConstraint(kind: vcAny, version: newVersion(0, 0, 0)),
    backend = "c", sourceFilter: string = "",
    buildHook: proc(pkgName: string, preferRef: string, backend: string): bool = nil): bool =
  ## Generic install via cfg. Returns true on success.
  ## `buildHook` is opt-in (builder stays in clue).
  cfg.withDatpkgrDB do:
    let showProgress = verbose # isatty check left to caller via verbose / callbacks
    proc progress(msg: string) =
      if showProgress: cfg.logInfo(msg)
    proc warn(msg: string) =
      cfg.logWarn(msg)
    proc fail(msg: string) =
      cfg.logError(msg)

    var rootMeta: PkgRef
    var curName = pkgName
    if url.len > 0:
      rootMeta = PkgRef(name: curName, url: url, refStr: "")
    else:
      let effectiveSource = if sourceFilter.len > 0: sourceFilter else: cfg.defaultSourceName
      let rootMetaOpt = cfg.fetchPkgMeta(curName, effectiveSource)
      if rootMetaOpt.isNone:
        fail("Package not found in registry: " & curName &
          (if sourceFilter.len > 0: " (source: " & sourceFilter & ")" else: ""))
        return false
      rootMeta = rootMetaOpt.get()

    var rootDest = cfg.pkgsCachePath() / curName
    if not dirExists(rootDest):
      progress("fetching " & curName & "...")
      if not cfg.clonePackage(rootMeta.url, rootDest):
        fail("Failed to fetch " & curName)
        return false
    else:
      progress("using cached " & curName)
      if refresh:
        discard cfg.clonePackage(rootMeta.url, rootDest, refresh = true)

    if url.len > 0:
      let nf = cfg.findManifestInDir(rootDest)
      if nf.len > 0:
        let canonical = manifestCanonicalName(cfg, nf)
        if canonical.len > 0 and canonical != curName:
          let canonicalDest = cfg.pkgsCachePath() / canonical
          if canonicalDest != rootDest:
            if dirExists(canonicalDest):
              try: removeDir(rootDest) except: discard
            else:
              try: moveDir(rootDest, canonicalDest) except: discard
            rootDest = canonicalDest
          let derivedInstBase = cfg.pkgsPath() / pkgName
          let canonicalInstBase = cfg.pkgsPath() / canonical
          if dirExists(derivedInstBase) and not dirExists(canonicalInstBase):
            try: moveDir(derivedInstBase, canonicalInstBase) except: discard
          curName = canonical
          rootMeta.name = canonical
          try:
            let tbl = cfg.stores.db.getTable("packages").get()
            let exists = tbl.where("name", newTextValue(curName)).toSeq().len > 0
            if not exists:
              var desc = ""
              var lic = ""
              try:
                let content = readFile(nf)
                let m = cfg.parseManifest(content, nf)
                desc = m.description
                lic = m.license
              except: discard
              discard cfg.stores.db.insertRow("packages", row({
                "name": newTextValue(curName),
                "url": newTextValue(rootMeta.url),
                "method": newTextValue("git"),
                "tags": newJsonValue(newJArray()),
                "description": newTextValue(desc),
                "license": newTextValue(lic),
                "web": newTextValue(""),
                "source": newTextValue("direct")
              }))
              cfg.stores.db.checkpoint()
          except: discard

    var rootConstraint = constraint
    if pkgRef.len > 0:
      try:
        rootConstraint = VersionConstraint(kind: vcExact, version: parseVersion(pkgRef))
      except CatchableError:
        rootMeta.refStr = pkgRef
        progress(curName & "@" & pkgRef)

    var registry: PackageRegistry
    var registered = initHashSet[string]()
    var pkgRefs = initTable[string, PkgRef]()
    pkgRefs[curName] = rootMeta

    proc registerVersions(name: string, versions: seq[DiscoveredVersion]) =
      if versions.len == 0:
        registry.addPackage(UnresolvedPackage(name: name,
          version: cfg.headVersion(name), dependencies: @[]))
      else:
        for v in versions:
          registry.addPackage(UnresolvedPackage(name: name,
            version: v.version, dependencies: @[]))
      registered.incl(name)

    registerVersions(curName, cfg.discoverVersions(curName, rootMeta.url, refresh))
    cfg.logDebug("root: " & curName & " (" & rootMeta.url & "), " &
      pluralize(registry[curName].len, "version") & " indexed")

    var seen = initHashSet[string]()
    seen.incl(curName)
    var expandQueue = @[curName]
    while expandQueue.len > 0:
      var nextNames = initHashSet[string]()
      for name in expandQueue:
        let meta = pkgRefs.getOrDefault(name, PkgRef())
        if meta.url.len == 0: continue
        let versions = cfg.cachedVersions(name)
        let ver = if versions.len > 0: $versions[0].version else: "0.0.0"
        for d in cfg.getDeps(name, ver, @[], refresh, meta.url):
          let dn = depName(d)
          if dn.len == 0 or dn in seen: continue
          var dmeta = pkgRefs.getOrDefault(dn, PkgRef())
          if dmeta.url.len == 0:
            if d.url.len > 0:
              dmeta = PkgRef(name: dn, url: d.url, refStr: "")
            else:
              let m = cfg.fetchPkgMeta(dn)
              if m.isSome: dmeta = m.get()
            pkgRefs[dn] = dmeta
          if dmeta.url.len == 0:
            warn("Unknown package in registry, skipping: " & dn)
            continue
          if d.branch.len > 0 or d.tag.len > 0:
            var m = dmeta
            m.refStr = if d.branch.len > 0: d.branch else: d.tag
            pkgRefs[dn] = m
            if not registry.hasKey(dn):
              registry.addPackage(UnresolvedPackage(name: dn,
                version: newVersion(0, 0, 0), dependencies: @[]))
            seen.incl(dn)
          else:
            nextNames.incl(dn)
      if nextNames.len == 0:
        break
      var toDiscover: seq[PkgRef]
      for name in nextNames:
        if name in registered: continue
        toDiscover.add(pkgRefs.getOrDefault(name, PkgRef()))
      if toDiscover.len > 0:
        cfg.logDebug("Phase A: fetching " & $toDiscover.len & " package(s)")
        progress("checking " & $toDiscover.len & " " & pluralize(toDiscover.len, "package") & "...")
        proc onFetch(name: string, count: int, cached: bool) =
          if showProgress:
            # use callbacks.onFetch if provided, else log
            if cfg.callbacks.onFetch != nil:
              cfg.callbacks.onFetch(name, count, cached)
            else:
              cfg.logInfo("  " & fetchEventText(name, count, cached))
        let discovered = cfg.discoverVersionsBatch(toDiscover, refresh, onFetch)
        for name, versions in discovered:
          registerVersions(name, versions)
        for m in toDiscover:
          if m.name notin discovered:
            registerVersions(m.name, @[])
      seen.incl(nextNames)
      expandQueue = @[]
      for name in nextNames:
        if name in registered:
          expandQueue.add(name)
    cfg.logDebug("Phase A done: " & $registered.len & " package(s) indexed")

    cfg.logDebug("Phase B: resolving " & curName)
    var activeFeatOf = initTable[string, seq[string]]()
    proc provider(name: string, version: Version, feats: seq[string]): seq[Dependency] =
      activeFeatOf[name] = feats
      let deps = cfg.getDeps(name, $version, feats, refresh, pkgRefs.getOrDefault(name).url)
      result = @[]
      for d in deps:
        let dn = depName(d)
        var meta = pkgRefs.getOrDefault(dn, PkgRef())
        if meta.url.len == 0:
          if d.url.len > 0:
            meta = PkgRef(name: dn, url: d.url, refStr: "")
            pkgRefs[dn] = meta
          else:
            let m = cfg.fetchPkgMeta(dn)
            if m.isSome:
              meta = m.get()
              pkgRefs[dn] = meta
        if meta.url.len == 0:
          warn("Unknown package in registry, skipping: " & dn)
          continue
        if d.branch.len > 0 or d.tag.len > 0:
          var m = meta
          m.refStr = if d.branch.len > 0: d.branch else: d.tag
          pkgRefs[dn] = m
          if not registry.hasKey(dn):
            registry.addPackage(UnresolvedPackage(name: dn,
              version: newVersion(0, 0, 0), dependencies: @[]))
          result.add(Dependency(name: dn,
            constraint: VersionConstraint(kind: vcExact, version: newVersion(0, 0, 0)),
            features: d.features))
        else:
          result.add(Dependency(name: dn, constraint: d.constraint, features: d.features))

    let roots = @[Dependency(name: curName, constraint: rootConstraint, features: features)]

    var resolution: Resolution
    try:
      while true:
        try:
          resolution = resolveDetailed(registry, roots, provider, maxProbes = 1000)
          break
        except PackageNotFoundError as e:
          var toDiscover: seq[PkgRef]
          for name in e.pending:
            if name in registered: continue
            let meta = pkgRefs.getOrDefault(name, PkgRef())
            if meta.url.len == 0: continue
            toDiscover.add(meta)
          if toDiscover.len == 0:
            fail("Could not resolve unknown package(s): " & e.pending.join(", "))
            return false
          progress("checking " & $toDiscover.len & " " & pluralize(toDiscover.len, "package") & "...")
          proc onFetch2(name: string, count: int, cached: bool) =
            if showProgress:
              if cfg.callbacks.onFetch != nil:
                cfg.callbacks.onFetch(name, count, cached)
              else:
                cfg.logInfo("  " & fetchEventText(name, count, cached))
          let discovered = cfg.discoverVersionsBatch(toDiscover, refresh, onFetch2)
          for name, versions in discovered:
            registerVersions(name, versions)
          for m in toDiscover:
            if m.name notin discovered:
              registerVersions(m.name, @[])
    except CircularDependencyError as e:
      fail("Circular dependency: " & e.msg); return false
    except VersionConflictError as e:
      fail("Version conflict: " & e.msg); return false
    except ResolverError as e:
      fail("Resolution failed: " & e.msg); return false

    var name2ver: Table[string, string]
    var verStrs: Table[string, string]
    for rp in resolution.packages:
      let meta = pkgRefs.getOrDefault(rp.name, PkgRef())
      name2ver[rp.name] = $rp.version
      verStrs[rp.name] = if meta.refStr.len > 0: meta.refStr else: $rp.version
    cfg.logDebug("resolved " & $resolution.packages.len & " package(s)")
    if verbose:
      cfg.logInfo("Dependency tree")
      proc renderDepTree(name: string, leading: string, isLast: bool, isRoot: bool,
          path: var HashSet[string]) =
        let refStr = pkgRefs.getOrDefault(name).refStr
        var label = name
        if refStr.len > 0:
          label.add(" @" & refStr)
        else:
          let ver = name2ver.getOrDefault(name)
          if ver.len > 0 and ver != "0.0.0":
            label.add(" v" & ver)
        let feats = activeFeatOf.getOrDefault(name)
        if feats.len > 0:
          label.add(" (features: " & feats.join(", ") & ")")
        var line = leading
        if not isRoot:
          line.add(if isLast: "└─ " else: "├─ ")
        cfg.logInfo(line & label)
        if name in path:
          return
        path.incl(name)
        let deps = resolution.depsOf.getOrDefault(name)
        for i, dep in deps:
          let childIsLast = i == deps.high
          let childLeading =
            if isRoot: ""
            else: leading & (if isLast: "   " else: "│  ")
          if dep.name in name2ver:
            renderDepTree(dep.name, childLeading, childIsLast, false, path)
          else:
            cfg.logInfo(childLeading & (if childIsLast: "└─ " else: "├─ ") &
              dep.name & " " & $dep.constraint)
        path.excl(name)
      var path = initHashSet[string]()
      renderDepTree(curName, "", false, true, path)

    for sv in resolution.softViolations:
      var msg = sv.name & " resolved to " & $sv.chosen &
        " ignoring constraint " & $sv.constraint
      if sv.fromPkg.len > 0:
        msg.add(" from " & sv.fromPkg)
      warn(msg)

    var installedCount = 0
    var installedLabels: seq[string]
    var jobs: seq[InstallJob]
    for rp in resolution.packages:
      let meta = pkgRefs.getOrDefault(rp.name, PkgRef())
      let verStr =
        if meta.refStr.len > 0: meta.refStr
        else: $rp.version
      cfg.logDebug("install: " & rp.name & "@" & verStr)
      let cacheDir = cfg.pkgsCachePath() / rp.name
      if not dirExists(cacheDir):
        var url = meta.url
        if url.len == 0:
          let m = cfg.fetchPkgMeta(rp.name)
          if m.isSome:
            url = m.get().url
        if url.len == 0:
          warn("No URL for " & rp.name & ", skipping")
          continue
        if not cfg.clonePackage(url, cacheDir):
          continue
      let verDir = cfg.pkgsPath() / rp.name / verStr
      let label =
        if meta.refStr.len > 0: " @" & verStr
        else: " v" & verStr
      if dirExists(verDir):
        installedCount.inc
        installedLabels.add(rp.name & "@" & verStr)
        continue
      # build Manifest for installCleanCopy via cfg
      let manifestPath = cfg.findManifestInDir(cacheDir)
      let manifest =
        if manifestPath.len > 0 and fileExists(manifestPath):
          try:
            let content = readFile(manifestPath)
            cfg.parseManifest(content, manifestPath)
          except: Manifest(path: manifestPath, extra: newJObject())
        else:
          let fallback = cacheDir / cfg.manifestNameForPkg(rp.name)
          if fileExists(fallback):
            try:
              let content = readFile(fallback)
              cfg.parseManifest(content, fallback)
            except: Manifest(path: fallback, extra: newJObject())
          else:
            Manifest(path: "", extra: newJObject())
      proc getStrSeq(node: JsonNode, key: string): seq[string] =
        if node != nil and node.kind == JObject and node.hasKey(key):
          for v in node[key]:
            result.add(v.getStr)
      let ex = manifest.extra
      let srcDirVal = if ex != nil and ex.hasKey("srcDir"): ex["srcDir"].getStr else: ""
      jobs.add(InstallJob(name: rp.name, cacheDir: cacheDir, verDir: verDir,
        refStr: meta.refStr, verStr: verStr, refresh: refresh, label: label,
        manifestPath: manifest.path, srcDir: srcDirVal,
        installDirs: getStrSeq(ex, "installDirs"),
        installFiles: getStrSeq(ex, "installFiles"),
        installExt: getStrSeq(ex, "installExt"),
        skipDirs: getStrSeq(ex, "skipDirs"),
        skipFiles: getStrSeq(ex, "skipFiles")))
    if jobs.len > 0:
      var results = newSeq[bool](jobs.len)
      var m = createMaster()
      m.awaitAll:
        for i, job in jobs:
          m.spawn installResolvedPkg(job) -> results[i]
      for i, ok in results:
        if ok:
          installedCount.inc
          installedLabels.add(jobs[i].name & "@" & jobs[i].verStr)
        else:
          warn("Failed to install " & jobs[i].name & " v" & jobs[i].verStr)

    for rp in resolution.packages:
      let meta = pkgRefs.getOrDefault(rp.name, PkgRef())
      let verStr = if meta.refStr.len > 0: meta.refStr else: $rp.version
      let feats = activeFeatOf.getOrDefault(rp.name)
      var deps: seq[types.DepEntry]
      for d in cfg.getDeps(rp.name, $rp.version, feats, url = pkgRefs.getOrDefault(rp.name).url):
        let dn = depName(d)
        if d.branch.len > 0:
          deps.add((dn, d.branch))
        elif verStrs.hasKey(dn):
          deps.add((dn, verStrs[dn]))
      cfg.recordInstall(rp.name, verStr, deps, root = rp.name == curName,
        features = feats, installPath = cfg.pkgsPath() / rp.name / verStr)

    if installedCount > 0:
      cfg.logInfo("Installed " & $installedCount & " " & pluralize(installedCount, "package"))
    for lbl in installedLabels:
      cfg.logInfo("  " & lbl)

    cfg.pruneOrphans(verbose)

    if doBuild and buildHook != nil:
      if not buildHook(curName, rootMeta.refStr, backend):
        return false
    return true

# ----------------------------------------------------------------------
# update / develop / prune / fetch / uninstall
# ----------------------------------------------------------------------

proc updateRootSubprocess(exe, name: string): int {.gcsafe.} =
  var subEnv = newStringTable()
  for k, v in envPairs():
    subEnv[k] = v
  var p = startProcess(exe, args = ["update", name], env = subEnv,
    options = {poUsePath, poParentStreams})
  result = p.waitForExit()
  p.close()

proc updatePackage*(cfg: DatpkgrConfig, name: string, verbose = false): bool =
  let recs = cfg.installedRecords(name)
  if recs.len > 0 and recs.all(proc(r: InstalledRecord): bool = cfg.isDevInstall(r)):
    cfg.logInfo("Skipping develop-mode package " & name & " (editable source, not registry-managed)")
    return true
  result = cfg.installPackage(name, "", refresh = true, verbose = verbose)

proc updateAllPackages*(cfg: DatpkgrConfig, verbose = false, exePath = ""): bool =
  let roots = cfg.installedRoots()
  if roots.len == 0:
    cfg.logInfo("No installed packages to update")
    return true
  if roots.len == 1:
    return cfg.updatePackage(roots[0], verbose)
  else:
    let exe = if exePath.len > 0: exePath else: getAppFilename()
    var codes = newSeq[int](roots.len)
    var m = createMaster()
    m.awaitAll:
      for i, name in roots:
        m.spawn updateRootSubprocess(exe, name) -> codes[i]
    if codes.anyIt(it != 0):
      return false
    return true

proc developPackage*(cfg: DatpkgrConfig, dir: string, verbose = true): bool =
  let manifestPath = cfg.findManifestForDir(dir)
  if manifestPath.len == 0:
    cfg.logError("No manifest file found in " & dir)
    return false
  var manifest: Manifest
  try:
    let content = readFile(manifestPath)
    manifest = cfg.parseManifest(content, manifestPath)
  except CatchableError as e:
    cfg.logError("Failed to parse manifest: " & e.msg)
    return false
  let pkgName = if manifest.name.len > 0: manifest.name else: manifestPath.extractFilename.changeFileExt("")
  let version = if manifest.version.len > 0: manifest.version else: "0.0.0"
  let linkPath = cfg.developPath() / pkgName
  discard existsOrCreateDir(cfg.developPath())
  cfg.safeRemoveSymlink(linkPath)
  createSymlink(dir, linkPath)
  var deps: seq[types.DepEntry]
  for d in manifest.dependencies:
    if d.isToolchain: continue
    deps.add((depName(d), ""))
  for _, fdeps in manifest.features:
    for d in fdeps:
      if d.isToolchain: continue
      let dn = depName(d)
      if dn.len > 0 and deps.anyIt(it.name == dn) == false:
        discard
  cfg.recordInstall(pkgName, version, deps, root = true,
    features = @[], installPath = linkPath)
  cfg.logInfo("Develop-mode: " & pkgName & "@" & version & " (editable, library discovery from " & dir & ")")
  true

proc prunePackages*(cfg: DatpkgrConfig, verbose = true) =
  cfg.pruneOrphans(verbose)

proc fetchRegistry*(cfg: DatpkgrConfig): bool =
  cfg.refreshRegistry()

proc installedHasPackage*(cfg: DatpkgrConfig, pkgName: string): bool =
  let pkgBase = cfg.pkgsPath() / pkgName
  var hasInstalled = false
  if dirExists(pkgBase):
    for entry in walkDir(pkgBase):
      if entry.kind == pcDir:
        hasInstalled = true
        break
  if not hasInstalled:
    hasInstalled = cfg.resolveInstalledPath(pkgName, "").len > 0
  if hasInstalled: return true
  let tblOpt = cfg.stores.db.getTable("packages")
  if tblOpt.isSome:
    let tbl = tblOpt.get()
    if tbl.where("name", newTextValue(pkgName)).toSeq().len > 0:
      return true
  false

proc uninstallPackage*(cfg: DatpkgrConfig, pkgName: string, pkgVersion: string = "",
    confirm: proc(msg: string): bool = nil, verbose = true): bool =
  ## Returns true if removed. `confirm` is injected UI (kapsis promptConfirm in clue).
  proc doConfirm(msg: string): bool =
    if confirm != nil: confirm(msg) else: true
  if pkgVersion.len > 0:
    var rec: InstalledRecord
    var found = false
    for r in cfg.installedRecords(pkgName):
      if r.version == pkgVersion:
        rec = r
        found = true
        break
    if not found:
      cfg.logError("Version not installed: " & pkgName & "@" & pkgVersion)
      return false
    if cfg.isDevInstall(rec):
      if doConfirm("Remove develop-mode install " & pkgName & "@" & pkgVersion & " (files kept)?"):
        cfg.unrecordInstall(pkgName, pkgVersion)
        cfg.safeRemoveSymlink(cfg.developPath() / pkgName)
        cfg.logInfo("Removed " & pkgName & "@" & pkgVersion & " (editable install, files untouched)")
      else:
        cfg.logInfo("Removal cancelled.")
        return false
    else:
      let verDir = cfg.pkgsPath() / pkgName / pkgVersion
      if dirExists(verDir):
        if doConfirm("Remove " & pkgName & "@" & pkgVersion & "?"):
          cfg.safeRemoveDir(verDir)
          cfg.unrecordInstall(pkgName, pkgVersion)
          cfg.logInfo("Removed " & pkgName & "@" & pkgVersion)
        else:
          cfg.logInfo("Removal cancelled.")
          return false
      else:
        cfg.logError("Version not installed: " & pkgName & "@" & pkgVersion)
        return false
  else:
    let recs = cfg.installedRecords(pkgName)
    var hasDirs = false
    if dirExists(cfg.pkgsPath() / pkgName):
      for e in walkDir(cfg.pkgsPath() / pkgName):
        if e.kind == pcDir:
          hasDirs = true
          break
    if recs.len == 0 and not hasDirs:
      cfg.logError("Package not found: " & pkgName)
      return false
    if doConfirm("Remove all versions of " & pkgName & "?"):
      cfg.safeRemoveDir(cfg.pkgsPath() / pkgName)
      cfg.unrecordInstall(pkgName, "")
      cfg.safeRemoveSymlink(cfg.developPath() / pkgName)
      cfg.logInfo("All versions of " & pkgName & " removed")
    else:
      cfg.logInfo("Uninstallation cancelled.")
      return false
  cfg.pruneOrphans(verbose)
  true

proc versionsFor*(cfg: DatpkgrConfig, pkgName: string, refresh = false): seq[DiscoveredVersion] =
  let metaOpt = cfg.fetchPkgMeta(pkgName)
  if metaOpt.isNone:
    cfg.logError("Package not found in registry: " & pkgName)
    return @[]
  let meta = metaOpt.get()
  cfg.discoverVersions(pkgName, meta.url, refresh)
