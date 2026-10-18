# Software on the agent server

[Back to the README](../README.md).


What the agents actually use, not every package installed. Ubuntu Server
24.04; versions given only where a mismatch breaks something.

| Software | Installed from | Used by | For |
|---|---|---|---|
| Claude Code | native installer | every agent | the agents themselves, and Remote Control from a phone or laptop |
| git, tmux | apt | every agent | the repo and its worktrees; sessions that survive a dropped connection |
| Tailscale | apt, Tailscale's repository | `box-keeper` | the private network every machine sits on |
| Python 3.12 with `python3-venv` | apt, then one venv per project | `builder`, `web-apps`, `rf-sensing` | app engines and their self-tests (Ubuntu 24.04 blocks system-wide pip) |
| Node 18, Playwright 1.55.1, headless Chromium | apt (`nodejs`, `npm`), then npm | `web-apps`, `promo`, `builder` | real-browser checks, and rendering pages to PDF and PNG, with Playwright pinned for Node 18 |
| OpenSCAD | OpenSCAD's own nightly apt repository (openscad.org downloads), package and binary `openscad-nightly`; Ubuntu's own `openscad` is the 2021.01 release | `stl-creator` | parametric parts to STL |
| CadQuery | a Python venv | `stl-creator` | Python-scripted parts to STL |
| `xvfb` | apt | `stl-creator` | PNG previews with no display attached: without `xvfb-run` the render fails on EGL |
| poppler-utils | apt | `manager`, `builder` | checking a PDF before it leaves: page count, fonts, extracted text, links, PNG previews |
| ArduPilot source trees | one git clone, a worktree per firmware version the fleet runs (4.6.3, 4.7.1, 4.8.0-dev), built with `build-essential`, `g++`, `ccache` | `ardupilot-programmer`, `promo` | SITL flights, parameter diffs between versions, and checking a script against the exact firmware it will run on |
| MAVProxy, pymavlink | one venv shared by the ArduPilot trees | `ardupilot-programmer`, `promo` | talking to SITL and to real flight controllers |
| `lua5.3`, `luacheck`, `lua-language-server` | apt, then an install script | `ardupilot-programmer` | linting onboard scripts, and catching calls to bindings a given firmware does not have |
| ExpressLRS and mLRS sources, PlatformIO | git, and a venv of its own | `ardupilot-programmer` | radio firmware builds matched to the radio's own version |
| Betaflight SITL, `python3-serial` | Betaflight source at its release tag, `make TARGET=SITL` with `build-essential`; apt | `ardupilot-programmer` | a scripted Betaflight CLI: backups, restores pinned to board and firmware, every setting read back; tested against SITL before a real board |
| Betaflight `blackbox_decode` | built from source (`betaflight/blackbox-tools`, which ships no Linux release) | `ardupilot-programmer` | Blackbox flight logs to CSV |
| HackRF host tools | apt, `hackrf` | `rf-sensing` | bench work with the receiver |
| `adb` | apt | `tak-sme` | removing bloat from the Android devices that run ATAK |
| ffmpeg | apt | `promo` | video cuts and the site's WebP image set |
| QEMU, OVMF, `xorriso` | apt | `box-keeper` | building and test-booting a sensor node's unattended install image |

**What stays off it.** The rule of thumb here: a headless agent box is
useful for software whose interface is a text file, and useless for
software whose interface is a mouse. So Fusion 360 and KiCad layout are
not installed, slicing happens on a laptop, and ATAK plugin development
needs more machine than this. The Betaflight App (formerly Configurator) is
a web app that needs the flight controller on the machine running the
browser, so it runs on the laptop; Betaflight's CLI and Blackbox logs are
text, and are on the box.

- Do not purge `lxd-installer` to get rid of LXD: on Ubuntu Server it takes
  the `ubuntu-server` metapackage with it.
