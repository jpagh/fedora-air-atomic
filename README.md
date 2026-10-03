# fedora-air (Atomic)

Fedora **Atomic** (rpm-ostree) setup for a 2015 MacBook Air — `MacBookAir7,2`, the 13" early
2015 model.

This is the Atomic sibling of **[brianjcohen/fedora-air](https://github.com/brianjcohen/fedora-air)**,
which covers the same machine on Fedora **Workstation** (dnf, DKMS, KDE Plasma). That repository
is where the hardware knowledge comes from — which wifi driver to use, how to get the camera
firmware out of Apple's driver, and the suspend quirks. This repository keeps only what Atomic
needs and re-implements it the Atomic way: packages layered with `rpm-ostree` instead of `dnf`,
kernel modules built as **akmods** instead of DKMS, files under `/etc` instead of read-only
`/usr`, and Sway instead of KDE.

> If you are on Fedora Workstation, use the original repository, not this one.

## Quick start

```sh
git clone <this-repo> && cd <this-repo>
./atomic-setup.sh
```

`atomic-setup.sh` runs as your normal user (it calls `sudo` where needed), asks a few optional
questions, layers the wifi and camera drivers, and tells you when to reboot. **Re-run it after
the reboot** to finish. It is safe to stop and re-run at any time — it inspects the machine and
does whatever is still missing.

## What it sets up

**Required** — this hardware does not work on Atomic without these:

| Piece | Why | Script |
|---|---|---|
| **Wifi** | The Broadcom BCM4360 needs the proprietary `wl` driver, layered as an akmod, plus three workarounds for its suspend/WPA3/PMF defects. | `atomic-wifi.sh` |
| **Camera** | The FaceTime HD camera needs an out-of-tree driver plus firmware extracted from Apple's macOS driver, both repackaged as an akmod + RPM. | `atomic-camera.sh` |

**Optional** — asked for, never assumed. Say no to any of them and nothing changes:

| Piece | Script |
|---|---|
| Keyboard-backlight keys (F5/F6) | `keyboard-backlight.sh` |
| Trackpad: tap-to-click + corner right-click | `trackpad.sh` |
| Swap Fn and left Ctrl | `swap-fn-ctrl.sh` |
| Swap Caps Lock and `` ` ``/`~` (personal taste) | `swap-caps-tilde.sh` |
| Lock screen: blurred ring (swaylock) or login-style (gtklock) | `lock-screen-setup.sh` |
| Numeric PIN for the lock screen | `lock-pin.sh` |

Each feature is a standalone script you can run on its own; `atomic-setup.sh` is just the
conductor that runs them in order and handles the reboot. Every script is idempotent.

## Layout

```
atomic-setup.sh          guided conductor -- run this first
atomic-playbook.md       the why of each piece, how it works, how to undo it
atomic-wifi.sh           Broadcom wl wifi + its three workarounds
atomic-camera.sh         FaceTime HD camera (local akmod + firmware)
atomic-upgrade.sh        after a kernel upgrade, verify wl + facetimehd were rebuilt
swap-fn-ctrl.sh          Fn <-> left Ctrl
swap-caps-tilde.sh       Caps Lock <-> `/~ (personal taste)
keyboard-backlight.sh    F5/F6 keyboard backlight (Sway)
trackpad.sh              tap-to-click / corner right-click (Sway)
lock-screen-setup.sh     swaylock (ring) or gtklock (login-style) (Sway)
lock-pin.sh              numeric PIN for the lock screen (PAM)
atomic-camera/           the three camera RPMs (akmod + firmware + meta)
etc/, usr/               local files the wifi and camera scripts install
LICENSE                  MIT (inherited from the original repository)
```

## After a kernel upgrade

`wl` and `facetimehd` are out-of-tree and must be rebuilt for each new kernel. `akmods` does
this automatically, but a kernel that boots fine can still have no wifi or no camera. Run:

```sh
sudo ./atomic-upgrade.sh
```

It stages the upgrade, checks that both modules were built for the new kernel, and tells you to
reboot only once they are.

## Credits

All of the hardware research lives in
**[brianjcohen/fedora-air](https://github.com/brianjcohen/fedora-air)** — its runbook is the
reference for why any of this is necessary. This repository is only the Atomic port. The camera
packaging is derived from the [mulderje/facetimehd-kmod](https://copr.fedorainfracloud.org/coprs/mulderje/facetimehd-kmod/)
COPR, with a one-line build fix for kernel ≥ 7.2.

## License

MIT — see [LICENSE](LICENSE).
