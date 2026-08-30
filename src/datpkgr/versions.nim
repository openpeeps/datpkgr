# datpkgr - An app/language agnostic package manager kit
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/datpkgr

import std/[os, osproc, strutils, tables, sets, sequtils,
      algorithm, times, json, options, locks, monotimes, strtabs]

import pkg/semver
import pkg/malebolgia
import pkg/flysystem
import pkg/threading/semaphore

import ./config
import ./store
import ./resolver
import ./types
import ./git

type
  DiscoveredVersion* = object
    version*: Version
    tag*: string

  DepEntry* = tuple[name: string, version: string]

const MaxConcurrentGit* = 8

proc findLocalTags(dest: string): seq[string] {.gcsafe.} =
  ## List local git tags by reading the ref store directly (`.git/packed-refs`
  ## plus loose `refs/tags/`) — no `git` subprocess, so it's fast even across
  ## many packages.
  var seen = initHashSet[string]()
  let gitDir = dest / ".git"
  let packedRefs = gitDir / "packed-refs"
  if fileExists(packedRefs):
    for line in readFile(packedRefs).splitLines():
      let trimmed = line.strip()
      if trimmed.len == 0 or trimmed.startsWith("#"): continue
      let parts = trimmed.splitWhitespace()
      if parts.len >= 2 and parts[1].startsWith("refs/tags/"):
        var tag = parts[1]["refs/tags/".len .. ^1]
        if tag.endsWith("^{}"):
          continue # peeled annotated-tag ref — the plain tag ref is enough
        if tag notin seen:
          seen.incl(tag)
          result.add(tag)
  let refsDir = gitDir / "refs" / "tags"
  if dirExists(refsDir):
    for f in walkDirRec(refsDir):
      let tag = relativePath(f, refsDir)
      if tag.len > 0 and tag notin seen:
        seen.incl(tag)
        result.add(tag)

proc findLocalTags*(cfg: DatpkgrConfig, dest: string): seq[string] =
  ## Driver-aware overload: uses flysystem when inside root, else raw.
  let inside = dest.startsWith(cfg.rootPath & DirSep) or dest == cfg.rootPath
  if inside:
    var seen = initHashSet[string]()
    let gitDir = dest / ".git"
    let packedRefs = gitDir / "packed-refs"
    let relPacked = relativePath(packedRefs, cfg.rootPath)
    var packedContent = ""
    var hasPacked = false
    try:
      if cfg.driver.exists(relPacked):
        packedContent = cfg.driver.read(relPacked)
        hasPacked = true
    except: discard
    if hasPacked:
      for line in packedContent.splitLines():
        let trimmed = line.strip()
        if trimmed.len == 0 or trimmed.startsWith("#"): continue
        let parts = trimmed.splitWhitespace()
        if parts.len >= 2 and parts[1].startsWith("refs/tags/"):
          var tag = parts[1]["refs/tags/".len .. ^1]
          if tag.endsWith("^{}"): continue
          if tag notin seen:
            seen.incl(tag)
            result.add(tag)
    let refsDir = gitDir / "refs" / "tags"
    let relRefsDir = relativePath(refsDir, cfg.rootPath)
    try:
      if cfg.driver.exists(relRefsDir):
        for meta in cfg.driver.list(relRefsDir, recursive = true):
          if meta.isDir: continue
          let tag = relativePath(cfg.rootPath / meta.path, refsDir)
          if tag.len > 0 and tag notin seen:
            seen.incl(tag)
            result.add(tag)
    except: discard
    return result
  else:
    return findLocalTags(dest)

proc listRemoteTags(cfg: DatpkgrConfig, url: string): seq[string] =  ## List all tag refs on a git remote without cloning (SSH first, HTTPS
  ## fallback). Prompts are disabled so a dead URL fails fast, never blocks.
  var output: string
  var exitCode: int
  (output, exitCode) = cfg.gitExec("git ls-remote --tags " & toGitSshUrl(url),
    env = gitEnv(nonInteractive = true))
  if exitCode != 0:
    (output, exitCode) = cfg.gitExec("git ls-remote --tags " & url,
      env = gitEnv(nonInteractive = true))
  if exitCode != 0: return @[]
  var seen: seq[string]
  var set = initHashSet[string]()
  const prefix = "refs/tags/"
  for line in output.splitLines():
    let parts = line.splitWhitespace()
    if parts.len < 2: continue
    let refName = parts[1]
    if refName.endsWith("^{}"): continue   # skip peeled annotated-tag refs
    if refName.startsWith(prefix):
      let tag = refName[prefix.len .. ^1]
      if tag notin set:
        set.incl(tag)
        seen.add(tag)
  seen

proc parseTag(tag: string): tuple[ok: bool, ver: Version] =
  let verStr = if tag.startsWith("v"): tag[1 .. ^1] else: tag
  try:
    (true, parseVersion(verStr))
  except CatchableError:
    (false, newVersion(0, 0, 0))

proc tagForVersion*(dest: string, version: string): string =
  ## Find the exact git tag whose semver equals `version`.
  try:
    let want = parseVersion(version)
    for tag in findLocalTags(dest):
      let (ok, ver) = parseTag(tag)
      if ok and ver == want:
        return tag
  except CatchableError:
    discard
  let tags = findLocalTags(dest)
  if ("v" & version) in tags: return "v" & version
  if version in tags: return version
  ""

proc tagForVersion*(cfg: DatpkgrConfig, dest: string, version: string): string =
  ## Driver-aware overload.
  try:
    let want = parseVersion(version)
    for tag in findLocalTags(cfg, dest):
      let (ok, ver) = parseTag(tag)
      if ok and ver == want:
        return tag
  except CatchableError:
    discard
  let tags = findLocalTags(cfg, dest)
  if ("v" & version) in tags: return "v" & version
  if version in tags: return version
  ""

proc isCruftName(name: string, m: Manifest): bool =
  ## Generic cruft heuristic. `Manifest.extra` may contain `skipDirs`/`skipFiles`.
  let lower = name.toLowerAscii
  result = lower in [".git", ".github", ".gitignore", ".gitattributes",
                     "tests", "examples", "example", "docs", "nimcache"]
  if result: return
  if m.extra != nil and m.extra.kind == JObject:
    if m.extra.hasKey("skipDirs"):
      for v in m.extra["skipDirs"]:
        if lower == v.getStr.toLowerAscii: return true
    if m.extra.hasKey("skipFiles"):
      for v in m.extra["skipFiles"]:
        if lower == v.getStr.toLowerAscii: return true

proc installCleanCopy*(cacheDir, verDir: string, m: Manifest) =
  ## Generic clean copy using `Manifest`. `extra` may contain `srcDir`,
  ## `installDirs`, `installFiles`, `installExt`. Falls back to flat copy
  ## when unspecified, matching the former Nim-agnostic behavior.
  createDir(verDir)
  proc copyEntry(e: string) =
    let name = e.extractFilename
    if isCruftName(name, m): return
    if dirExists(e):
      copyDir(e, verDir / name)
    else:
      copyFile(e, verDir / name)
  var srcDirVal = ""
  var installDirs: seq[string]
  var installFiles: seq[string]
  var installExt: seq[string]
  if m.extra != nil and m.extra.kind == JObject:
    if m.extra.hasKey("srcDir"): srcDirVal = m.extra["srcDir"].getStr
    if m.extra.hasKey("installDirs"):
      for v in m.extra["installDirs"]: installDirs.add(v.getStr)
    if m.extra.hasKey("installFiles"):
      for v in m.extra["installFiles"]: installFiles.add(v.getStr)
    if m.extra.hasKey("installExt"):
      for v in m.extra["installExt"]: installExt.add(v.getStr)
  if srcDirVal.len > 0 and dirExists(cacheDir / srcDirVal):
    for e in walkDir(cacheDir / srcDirVal):
      copyEntry(e.path)
  else:
    for e in walkDir(cacheDir):
      copyEntry(e.path)
  if m.path.len > 0:
    let mf = cacheDir / m.path.extractFilename
    if fileExists(mf):
      copyFile(mf, verDir / m.path.extractFilename)
  for d in installDirs:
    if dirExists(cacheDir / d):
      copyDir(cacheDir / d, verDir / d)
  for f in installFiles:
    if fileExists(cacheDir / f):
      copyFile(cacheDir / f, verDir / f)
  if installExt.len > 0:
    let srcDir = if srcDirVal.len > 0: cacheDir / srcDirVal else: cacheDir
    var found: seq[string]
    for f in walkDirRec(srcDir):
      if f.extractFilename.splitFile.ext in installExt and f notin found:
        found.add(f)
    for f in found:
      let rel = relativePath(f, srcDir)
      let target = verDir / rel
      if not dirExists(target.parentDir()):
        createDir(target.parentDir())
      copyFile(f, target)

proc installCleanCopy*(cfg: DatpkgrConfig, cacheDir, verDir: string, m: Manifest) =
  ## Flysystem-aware wrapper: ensures verDir via driver, then delegates to raw copy.
  let relVerDir = relativePath(verDir, cfg.rootPath)
  try: cfg.driver.makeDir(relVerDir)
  except: createDir(verDir)
  installCleanCopy(cacheDir, verDir, m)

#
# Versions cache (DB)
#

proc cacheVersions(cfg: DatpkgrConfig, name: string, versions: seq[DiscoveredVersion]) =
  cfg.withDatpkgrDB do:
    let tbl = cfg.stores.versionsDB.getTable("versions").get()
    for (pk, row) in tbl.where("name", newTextValue(name)).toSeq():
      discard cfg.stores.versionsDB.deleteRow("versions", pk)
    let nowStr = now().format("yyyy-MM-dd'T'HH:mm:sszzz")
    for v in versions:
      discard cfg.stores.versionsDB.insertRow("versions", row({
        "name": newTextValue(name),
        "version": newTextValue($v.version),
        "tag": newTextValue(v.tag),
        "discovered_at": newTextValue(nowStr)
      }))
    cfg.stores.versionsDB.checkpoint()

proc cachedVersions*(cfg: DatpkgrConfig, name: string): seq[DiscoveredVersion] =
  ## Read the version list for `name` from the versions DB, newest first. The
  ## DB is authoritative once populated — no git or network is touched here, so
  ## repeat installs/builds stay fully offline.
  cfg.withDatpkgrDB do:
    let rows = cfg.stores.versionsDB.getTable("versions").get().where("name", newTextValue(name)).toSeq()
    if rows.len > 0:
      var all: seq[DiscoveredVersion]
      for (pk, row) in rows:
        try:
          all.add(DiscoveredVersion(version: parseVersion(row["version"].strVal),
                                    tag: row["tag"].strVal))
        except CatchableError:
          discard
      if all.len > 0:
        all.sort(proc(a, b: DiscoveredVersion): int = cmp(b.version, a.version))
        return all
  @[]

proc discoverFromTags(name: string, tags: seq[string]): seq[DiscoveredVersion] =
  ## Parse, sort and dedupe a tag list into semver versions (newest first).
  ## Dedupes e.g. "1.2.3" and "v1.2.3" pointing at the same version.
  var all: seq[DiscoveredVersion]
  for tag in tags:
    let (ok, ver) = parseTag(tag)
    if ok:
      all.add(DiscoveredVersion(version: ver, tag: tag))
  all.sort(proc(a, b: DiscoveredVersion): int = cmp(b.version, a.version))
  var seen: seq[Version]
  for v in all:
    if v.version notin seen:
      seen.add(v.version)
      result.add(v)

proc discoverVersions*(cfg: DatpkgrConfig, name, url: string, refresh = false,
    cloneOnMiss = true): seq[DiscoveredVersion] =
  ## Discover all semver versions for a package, newest first.
  ## Serves from the DB cache unless `refresh` is set. On a cache miss the
  ## package is cloned into `_cache` (first time only) and versions are read
  ## from its local git tags — no network afterwards; with `refresh` an existing
  ## clone is fetched (`git fetch --tags`) so new remote tags are picked up.
  ## With `cloneOnMiss = false` (the `clue versions` query) it lists the remote
  ## without cloning.
  if not refresh:
    let cached = cfg.cachedVersions(name)
    if cached.len > 0:
      return cached
  let dest = cfg.pkgsCachePath() / name
  let relDest = relativePath(dest, cfg.rootPath)
  var existsDest = false
  try: existsDest = cfg.driver.exists(relDest)
  except: existsDest = dirExists(dest)
  if existsDest:
    if refresh:
      discard cfg.refreshRemoteTags(dest, url, nonInteractive = true)
  elif cloneOnMiss:
    if not cfg.clonePackage(url, dest, refresh, nonInteractive = true):
      return @[]
    try: existsDest = cfg.driver.exists(relDest)
    except: existsDest = dirExists(dest)
  let tags =
    if existsDest: findLocalTags(cfg, dest)
    else: cfg.listRemoteTags(url)
  result = discoverFromTags(name, tags)
  cfg.cacheVersions(name, result)

type
  TagFetchJob = tuple[name: string, url: string, dest: string, refresh: bool]

proc fetchTagsJob(job: TagFetchJob): tuple[name: string, tags: seq[string]] {.gcsafe.} =
  ## Worker for `discoverVersionsBatch`: ensures the package is present in
  ## `_cache` — cloning on a miss, fetching new tags on an existing clone when
  ## `refresh` is set — then lists its local git tags. Non-interactive so dead
  ## URLs fail fast. Never touches the DB.
  let dest = job.dest
  var existsDest = dirExists(dest)
  let tmpCfgCheck = newDatpkgrConfig("datpkgr", dest.parentDir().parentDir(), debugEnabled = false)
  try: existsDest = tmpCfgCheck.driver.exists(relativePath(dest, tmpCfgCheck.rootPath))
  except: discard
  if not existsDest:
    let tmpCfg = newDatpkgrConfig("datpkgr", dest.parentDir().parentDir(), debugEnabled = false)
    if tmpCfg.cloneRepo(job.url, dest, nonInteractive = true):
      discard
    else:
      return (job.name, @[])
  elif job.refresh:
    let tmpCfg = newDatpkgrConfig("datpkgr", dest.parentDir().parentDir(), debugEnabled = false)
    discard tmpCfg.refreshRemoteTags(dest, job.url, nonInteractive = true)
  let tmpCfg2 = newDatpkgrConfig("datpkgr", dest.parentDir().parentDir(), debugEnabled = false)
  let tags =
    try: findLocalTags(tmpCfg2, dest)
    except: findLocalTags(dest)
  (job.name, tags)

proc discoverVersionsBatch*(cfg: DatpkgrConfig, pkgs: openArray[PkgRef], refresh = false,
    onDone: proc(name: string, versions: int, cached: bool) = nil):
    Table[string, seq[DiscoveredVersion]] =
  ## Discover versions for many packages at once. The clone-and-list steps run
  ## concurrently on the malebolgia pool; DB cache writes happen sequentially on
  ## the caller's thread since the store isn't thread-safe. `onDone` is called
  ## on the caller's thread as each package finishes (for live progress), with
  ## `cached` true when it was served from the local DB (no network). With
  ## `refresh` existing clones are fetched (`git fetch --tags`) so new remote
  ## tags are picked up for every package.
  var toFetch: seq[PkgRef]
  for pkg in pkgs:
    if pkg.name.len == 0 or result.hasKey(pkg.name):
      continue
    if not refresh:
      let cached = cfg.cachedVersions(pkg.name)
      if cached.len > 0:
        result[pkg.name] = cached
        if onDone != nil:
          onDone(pkg.name, cached.len, true)
        continue
    toFetch.add(pkg)
  if toFetch.len > 0:
    var results = newSeq[tuple[name: string, tags: seq[string]]](toFetch.len)
    var m = createMaster()
    m.awaitAll:
      for i, pkg in toFetch:
        m.spawn fetchTagsJob((pkg.name, pkg.url, cfg.pkgsCachePath() / pkg.name, refresh)) ->
          results[i]
    for i in 0 ..< toFetch.len:
      let (name, tags) = results[i]
      let versions = discoverFromTags(name, tags)
      cfg.debugLog("discover " & name & ": " & $versions.len & " version(s), " & $tags.len & " tag(s)")
      cfg.cacheVersions(name, versions)
      result[name] = versions
      if onDone != nil:
        onDone(name, versions.len, false)

proc headVersion*(cfg: DatpkgrConfig, name: string): Version =
  ## Version to register for a package with no semver tags: the version
  ## declared in its manifest (checked out at the default branch),
  ## or 0.0.0 when unknown. Uses the pluggable manifest entry.
  let dest = cfg.pkgsCachePath() / name
  var existsDest = false
  try: existsDest = cfg.driver.exists(relativePath(dest, cfg.rootPath))
  except: existsDest = dirExists(dest)
  if not existsDest:
    let meta = cfg.fetchPkgMeta(name)
    if meta.isNone:
      return newVersion(0, 0, 0)
    if not cfg.clonePackage(meta.get().url, dest):
      return newVersion(0, 0, 0)
  let manifestPath = cfg.findManifestInDir(dest)
  if manifestPath.len > 0:
    var hasMan = false
    try: hasMan = cfg.driver.exists(relativePath(manifestPath, cfg.rootPath))
    except: hasMan = fileExists(manifestPath)
    if hasMan:
      try:
        let content =
          try: cfg.driver.read(relativePath(manifestPath, cfg.rootPath))
          except: readFile(manifestPath)
        let m = cfg.parseManifest(content, manifestPath)
        if m.version.len > 0:
          return parseVersion(m.version)
      except CatchableError:
        discard
  let fallbackPath = dest / cfg.manifestNameForPkg(name)
  var hasFall = false
  try: hasFall = cfg.driver.exists(relativePath(fallbackPath, cfg.rootPath))
  except: hasFall = fileExists(fallbackPath)
  if hasFall:
    try:
      let content =
        try: cfg.driver.read(relativePath(fallbackPath, cfg.rootPath))
        except: readFile(fallbackPath)
      let m = cfg.parseManifest(content, fallbackPath)
      if m.version.len > 0:
        return parseVersion(m.version)
    except CatchableError:
      discard
  newVersion(0, 0, 0)

const
  depsCacheVersion = 6

type
  CachedDeps = object
    hard: seq[PkgDependency]
    features: Table[string, seq[PkgDependency]]
    dev: seq[PkgDependency]

proc depsToJsonArr(deps: seq[PkgDependency]): JsonNode =
  result = newJArray()
  for d in deps:
    var node = %*{"name": d.name, "url": d.url, "branch": d.branch,
                  "constraint": $d.constraint,
                  "isToolchain": d.isToolchain}
    if d.features.len > 0:
      node["features"] = %d.features
    result.add(node)

proc jsonToDepsArr(n: JsonNode): seq[PkgDependency] =
  for d in n:
    var features: seq[string]
    if d.hasKey("features"):
      for f in d["features"]:
        features.add(f.getStr)
    let isToolchainVal = if d.hasKey("isToolchain"): d["isToolchain"].getBool
                         elif d.hasKey("isNim"): d["isNim"].getBool else: false
    result.add(PkgDependency(
      name: d["name"].getStr,
      url: d["url"].getStr,
      branch: d["branch"].getStr,
      constraint: parseConstraint(d["constraint"].getStr),
      features: features,
      isToolchain: isToolchainVal
    ))

proc readCachedDeps(cfg: DatpkgrConfig, name, version: string): Option[CachedDeps] =
  cfg.withDatpkgrDB do:
    let rows = cfg.stores.versionsDB.getTable("deps").get().where("name", newTextValue(name)).toSeq()
    for (pk, row) in rows:
      if row["version"].strVal == version:
        try:
          let n = parseJson(row["deps"].jsonVal)
          if n.kind != JObject:
            # legacy cache format: a flat array of deps (no feature blocks)
            return some(CachedDeps(hard: jsonToDepsArr(n)))
          if not n.hasKey("v") or n["v"].getInt != depsCacheVersion:
            # cache written by an older clue — re-parse
            return none(CachedDeps)
          var res = CachedDeps(hard: jsonToDepsArr(n["hard"]))
          if n.hasKey("features"):
            for fname, fnode in n["features"]:
              res.features[fname] = jsonToDepsArr(fnode)
          if n.hasKey("dev"):
            res.dev = jsonToDepsArr(n["dev"])
          return some(res)
        except CatchableError:
          return none(CachedDeps)
  none(CachedDeps)

proc cacheDeps(cfg: DatpkgrConfig, name, version: string, deps: CachedDeps) =
  cfg.withDatpkgrDB do:
    let tbl = cfg.stores.versionsDB.getTable("deps").get()
    for (pk, row) in tbl.where("name", newTextValue(name)).toSeq():
      if row["version"].strVal == version:
        discard cfg.stores.versionsDB.deleteRow("deps", pk)
        break
    var featsNode = newJObject()
    for fname, fdeps in deps.features:
      featsNode[fname] = depsToJsonArr(fdeps)
    let depsNode = %*{"v": depsCacheVersion,
                      "hard": depsToJsonArr(deps.hard),
                      "features": featsNode,
                      "dev": depsToJsonArr(deps.dev)}
    discard cfg.stores.versionsDB.insertRow("deps", row({
      "name": newTextValue(name),
      "version": newTextValue(version),
      "deps": newJSONValue(depsNode),
      "cached_at": newTextValue(now().format("yyyy-MM-dd'T'HH:mm:sszzz"))
    }))
    cfg.stores.db.checkpoint()

proc defaultBranch(cfg: DatpkgrConfig, dest: string): string =
  ## The default branch name of a cached clone (origin/HEAD, fallback master).
  let (defOut, _) = cfg.gitExec("git -C " & dest &
    " symbolic-ref --quiet refs/remotes/origin/HEAD")
  var b = defOut.strip()
  if b.startsWith("refs/remotes/origin/"):
    b = b["refs/remotes/origin/".len .. ^1]
  if b.len == 0:
    b = "master"
  b

proc readManifestContent*(cfg: DatpkgrConfig, dest, name, version: string): string =
  ## Read a package version's manifest file via `git show` — no working-tree
  ## checkout. Uses `cfg.manifestNameForPkg` so the entry file is pluggable.
  let manifestName = cfg.manifestNameForPkg(name)
  let tag =
    if version == "0.0.0": ""
    else:
      let inside = dest.startsWith(cfg.rootPath & DirSep) or dest == cfg.rootPath
      if inside:
        try: tagForVersion(cfg, dest, version)
        except: tagForVersion(dest, version)
      else: tagForVersion(dest, version)
  let (output, exitCode) =
    if version == "0.0.0":
      cfg.gitExec("git -C " & dest & " show origin/" & cfg.defaultBranch(dest) & ":" &
        manifestName)
    else:
      if tag.len == 0:
        return ""
      cfg.gitExec("git -C " & dest & " show " & tag & ":" & manifestName)
  if exitCode == 0: output else: ""

proc readManifestContentGeneric*(cfg: DatpkgrConfig, dest, name, version: string): string =
  cfg.readManifestContent(dest, name, version)

proc getDeps*(cfg: DatpkgrConfig, name, version: string, features: seq[string] = @[],
    refresh = false, url = ""): seq[PkgDependency] =
  ## Lazily fetch the dependency list for a specific package version,
  ## including the requires of any activated `features`. Serves from the
  ## DB cache, cloning + parsing on first demand. `url` overrides the registry
  ## lookup when the package is only known by its repository URL.
  ## The manifest is read via `cfg.readManifestContent` and parsed via
  ## `cfg.manifestParser`, so the entry file is fully pluggable.
  cfg.debugLog("deps: " & name & "@" & version & (if url.len > 0: " <- " & url else: ""))
  result = @[]
  var cached: Option[CachedDeps]
  if not refresh:
    cached = cfg.readCachedDeps(name, version)
    if cached.isSome:
      for f in features:
        if not cached.get.features.hasKey(f):
          cached = none(CachedDeps)
          break

  var deps: CachedDeps
  if cached.isSome:
    deps = cached.get
  else:
    let dest = cfg.pkgsCachePath() / name
    var existsDest = false
    try: existsDest = cfg.driver.exists(relativePath(dest, cfg.rootPath))
    except: existsDest = dirExists(dest)
    if not existsDest:
      var pkgUrl = url
      if pkgUrl.len == 0:
        let meta = cfg.fetchPkgMeta(name)
        if meta.isSome:
          pkgUrl = meta.get().url
      if pkgUrl.len == 0:
        cfg.logWarn("Unknown package in registry: " & name)
        return @[]
      if not cfg.clonePackage(pkgUrl, dest, refresh):
        return @[]

    if version == "0.0.0" and refresh:
      discard cfg.gitExec("git -C " & dest & " fetch origin --quiet", env = gitEnv(nonInteractive = false))

    let manifestContent = cfg.readManifestContent(dest, name, version)
    if manifestContent.len > 0:
      let m = cfg.parseManifest(manifestContent, cfg.manifestNameForPkg(name))
      proc isToolchainDep(d: PkgDependency): bool =
        d.isToolchain or d.name == cfg.toolchainName
      for dep in m.dependencies:
        if not isToolchainDep(dep):
          deps.hard.add(dep)
      for fname, fdeps in m.features:
        var farr: seq[PkgDependency]
        for dep in fdeps:
          if not isToolchainDep(dep):
            farr.add(dep)
        deps.features[fname] = farr
      for dep in m.devDependencies:
        if not isToolchainDep(dep):
          deps.dev.add(dep)
      cfg.cacheDeps(name, version, deps)

  result = deps.hard
  for f in features:
    if deps.features.hasKey(f):
      for dep in deps.features[f]:
        result.add(dep)

#
# Installed manifest + pruning
#
