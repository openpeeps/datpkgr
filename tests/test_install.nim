import std/[os, unittest, tables, sequtils, json]
import pkg/semver
import pkg/boogie/stores/rdbms
import datpkgr/config
import datpkgr/install
import datpkgr/store
import datpkgr/types
import helpers

suite "install — record and query":
  test "recordInstall and installedRecords":
    let cfg = tempCfg()
    defer: cleanupCfg(cfg)
    cfg.initDatpkgr()
    cfg.recordInstall("pkgA", "1.0.0", @[("dep", "1.0.0")], root=true, features= @["ssl"], installPath=cfg.pkgsPath()/"pkgA"/"1.0.0")
    let recs = cfg.installedRecords("pkgA")
    check recs.len == 1
    check recs[0].version == "1.0.0"
    check recs[0].root == true
    check cfg.installedPath("pkgA", "1.0.0") == cfg.pkgsPath()/"pkgA"/"1.0.0"

  test "resolveInstalledPath prefers exact ref else newest semver":
    let cfg = tempCfg()
    defer: cleanupCfg(cfg)
    cfg.initDatpkgr()
    cfg.recordInstall("pkg", "1.0.0", @[], root=true, installPath=cfg.pkgsPath()/"pkg"/"1.0.0")
    cfg.recordInstall("pkg", "2.0.0", @[], root=true, installPath=cfg.pkgsPath()/"pkg"/"2.0.0")
    cfg.recordInstall("pkg", "head", @[], root=true, installPath=cfg.pkgsPath()/"pkg"/"head")
    check cfg.resolveInstalledPath("pkg", "head") == cfg.pkgsPath()/"pkg"/"head"
    check cfg.resolveInstalledPath("pkg", "") == cfg.pkgsPath()/"pkg"/"2.0.0"

  test "isDevInstall detects outside pkgs":
    let cfg = tempCfg()
    defer: cleanupCfg(cfg)
    cfg.initDatpkgr()
    let devRec = InstalledRecord(version: "1.0.0", path: "/tmp/somewhere/pkg", root: true)
    check cfg.isDevInstall(devRec)
    let regRec = InstalledRecord(version: "1.0.0", path: cfg.pkgsPath()/"pkg"/"1.0.0", root: true)
    check not cfg.isDevInstall(regRec)

  test "installedRoots returns roots only":
    let cfg = tempCfg()
    defer: cleanupCfg(cfg)
    cfg.initDatpkgr()
    cfg.recordInstall("rootA", "1.0.0", @[], root=true, installPath=cfg.pkgsPath()/"rootA"/"1.0.0")
    cfg.recordInstall("depB", "1.0.0", @[], root=false, installPath=cfg.pkgsPath()/"depB"/"1.0.0")
    let roots = cfg.installedRoots()
    check "rootA" in roots
    check "depB" notin roots

  test "collectInstalledDepNames BFS":
    let cfg = tempCfg()
    defer: cleanupCfg(cfg)
    cfg.initDatpkgr()
    cfg.recordInstall("A", "1.0.0", @[("B", "1.0.0")], root=true, installPath=cfg.pkgsPath()/"A"/"1.0.0")
    cfg.recordInstall("B", "1.0.0", @[("C", "1.0.0")], root=false, installPath=cfg.pkgsPath()/"B"/"1.0.0")
    cfg.recordInstall("C", "1.0.0", @[], root=false, installPath=cfg.pkgsPath()/"C"/"1.0.0")
    let names = cfg.collectInstalledDepNames(@["A"])
    check "B" in names
    check "C" in names
    check "A" in names

  test "installedFeatures union":
    let cfg = tempCfg()
    defer: cleanupCfg(cfg)
    cfg.initDatpkgr()
    cfg.recordInstall("pkg", "1.0.0", @[], root=true, features= @["ssl"], installPath=cfg.pkgsPath()/"pkg"/"1.0.0")
    cfg.recordInstall("pkg", "2.0.0", @[], root=true, features= @["jwt"], installPath=cfg.pkgsPath()/"pkg"/"2.0.0")
    let feats = cfg.installedFeatures()
    check "ssl" in feats["pkg"]
    check "jwt" in feats["pkg"]

  test "pruneOrphans removes unreachable":
    let cfg = tempCfg()
    defer: cleanupCfg(cfg)
    cfg.initDatpkgr()
    cfg.recordInstall("root", "1.0.0", @[("dep", "1.0.0")], root=true, installPath=cfg.pkgsPath()/"root"/"1.0.0")
    cfg.recordInstall("dep", "1.0.0", @[], root=false, installPath=cfg.pkgsPath()/"dep"/"1.0.0")
    cfg.recordInstall("orphan", "1.0.0", @[], root=false, installPath=cfg.pkgsPath()/"orphan"/"1.0.0")
    createDir(cfg.pkgsPath() / "orphan" / "1.0.0")
    check dirExists(cfg.pkgsPath() / "orphan" / "1.0.0")
    cfg.pruneOrphans(verbose=false)
    check cfg.installedRecords("orphan").len == 0
    check not dirExists(cfg.pkgsPath() / "orphan" / "1.0.0")
    check cfg.installedRecords("dep").len == 1

  test "unrecordInstall removes entry":
    let cfg = tempCfg()
    defer: cleanupCfg(cfg)
    cfg.initDatpkgr()
    cfg.recordInstall("pkg", "1.0.0", @[], root=true, installPath=cfg.pkgsPath()/"pkg"/"1.0.0")
    cfg.recordInstall("pkg", "2.0.0", @[], root=true, installPath=cfg.pkgsPath()/"pkg"/"2.0.0")
    cfg.unrecordInstall("pkg", "1.0.0")
    check cfg.installedRecords("pkg").len == 1
    check cfg.installedRecords("pkg")[0].version == "2.0.0"
    cfg.unrecordInstall("pkg", "")
    check cfg.installedRecords("pkg").len == 0

  test "allInstalledPaths returns one per package newest":
    let cfg = tempCfg()
    defer: cleanupCfg(cfg)
    cfg.initDatpkgr()
    cfg.recordInstall("pkg", "1.0.0", @[], root=true, installPath=cfg.pkgsPath()/"pkg"/"1.0.0")
    cfg.recordInstall("pkg", "2.0.0", @[], root=true, installPath=cfg.pkgsPath()/"pkg"/"2.0.0")
    cfg.recordInstall("other", "1.0.0", @[], root=true, installPath=cfg.pkgsPath()/"other"/"1.0.0")
    let paths = cfg.allInstalledPaths()
    check paths.len == 2
    check cfg.pkgsPath()/"pkg"/"2.0.0" in paths or cfg.pkgsPath()/"pkg"/"2.0.0"/"src" in paths

  test "allInstalledPaths includes HEAD-only packages":
    # Regression: tagless packages (sole `HEAD` record, e.g. sorta) vanished
    # from every `--path` list, failing dependents with `cannot open file`
    # even though installed.
    let cfg = tempCfg()
    defer: cleanupCfg(cfg)
    cfg.initDatpkgr()
    cfg.recordInstall("sorta", "HEAD", @[], root=false, installPath=cfg.pkgsPath()/"sorta"/"HEAD")
    let paths = cfg.allInstalledPaths()
    check paths.len == 1
    check cfg.pkgsPath()/"sorta"/"HEAD" in paths

  test "allInstalledPaths prefers HEAD over semver rows":
    let cfg = tempCfg()
    defer: cleanupCfg(cfg)
    cfg.initDatpkgr()
    cfg.recordInstall("pkg", "0.2.0", @[], root=false, installPath=cfg.pkgsPath()/"pkg"/"0.2.0")
    cfg.recordInstall("pkg", "HEAD", @[], root=false, installPath=cfg.pkgsPath()/"pkg"/"HEAD")
    let paths = cfg.allInstalledPaths()
    check paths.len == 1
    check cfg.pkgsPath()/"pkg"/"HEAD" in paths

  test "allInstalledPaths keeps branch rows, drops empty versions":
    let cfg = tempCfg()
    defer: cleanupCfg(cfg)
    cfg.initDatpkgr()
    cfg.recordInstall("branched", "main", @[], root=true, installPath=cfg.pkgsPath()/"branched"/"main")
    cfg.recordInstall("legacy", "", @[], root=true, installPath=cfg.pkgsPath()/"legacy"/"x")
    let paths = cfg.allInstalledPaths()
    check cfg.pkgsPath()/"branched"/"main" in paths
    check paths.len == 1

  test "resolveDepPathLike prefers HEAD dirs":
    let cfg = tempCfg()
    defer: cleanupCfg(cfg)
    cfg.initDatpkgr()
    createDir(cfg.pkgsPath() / "pkg" / "1.0.0")
    createDir(cfg.pkgsPath() / "pkg" / "HEAD")
    check cfg.resolveDepPathLike("pkg") == cfg.pkgsPath() / "pkg" / "HEAD"
