# datpkgr - An app/language agnostic package manager kit
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/datpkgr

import std/[os, osproc, strutils, options, sequtils, tables, times]
import pkg/boogie/stores/rdbms
import pkg/openparser/json
import pkg/semver
import pkg/flysystem

import ./config
import ./types
import ./resolver

export rdbms

proc debugLog*(cfg: DatpkgrConfig, msg: string) =
  if cfg.debugEnabled:
    cfg.logDebug(msg)

proc isValidSourceName*(s: string): bool =
  if s.len == 0: return false
  for c in s:
    if c notin {'a'..'z', '0'..'9', '-', '_'}: return false
  true

proc sourceCachePath*(cfg: DatpkgrConfig, name: string): string =
  cfg.registriesDir() / name & ".json"

proc ensureSourcesFile*(cfg: DatpkgrConfig) =
  cfg.driver.makeDir("")
  cfg.driver.makeDir(cfg.registriesDir())
  if not cfg.driver.exists(cfg.sourcesPath()):
    let defaultSources = %*{"sources": [%*{"name": cfg.defaultSourceName, "url": cfg.defaultRegistryUrl}]}
    cfg.fs.write(cfg.sourcesPath(), pretty(defaultSources))

proc loadSources*(cfg: DatpkgrConfig): seq[Source] =
  cfg.ensureSourcesFile()
  try:
    let content = cfg.fs.read(cfg.sourcesPath())
    let j = fromJson(content)
    let arr = if j.kind == JObject and j.hasKey("sources"): j["sources"] else: j
    if arr.kind != JArray:
      cfg.logWarn("Invalid sources.json: expected array, using default")
      return @[Source(name: cfg.defaultSourceName, url: cfg.defaultRegistryUrl)]
    for item in arr:
      if item.hasKey("name") and item.hasKey("url"):
        let n = item["name"].getStr
        let u = item["url"].getStr
        if isValidSourceName(n) and u.len > 0:
          result.add(Source(name: n, url: u))
    if result.len == 0:
      result.add(Source(name: cfg.defaultSourceName, url: cfg.defaultRegistryUrl))
  except CatchableError as e:
    cfg.logWarn("Failed to read sources.json: " & e.msg & " — using default")
    result = @[Source(name: cfg.defaultSourceName, url: cfg.defaultRegistryUrl)]

proc saveSources*(cfg: DatpkgrConfig, sources: seq[Source]) =
  cfg.ensureSourcesFile()
  var arr = newJArray()
  for s in sources:
    arr.add(%*{"name": s.name, "url": s.url})
  cfg.fs.write(cfg.sourcesPath(), pretty(%*{"sources": arr}))

proc resetDatpkgrForTests*(cfg: DatpkgrConfig) =
  cfg.stores.initialized = false

proc seedPackagesTable*(cfg: DatpkgrConfig, registryPackages: JsonNode, source: string): int =
  for localPkg in registryPackages:
    if localPkg.hasKey("alias") or not localPkg.hasKey("web"):
      continue
    try:
      let mthd = if localPkg.hasKey"method": localPkg["method"].getStr else: ""
      discard cfg.stores.db.insertRow("packages", row({
        "name": newTextValue(localPkg["name"].getStr),
        "url": newTextValue(localPkg["url"].getStr),
        "method": newTextValue(mthd),
        "tags": newJsonValue(localPkg["tags"]),
        "description": newTextValue(localPkg["description"].getStr),
        "license": newTextValue(localPkg["license"].getStr),
        "web": newTextValue(localPkg["web"].getStr),
        "source": newTextValue(source)
      }))
      inc result
    except CatchableError:
      discard

proc seedPackagesTableDefault*(cfg: DatpkgrConfig, registryPackages: JsonNode): int =
  cfg.seedPackagesTable(registryPackages, cfg.defaultSourceName)

proc manifestCanonicalName(cfg: DatpkgrConfig, manifestPath: string): string =
  ## Language-agnostic package name from manifest. Tries parsed manifest
  ## `name` field first, falls back to filename without extension.
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

proc initDatpkgr*(cfg: DatpkgrConfig) =
  if cfg.stores.initialized:
    return
  cfg.stores.initialized = true

  cfg.driver.makeDir("")
  cfg.driver.makeDir("packages")
  cfg.driver.makeDir("packages/_cache")
  cfg.driver.makeDir("bin")
  cfg.driver.makeDir("develop")

  var hasDatabase = fileExists(cfg.dbPath())
  cfg.stores.db = newStore(cfg.dbPath(), StorageMode.smDisk,
                    enableWal = true, walFlushEveryOps = 100'u32)
  cfg.stores.versionsDB = newStore(cfg.versionsDBPath(), StorageMode.smDisk,
                        enableWal = true, walFlushEveryOps = 100'u32)

  cfg.stores.db.createTableIfNotExist(newTable(
    name = "packages",
    primaryKey = "id",
    columns = [
      newColumn("id", dtInt, false),
      newColumn("name", dtText, false),
      newColumn("url", dtText, false),
      newColumn("method", dtText, false),
      newColumn("tags", dtJson, false),
      newColumn("description", dtText, false),
      newColumn("license", dtText, false),
      newColumn("web", dtText, false),
      newColumn("source", dtText, false)
    ]
  ))

  block:
    let tblOpt = cfg.stores.db.getTable("packages")
    if tblOpt.isSome:
      let tbl = tblOpt.get()
      var hasSource = false
      for c in tbl.columns:
        if c.name == "source":
          hasSource = true
          break
      if not hasSource:
        var rows: seq[RowData]
        for (pk, row) in tbl.allRows():
          rows.add(row)
        cfg.stores.db.dropTable("packages")
        cfg.stores.db.createTable(newTable(
          name = "packages",
          primaryKey = "id",
          columns = [
            newColumn("id", dtInt, false),
            newColumn("name", dtText, false),
            newColumn("url", dtText, false),
            newColumn("method", dtText, false),
            newColumn("tags", dtJson, false),
            newColumn("description", dtText, false),
            newColumn("license", dtText, false),
            newColumn("web", dtText, false),
            newColumn("source", dtText, false)
          ]
        ))
        for row in rows:
          var r = row
          r["source"] = newTextValue(cfg.defaultSourceName)
          discard cfg.stores.db.insertRow("packages", r)
        cfg.stores.db.checkpoint()

  cfg.ensureSourcesFile()
  cfg.driver.makeDir(cfg.registriesDir())

  block:
    let cachePath = cfg.pkgsCachePath()
    if dirExists(cachePath):
      for kind, path in walkDir(cachePath):
        if kind != pcDir: continue
        let dirName = path.extractFilename
        var nf = cfg.findManifestInDir(path)
        if nf.len == 0: continue
        let canonical = cfg.manifestCanonicalName(nf)
        if canonical.len == 0 or canonical == dirName: continue
        let canonicalPath = cachePath / canonical
        if not dirExists(canonicalPath):
          try: moveDir(path, canonicalPath) except: discard
        try:
          let tbl = cfg.stores.db.getTable("packages").get()
          if tbl.where("name", newTextValue(canonical)).toSeq().len == 0:
            var copied = false
            for (_, row) in tbl.where("name", newTextValue(dirName)).toSeq():
              var r = row
              r["name"] = newTextValue(canonical)
              if r["source"].strVal.len == 0:
                r["source"] = newTextValue("direct")
              discard cfg.stores.db.insertRow("packages", r)
              copied = true
              break
            if not copied:
              var url = ""
              try:
                let (outp, code) = execCmdEx("git -C " & quoteShell(canonicalPath) & " config --get remote.origin.url")
                if code == 0: url = outp.strip()
              except: discard
              discard cfg.stores.db.insertRow("packages", row({
                "name": newTextValue(canonical),
                "url": newTextValue(url),
                "method": newTextValue("git"),
                "tags": newJsonValue(newJArray()),
                "description": newTextValue(""),
                "license": newTextValue(""),
                "web": newTextValue(""),
                "source": newTextValue("direct")
              }))
            cfg.stores.db.checkpoint()
        except: discard

    if cfg.stores.db.hasTable("installed"):
      try:
        let tblOpt = cfg.stores.db.getTable("installed")
        if tblOpt.isSome:
          let tbl = tblOpt.get()
          var toMigrate: seq[tuple[pk: string, row: RowData, canonical: string, oldPath: string, newPath: string]] = @[]
          for (pk, row) in tbl.allRows():
            let oldName = row["name"].strVal
            let oldPath = row["path"].strVal
            if oldPath.len == 0 or not dirExists(oldPath): continue
            var nf = cfg.findManifestInDir(oldPath)
            if nf.len == 0:
              let base = oldPath.parentDir()
              nf = cfg.findManifestInDir(base)
              if nf.len == 0: continue
            let canonical = cfg.manifestCanonicalName(nf)
            if canonical.len == 0 or canonical == oldName: continue
            let newPath = oldPath.replace(oldName, canonical)
            toMigrate.add((pk, row, canonical, oldPath, newPath))
          for item in toMigrate:
            let baseOld = cfg.pkgsPath() / item.row["name"].strVal
            let baseNew = cfg.pkgsPath() / item.canonical
            if dirExists(baseOld) and not dirExists(baseNew):
              try: moveDir(baseOld, baseNew) except: discard
            discard cfg.stores.db.deleteRow("installed", item.pk)
            var r = item.row
            r["name"] = newTextValue(item.canonical)
            r["path"] = newTextValue(item.newPath)
            discard cfg.stores.db.insertRow("installed", r)
          if toMigrate.len > 0:
            cfg.stores.db.checkpoint()
      except: discard

    if dirExists(cachePath):
      for kind, path in walkDir(cachePath):
        if kind != pcDir: continue
        var nf = cfg.findManifestInDir(path)
        if nf.len == 0: continue
        let canonical = cfg.manifestCanonicalName(nf)
        if canonical.len == 0: continue
        try:
          let tbl = cfg.stores.db.getTable("packages").get()
          if tbl.where("name", newTextValue(canonical)).toSeq().len == 0:
            var url = ""
            try:
              let (outp, code) = execCmdEx("git -C " & quoteShell(path) & " config --get remote.origin.url")
              if code == 0: url = outp.strip()
            except: discard
            if url.len == 0: continue
            discard cfg.stores.db.insertRow("packages", row({
              "name": newTextValue(canonical),
              "url": newTextValue(url),
              "method": newTextValue("git"),
              "tags": newJsonValue(newJArray()),
              "description": newTextValue(""),
              "license": newTextValue(""),
              "web": newTextValue(""),
              "source": newTextValue("direct")
            }))
            cfg.stores.db.checkpoint()
        except: discard

  if cfg.stores.db.hasTable("installed"):
    let installedTbl = cfg.stores.db.getTable("installed").get()
    var hasFeatures = false
    var hasPath = false
    for c in installedTbl.columns:
      if c.name == "features":
        hasFeatures = true
      elif c.name == "path":
        hasPath = true
    if not (hasFeatures and hasPath):
      cfg.stores.db.dropTable("installed")

  cfg.stores.db.createTableIfNotExist(newTable(
    name = "installed",
    primaryKey = "id",
    columns = [
      newColumn("id", dtInt, false),
      newColumn("name", dtText, false),
      newColumn("version", dtText, false),
      newColumn("root", dtBool, false),
      newColumn("features", dtJson, false),
      newColumn("deps", dtJson, false),
      newColumn("path", dtText, false),
      newColumn("installed_at", dtText, false)
    ]
  ))

  cfg.stores.versionsDB.createTableIfNotExist(newTable(
    name = "versions",
    primaryKey = "id",
    columns = [
      newColumn("id", dtInt, false),
      newColumn("name", dtText, false),
      newColumn("version", dtText, false),
      newColumn("tag", dtText, false),
      newColumn("discovered_at", dtText, false)
    ]
  ))
  cfg.stores.versionsDB.createTableIfNotExist(newTable(
    name = "deps",
    primaryKey = "id",
    columns = [
      newColumn("id", dtInt, false),
      newColumn("name", dtText, false),
      newColumn("version", dtText, false),
      newColumn("deps", dtJson, false),
      newColumn("cached_at", dtText, false)
    ]
  ))

  if cfg.stores.db.hasTable("versions"):
    let srcTbl = cfg.stores.db.getTable("versions").get()
    var versionRows: seq[tuple[name, version, tag, discoveredAt: string]]
    var depsRows: seq[tuple[name, version, depsJson: string]]
    for (pk, row) in srcTbl.allRows():
      if row["deps"].jsonVal.len > 2:
        depsRows.add((row["name"].strVal, row["version"].strVal, row["deps"].jsonVal))
      else:
        versionRows.add((row["name"].strVal, row["version"].strVal,
          row["tag"].strVal, row["discovered_at"].strVal))
    for (name, version, tag, at) in versionRows:
      discard cfg.stores.versionsDB.insertRow("versions", row({
        "name": newTextValue(name),
        "version": newTextValue(version),
        "tag": newTextValue(tag),
        "discovered_at": newTextValue(at)
      }))
    for (name, version, depsJson) in depsRows:
      discard cfg.stores.versionsDB.insertRow("deps", row({
        "name": newTextValue(name),
        "version": newTextValue(version),
        "deps": newJSONValue(parseJson(depsJson)),
        "cached_at": newTextValue(now().format("yyyy-MM-dd'T'HH:mm:sszzz"))
      }))
    if versionRows.len > 0 or depsRows.len > 0:
      cfg.stores.versionsDB.checkpoint()
    cfg.stores.db.dropTable("versions")
  if cfg.stores.db.hasTable("deps"):
    for (pk, row) in cfg.stores.db.getTable("deps").get().allRows():
      discard cfg.stores.versionsDB.insertRow("deps", row({
        "name": newTextValue(row["name"].strVal),
        "version": newTextValue(row["version"].strVal),
        "deps": newJSONValue(parseJson(row["deps"].jsonVal)),
        "cached_at": newTextValue(now().format("yyyy-MM-dd'T'HH:mm:sszzz"))
      }))
    cfg.stores.versionsDB.checkpoint()
    cfg.stores.db.dropTable("deps")

  if not hasDatabase:
    cfg.logInfo("Initializing Datpkgr database...")
    let sources = cfg.loadSources()
    var seededAny = false
    for src in sources:
      let cacheFile = cfg.sourceCachePath(src.name)
      var registryPackages: JsonNode
      var gotData = false
      if cfg.driver.exists(cacheFile):
        try:
          registryPackages = fromJson(cfg.fs.read(cacheFile))
          gotData = true
        except CatchableError:
          cfg.logWarn("Failed to read " & cacheFile & ": " & getCurrentExceptionMsg())
      elif src.name == cfg.defaultSourceName and fileExists(cfg.legacyRegistryPath):
        try:
          registryPackages = fromJson(readFile(cfg.legacyRegistryPath))
          gotData = true
          cfg.driver.makeDir(cfg.registriesDir())
          cfg.fs.write(cacheFile, $registryPackages)
        except CatchableError:
          cfg.logWarn("Failed to read " & cfg.legacyRegistryPath & ": " & getCurrentExceptionMsg())
      if not gotData:
        cfg.logInfo("Downloading registry for source: " & src.name & "...")
        try:
          cfg.driver.makeDir(cfg.registriesDir())
          let tmpFile = cacheFile & ".tmp"
          let tmpFull = cfg.rootPath / tmpFile
          let (output, exitCode) = execCmdEx("curl -fsSL --connect-timeout 10 -o " &
            quoteShell(tmpFull) & " " & quoteShell(src.url))
          if exitCode != 0:
            raise newException(IOError, "curl failed: " & output)
          registryPackages = fromJson(readFile(tmpFull))
          if cfg.driver.exists(tmpFile):
            cfg.driver.move(tmpFile, cacheFile)
          else:
            moveFile(tmpFull, cfg.rootPath / cacheFile)
          cfg.logInfo("Downloaded registry for " & src.name)
          gotData = true
        except CatchableError as e:
          cfg.logWarn("Could not download registry for " & src.name & ": " & e.msg)
          continue
      if gotData:
        discard cfg.seedPackagesTable(registryPackages, src.name)
        seededAny = true
    if seededAny:
      cfg.stores.db.checkpoint()
    else:
      cfg.logWarn("No registry data seeded — run source.fetch")

proc refreshSource*(cfg: DatpkgrConfig, sourceName: string): bool =
  var srcOpt: Option[Source]
  for s in cfg.loadSources():
    if s.name == sourceName:
      srcOpt = some(s)
      break
  if srcOpt.isNone:
    cfg.logError("Unknown source: " & sourceName)
    return false
  let src = srcOpt.get()
  let cacheFile = cfg.sourceCachePath(src.name)
  let tmpFile = cacheFile & ".tmp"
  try:
    cfg.driver.makeDir(cfg.registriesDir())
    let tmpFull = cfg.rootPath / tmpFile
    let cacheFull = cfg.rootPath / cacheFile
    let (output, exitCode) = execCmdEx("curl -fsSL --connect-timeout 10 -o " &
      quoteShell(tmpFull) & " " & quoteShell(src.url))
    if exitCode != 0:
      cfg.logError("Failed to download registry for " & src.name & ": " & output)
      return false
    var registryPackages: JsonNode
    try:
      registryPackages = fromJson(readFile(tmpFull))
    except CatchableError:
      removeFile(tmpFull)
      cfg.logError("Failed to parse registry for " & src.name & ": " & getCurrentExceptionMsg())
      return false
    if cfg.driver.exists(tmpFile):
      cfg.driver.move(tmpFile, cacheFile)
    else:
      moveFile(tmpFull, cacheFull)
    if src.name == cfg.defaultSourceName:
      try:
        createDir(cfg.legacyRegistryPath.parentDir())
        copyFile(cacheFull, cfg.legacyRegistryPath)
      except CatchableError: discard
    cfg.initDatpkgr()
    let tbl = cfg.stores.db.getTable("packages").get()
    for (pk, row) in tbl.allRows():
      if row["source"].strVal == src.name:
        discard cfg.stores.db.deleteRow("packages", pk)
    let count = cfg.seedPackagesTable(registryPackages, src.name)
    cfg.stores.db.checkpoint()
    cfg.logInfo("Updated " & src.name & " (" & $count & " packages)")
    return true
  except CatchableError as e:
    cfg.logError("Failed to update source " & sourceName & ": " & e.msg)
    false

proc refreshAllSources*(cfg: DatpkgrConfig): bool =
  var ok = true
  var anyOk = false
  for src in cfg.loadSources():
    if not cfg.refreshSource(src.name):
      ok = false
    else:
      anyOk = true
  result = anyOk

proc refreshRegistry*(cfg: DatpkgrConfig): bool =
  cfg.refreshAllSources()

template withDatpkgrDB*(cfg: DatpkgrConfig, body: untyped) =
  cfg.initDatpkgr()
  body

proc fetchPkgMeta*(cfg: DatpkgrConfig, pkgName: string, sourceFilter: string = ""): Option[PkgRef] =
  cfg.withDatpkgrDB do:
    let tbl = cfg.stores.db.getTable("packages").get()
    if sourceFilter.len > 0:
      let res = tbl.where("name", newTextValue(pkgName)).toSeq()
      for (_, row) in res:
        if row["source"].strVal == sourceFilter:
          return some(PkgRef(name: pkgName, url: row["url"].strVal, refStr: ""))
      if res.len > 0:
        var foundSources: seq[string]
        for (_, row) in res:
          foundSources.add(row["source"].strVal)
        cfg.logWarn("Package '" & pkgName & "' not found in source '" &
          sourceFilter & "' but found in: " & foundSources.join(", ") &
          " — use source=" & foundSources[0])
      return none(PkgRef)
    else:
      let sources = cfg.loadSources()
      var bySource = initTable[string, string]()
      for (_, row) in tbl.where("name", newTextValue(pkgName)).toSeq():
        let src = row["source"].strVal
        if src notin bySource:
          bySource[src] = row["url"].strVal
      for src in sources:
        if src.name in bySource:
          return some(PkgRef(name: pkgName, url: bySource[src.name], refStr: ""))
      let res = tbl.where("name", newTextValue(pkgName)).toSeq()
      if res.len == 0:
        return none(PkgRef)
      return some(PkgRef(name: pkgName, url: res[0][1]["url"].strVal, refStr: ""))
  none(PkgRef)

proc fetchAllPkgMetas*(cfg: DatpkgrConfig, pkgName: string): seq[PkgRef] =
  cfg.withDatpkgrDB do:
    for (_, row) in cfg.stores.db.getTable("packages").get().where("name", newTextValue(pkgName)).toSeq():
      result.add(PkgRef(name: pkgName, url: row["url"].strVal, refStr: ""))
