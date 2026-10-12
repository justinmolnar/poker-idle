#!/usr/bin/env python3
"""
publish.py — push a finished build: the win64 folder to Steam (steamcmd)
and the web and win64 zips to itch (butler). Reads build-tools/build.toml
for the ids and names; never sets a Steam branch live (that stays a click
in Steamworks).

    python build-tools/publish.py --version 0.1.0 [--demo] --steam
    python build-tools/publish.py --version 0.1.0 [--demo] --itch
    python build-tools/publish.py --version 0.1.0 [--demo] --tag
    --dry-run prints what would run.

Steam: writes build/steam/app_build.vdf + depot_build.vdf for the content
root build/<version>-demo/win64/ and runs
    steamcmd +login <steam.user> +run_app_build <vdf> +quit
(the password prompt is steamcmd's own; Steam Guard too). Then set the
build live on the branch in Steamworks → App → Builds.

itch: butler push build/<version>-demo/web <itch.target>:web-demo and the
win64 folder to :win64-demo (a dev build uses :web / :win64).
"""

import argparse
import os
import shutil
import subprocess
import sys
import tomllib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOLS = os.path.join(ROOT, "build-tools")
BUILD = os.path.join(ROOT, "build")
SLUG = "IHardlyKnower"


def log(msg):
    print(f"[publish] {msg}")


def die(msg):
    sys.exit(f"[publish] {msg}")


def run(cmd, dry):
    print("    " + " ".join(str(c) for c in cmd))
    if dry:
        return 0
    return subprocess.run(cmd).returncode


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--version", required=True)
    ap.add_argument("--demo", action="store_true")
    ap.add_argument("--steam", action="store_true")
    ap.add_argument("--itch", action="store_true")
    ap.add_argument("--tag", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    with open(os.path.join(TOOLS, "build.toml"), "rb") as f:
        cfg = tomllib.load(f)
    out_dir = os.path.join(BUILD, args.version + ("-demo" if args.demo else ""))
    win64_dir = os.path.join(out_dir, "win64")
    web_dir = os.path.join(out_dir, "web")
    if not os.path.isdir(out_dir):
        die(f"no build at {out_dir}; run build.py first")

    if args.steam:
        steam = cfg.get("steam", {})
        app_id = steam.get("demo_app_id" if args.demo else "app_id")
        depot_id = steam.get("demo_depot_id" if args.demo else "depot_id")
        user = steam.get("user")
        if not (app_id and depot_id and user):
            die("build.toml needs [steam] user, app_id/depot_id (demo_app_id/demo_depot_id for --demo)")
        if not os.path.isdir(win64_dir):
            die(f"no win64 build at {win64_dir}")
        steam_dir = os.path.join(BUILD, "steam")
        os.makedirs(os.path.join(steam_dir, "output"), exist_ok=True)
        depot_vdf = os.path.join(steam_dir, "depot_build.vdf")
        app_vdf = os.path.join(steam_dir, "app_build.vdf")
        with open(depot_vdf, "w", encoding="utf-8") as f:
            f.write('"DepotBuild"\n{\n'
                    f'  "DepotID" "{depot_id}"\n'
                    f'  "ContentRoot" "{os.path.abspath(win64_dir)}"\n'
                    '  "FileMapping" { "LocalPath" "*" "DepotPath" "." "recursive" "1" }\n'
                    '}\n')
        with open(app_vdf, "w", encoding="utf-8") as f:
            f.write('"AppBuild"\n{\n'
                    f'  "AppID" "{app_id}"\n'
                    f'  "Desc" "{SLUG} {args.version}{" demo" if args.demo else ""}"\n'
                    f'  "ContentRoot" "{os.path.abspath(win64_dir)}"\n'
                    f'  "BuildOutput" "{os.path.abspath(os.path.join(steam_dir, "output"))}"\n'
                    f'  "Depots" {{ "{depot_id}" "{os.path.abspath(depot_vdf)}" }}\n'
                    '}\n')
        steamcmd = steam.get("steamcmd") or shutil.which("steamcmd") or shutil.which("steamcmd.exe")
        if not steamcmd:
            die("steamcmd not found: set [steam] steamcmd in build.toml or put it on PATH")
        rc = run([steamcmd, "+login", user, "+run_app_build", os.path.abspath(app_vdf), "+quit"], args.dry_run)
        if rc != 0:
            die("steamcmd failed")
        log("uploaded; set the build live on its branch in Steamworks (App → Builds)")

    if args.itch:
        itch = cfg.get("itch", {})
        target = itch.get("target")
        if not target:
            die("build.toml needs [itch] target (user/game)")
        butler = itch.get("butler") or shutil.which("butler") or shutil.which("butler.exe")
        if not butler:
            die("butler not found: set [itch] butler in build.toml or put it on PATH")
        suffix = "-demo" if args.demo else ""
        if os.path.isdir(web_dir):
            rc = run([butler, "push", web_dir, f"{target}:web{suffix}", "--userversion", args.version], args.dry_run)
            if rc != 0:
                die("butler push (web) failed")
        if os.path.isdir(win64_dir):
            rc = run([butler, "push", win64_dir, f"{target}:win64{suffix}", "--userversion", args.version], args.dry_run)
            if rc != 0:
                die("butler push (win64) failed")

    if args.tag:
        tag = ("demo-v" if args.demo else "v") + args.version
        rc = run(["git", "tag", "-a", tag, "-m", f"{SLUG} {args.version}" + (" demo" if args.demo else "")], args.dry_run)
        if rc != 0:
            die("git tag failed")
        log(f"tagged {tag}")


if __name__ == "__main__":
    main()
