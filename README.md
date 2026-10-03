# fedora-air (Atomic)

Fedora Atomic (rpm-ostree) setup for a 2015 13" MacBook Air (`MacBookAir7,2`).

This is the Atomic version of [brianjcohen/fedora-air](https://github.com/brianjcohen/fedora-air),
which covers the same machine on Fedora Workstation. That repo is where the hardware research
comes from: the wifi driver choice, the camera firmware, the suspend quirks. This repo just
redoes it for Atomic, where `rpm-ostree` replaces `dnf`, akmods replace DKMS, and `/usr` is
read-only so the extra files go in `/etc`.

If you're on Workstation, use the original repo.

## Setup

```sh
git clone https://github.com/jpagh/fedora-air-atomic
cd fedora-air-atomic
./atomic-setup.sh
```

Run it as your normal user; it calls `sudo` when it needs to. It asks a few optional questions,
layers the wifi and camera drivers, then tells you to reboot. Run it again after the reboot to
finish. It's safe to re-run: it checks what's already done and skips it.

## What it sets up

Wifi and camera are required. Neither works on Atomic without them.

| Piece | Script |
|---|---|
| Wifi: Broadcom BCM4360, needs the proprietary `wl` driver | `atomic-wifi.sh` |
| Camera: FaceTime HD, out-of-tree driver plus Apple firmware | `atomic-camera.sh` |

Everything else is optional.

| Piece | Script |
|---|---|
| Keyboard-backlight keys (F5/F6) | `keyboard-backlight.sh` |
| Trackpad: tap-to-click and corner right-click | `trackpad.sh` |
| Swap Fn and left Ctrl | `swap-fn-ctrl.sh` |
| Swap Caps Lock and `` ` ``/`~` | `swap-caps-tilde.sh` |
| Lock screen: swaylock or gtklock | `lock-screen-setup.sh` |
| Lock-screen numeric PIN | `lock-pin.sh` |

Each is a standalone script. `atomic-setup.sh` runs them in order and handles the reboot.

## Files

```
atomic-setup.sh          run this first
atomic-playbook.md       what each piece does, and how to undo it
atomic-wifi.sh           wifi
atomic-camera.sh         camera
atomic-upgrade.sh        check the modules rebuilt after a kernel upgrade
swap-fn-ctrl.sh          Fn <-> left Ctrl
swap-caps-tilde.sh       Caps Lock <-> `/~`
keyboard-backlight.sh    F5/F6 backlight (Sway)
trackpad.sh              tap-to-click / corner right-click (Sway)
lock-screen-setup.sh     swaylock or gtklock (Sway)
lock-pin.sh              lock-screen PIN (PAM)
atomic-camera/           the three camera RPMs
etc/, usr/               files the wifi and camera scripts install
LICENSE                  MIT
```

## Kernel upgrades

`wl` and `facetimehd` are out-of-tree, so akmods rebuilds them for each new kernel. A kernel can
boot fine and still have no wifi or camera, so verify:

```sh
sudo ./atomic-upgrade.sh
```

It stages the upgrade, checks both modules were built, and tells you to reboot.

## Credits

Hardware research: [brianjcohen/fedora-air](https://github.com/brianjcohen/fedora-air).
Camera packaging: [mulderje/facetimehd-kmod](https://copr.fedorainfracloud.org/coprs/mulderje/facetimehd-kmod/),
with a build fix for kernel 7.2 and later.

## License

MIT. See [LICENSE](LICENSE).
