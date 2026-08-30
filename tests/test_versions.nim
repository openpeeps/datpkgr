import std/[os, strutils, unittest, json, tables]
import pkg/semver
import pkg/boogie/stores/rdbms
import datpkgr/config
import datpkgr/types
import datpkgr/store
import datpkgr/versions
import helpers

suite "versions — tagForVersion from git ref store":
  test "finds an exact semver tag among packed and loose refs":
    let dir = getTempDir() / "datpkgr_versions_tags" / $getCurrentProcessId()
    createDir(dir / ".git" / "refs" / "tags")
    defer: removeDir(dir)
    writeFile(dir / ".git" / "packed-refs",
      "# pack-refs with: peeled fully-peeled sorted\n" &
      "0000000000000000000000000000000000000001 refs/tags/v1.2.3\n" &
      "0000000000000000000000000000000000000001 refs/tags/v1.2.3^{}\n" &
      "0000000000000000000000000000000000000002 refs/tags/v2.0.0\n")
    writeFile(dir / ".git" / "refs" / "tags" / "1.5.0",
      "0000000000000000000000000000000000000003\n")

    check tagForVersion(dir, "1.2.3") == "v1.2.3"
    check tagForVersion(dir, "2.0.0") == "v2.0.0"
    check tagForVersion(dir, "1.5.0") == "1.5.0"
    check tagForVersion(dir, "9.9.9") == ""

  test "peeled annotated-tag refs are ignored":
    let dir = getTempDir() / "datpkgr_versions_peeled" / $getCurrentProcessId()
    createDir(dir / ".git")
    defer: removeDir(dir)
    writeFile(dir / ".git" / "packed-refs",
      "0000000000000000000000000000000000000001 refs/tags/v3.1.4^{}\n")
    check tagForVersion(dir, "3.1.4") == ""

suite "versions — installCleanCopy layout":
  test "flattens srcDir into the install dir, skipping cruft":
    let cache = getTempDir() / "datpkgr_versions_cache" / $getCurrentProcessId()
    let outDir = getTempDir() / "datpkgr_versions_out" / $getCurrentProcessId()
    createDir(cache / "src" / "sub")
    createDir(cache / "tests")
    defer: removeDir(cache); removeDir(outDir)
    writeFile(cache / "src" / "mod.nim", "module\n")
    writeFile(cache / "src" / "sub" / "helper.nim", "helper\n")
    writeFile(cache / "tests" / "t.nim", "test\n")
    writeFile(cache / "pkg.manifest", "pkg\n")

    let m = Manifest(path: "pkg.manifest", extra: %*{"srcDir": "src"})
    installCleanCopy(cache, outDir, m)

    check fileExists(outDir / "mod.nim")
    check fileExists(outDir / "sub" / "helper.nim")
    check not dirExists(outDir / "tests")
    check not dirExists(outDir / "src")

  test "uses repo root when no srcDir is declared":
    let cache = getTempDir() / "datpkgr_versions_root" / $getCurrentProcessId()
    let outDir = getTempDir() / "datpkgr_versions_rootout" / $getCurrentProcessId()
    createDir(cache)
    defer: removeDir(cache); removeDir(outDir)
    writeFile(cache / "main.nim", "main\n")
    writeFile(cache / ".gitignore", "x\n")
    let m = Manifest(path: "", extra: newJObject())
    installCleanCopy(cache, outDir, m)
    check fileExists(outDir / "main.nim")
    check not fileExists(outDir / ".gitignore")

  test "copies installDirs, installFiles and installExt":
    let cache = getTempDir() / "datpkgr_versions_ext" / $getCurrentProcessId()
    let outDir = getTempDir() / "datpkgr_versions_extout" / $getCurrentProcessId()
    createDir(cache / "src")
    createDir(cache / "assets")
    createDir(cache / "src" / "deep")
    defer: removeDir(cache); removeDir(outDir)
    writeFile(cache / "assets" / "logo.png", "png")
    writeFile(cache / "LICENSE", "mit")
    writeFile(cache / "src" / "deep" / "extra.toml", "cfg")
    writeFile(cache / "src" / "deep" / "code.nim", "code")

    let m = Manifest(path: "", extra: %*{"srcDir": "src", "installDirs": ["assets"], "installFiles": ["LICENSE"], "installExt": [".toml"]})
    installCleanCopy(cache, outDir, m)

    check fileExists(outDir / "assets" / "logo.png")
    check fileExists(outDir / "LICENSE")
    check fileExists(outDir / "deep" / "extra.toml")
    check fileExists(outDir / "deep" / "code.nim")

  test "respects skipDirs/skipFiles via extra":
    let cache = getTempDir() / "datpkgr_versions_skip" / $getCurrentProcessId()
    let outDir = getTempDir() / "datpkgr_versions_skipout" / $getCurrentProcessId()
    createDir(cache)
    defer: removeDir(cache); removeDir(outDir)
    writeFile(cache / "keep.nim", "keep")
    writeFile(cache / "skipme.nim", "skip")
    let m = Manifest(path: "", extra: %*{"skipFiles": ["skipme.nim"]})
    installCleanCopy(cache, outDir, m)
    check fileExists(outDir / "keep.nim")
    check not fileExists(outDir / "skipme.nim")

suite "versions — headVersion fallback":
  test "reads version from manifest when no tags":
    let cfg = tempCfg()
    defer: cleanupCfg(cfg)
    cfg.manifestFileName = proc(pkg: string): string = "manifest.json"
    cfg.manifestFinder = proc(dir: string): string =
      let cand = dir / "manifest.json"
      if fileExists(cand): cand else: ""
    cfg.manifestParser = proc(content: string, path: string): Manifest =
      var m = Manifest(path: path, extra: newJObject())
      let j = parseJson(content)
      m.name = j["name"].getStr
      m.version = j["version"].getStr
      m
    cfg.initDatpkgr()
    let cache = cfg.pkgsCachePath() / "mypkg"
    createDir(cache)
    writeFile(cache / "manifest.json", """{"name":"mypkg","version":"1.2.3"}""")
    let v = cfg.headVersion("mypkg")
    check $v == "1.2.3"

suite "versions — getDeps caching":
  test "caches and serves from deps table":
    let cfg = tempCfg()
    defer: cleanupCfg(cfg)
    cfg.initDatpkgr()
    # manually seed deps cache with version 6 format
    let depsJson = %*{"v": 6, "hard": [%*{"name": "depA", "url": "", "branch": "", "constraint": "*", "isToolchain": false}], "features": {}, "dev": []}
    cfg.withDatpkgrDB do:
      discard cfg.stores.versionsDB.insertRow("deps", row({
        "name": newTextValue("mypkg"),
        "version": newTextValue("1.0.0"),
        "deps": newJSONValue(depsJson),
        "cached_at": newTextValue("2026-01-01T00:00:00")
      }))
    let deps1 = cfg.getDeps("mypkg", "1.0.0")
    check deps1.len == 1
    check deps1[0].name == "depA"
    let deps2 = cfg.getDeps("mypkg", "1.0.0")
    check deps2.len == 1
    check deps2[0].name == "depA"
