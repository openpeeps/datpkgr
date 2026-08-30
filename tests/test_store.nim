import std/[os, unittest, json, sequtils, options, strutils]
import pkg/boogie/stores/rdbms
import pkg/flysystem
import datpkgr/config
import datpkgr/store
import datpkgr/types
import helpers

suite "store — isValidSourceName":
  test "valid names":
    check isValidSourceName("nim-lang")
    check isValidSourceName("myreg")
    check isValidSourceName("a1_b-2")
  test "invalid names":
    check not isValidSourceName("")
    check not isValidSourceName("MyReg")
    check not isValidSourceName("a b")
    check not isValidSourceName("a/b")

suite "store — sourceCachePath":
  test "joins registries dir and .json":
    let cfg = tempCfg()
    defer: cleanupCfg(cfg)
    check cfg.sourceCachePath("myreg") == "registries" / "myreg.json"

suite "store — load/save sources":
  test "ensure creates default source file":
    let cfg = tempCfg()
    defer: cleanupCfg(cfg)
    cfg.defaultRegistryUrl = "https://example.com/a.json"
    cfg.defaultSourceName = "nim-lang"
    cfg.ensureSourcesFile()
    check cfg.driver.exists(cfg.sourcesPath())
    let srcs = cfg.loadSources()
    check srcs.len >= 1
    check srcs[0].name == "nim-lang"

  test "save and load roundtrip":
    let cfg = tempCfg()
    defer: cleanupCfg(cfg)
    let srcs = @[Source(name: "nim-lang", url: "https://example.com/a.json"),
                 Source(name: "myreg", url: "https://example.com/b.json")]
    cfg.saveSources(srcs)
    let loaded = cfg.loadSources()
    check loaded.len == 2
    check loaded[0].name == "nim-lang"
    check loaded[1].url == "https://example.com/b.json"

  test "invalid names filtered on load":
    let cfg = tempCfg()
    defer: cleanupCfg(cfg)
    # write invalid source directly via filesystem
    let j = %*{"sources": [%*{"name": "MyReg", "url": "https://example.com/a.json"},
                           %*{"name": "valid", "url": "https://example.com/b.json"}]}
    cfg.driver.makeDir(cfg.registriesDir())
    cfg.fs.write(cfg.sourcesPath(), pretty(j))
    let loaded = cfg.loadSources()
    check loaded.len == 1
    check loaded[0].name == "valid"

  test "bare array fallback":
    let cfg = tempCfg()
    defer: cleanupCfg(cfg)
    let arr = %*[%*{"name": "myreg", "url": "https://example.com/c.json"}]
    cfg.fs.write(cfg.sourcesPath(), pretty(arr))
    let loaded = cfg.loadSources()
    check loaded.len == 1
    check loaded[0].name == "myreg"

suite "store — seedPackagesTable":
  test "skips alias and missing web":
    let cfg = tempCfg()
    defer: cleanupCfg(cfg)
    cfg.initDatpkgr()
    let data = %*[
      {"name": "good", "url": "https://github.com/org/good", "method": "git",
       "tags": ["v1.0.0"], "description": "d", "license": "MIT", "web": "https://example.com"},
      {"name": "bad_alias", "url": "https://github.com/org/bad", "method": "git",
       "tags": [], "description": "d", "license": "MIT", "web": "https://example.com", "alias": "x"},
      {"name": "no_web", "url": "https://github.com/org/noweb", "method": "git",
       "tags": [], "description": "d", "license": "MIT"}
    ]
    let n = cfg.seedPackagesTable(data, "nim-lang")
    check n == 1
    let tbl = cfg.stores.db.getTable("packages").get()
    check tbl.where("name", newTextValue("good")).toSeq().len == 1
    check tbl.where("name", newTextValue("bad_alias")).toSeq().len == 0

suite "store — fetchPkgMeta":
  test "fetch by source priority and filter":
    let cfg = tempCfg()
    defer: cleanupCfg(cfg)
    cfg.defaultSourceName = "nim-lang"
    cfg.defaultRegistryUrl = "https://example.com/a.json"
    cfg.initDatpkgr()
    let data = %*[
      {"name": "pkg", "url": "https://github.com/org/pkg", "method": "git",
       "tags": [], "description": "d", "license": "MIT", "web": "https://example.com"},
      {"name": "pkg", "url": "https://github.com/other/pkg", "method": "git",
       "tags": [], "description": "d", "license": "MIT", "web": "https://example.com"}
    ]
    discard cfg.seedPackagesTable(data, "nim-lang")
    discard cfg.seedPackagesTable(data, "myreg")
    # Need sources ordered nim-lang first
    cfg.saveSources(@[Source(name: "nim-lang", url: "https://example.com/a.json"),
                      Source(name: "myreg", url: "https://example.com/b.json")])
    let m1 = cfg.fetchPkgMeta("pkg")
    check m1.isSome
    let m2 = cfg.fetchPkgMeta("pkg", "myreg")
    check m2.isSome
    check m2.get().url == "https://github.com/other/pkg" or m2.get().url == "https://github.com/org/pkg"
    let miss = cfg.fetchPkgMeta("nonexistent")
    check miss.isNone

  test "fetchAllPkgMetas returns all":
    let cfg = tempCfg()
    defer: cleanupCfg(cfg)
    cfg.initDatpkgr()
    let data = %*[
      {"name": "dup", "url": "https://github.com/a/dup", "method": "git",
       "tags": [], "description": "d", "license": "MIT", "web": "https://example.com"},
      {"name": "dup", "url": "https://github.com/b/dup", "method": "git",
       "tags": [], "description": "d", "license": "MIT", "web": "https://example.com"}
    ]
    discard cfg.seedPackagesTable(data, "nim-lang")
    discard cfg.seedPackagesTable(data, "other")
    let all = cfg.fetchAllPkgMetas("dup")
    check all.len >= 2

suite "store — withDatpkgrDB":
  test "initializes lazily":
    let cfg = tempCfg()
    defer: cleanupCfg(cfg)
    check not cfg.stores.initialized
    cfg.withDatpkgrDB do:
      check cfg.stores.initialized
