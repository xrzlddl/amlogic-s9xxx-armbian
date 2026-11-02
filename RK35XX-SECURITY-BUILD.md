# RK35xx security build (experimental, no publication)

The source repositories, scripts and workflow changes are confined to `xrzlddl` forks.
No release/tag is created. Nothing connects to or changes a physical device.

## Requested targets

* R66S: `r66s`, RK3568, `rk3568-fastrhino-r66s.dtb`, R8125 vendor driver.
* OEC BOX WXY4Module: `wxy-oect`, RK3566, `rk3566-wxy-oec-turbo-4g.dtb`.
  `wxy-oect-mod` is the different replaced-eMMC model and is not selected.
* The current systems use Debian Bookworm, so full image packaging uses Bookworm.

The revised priority is integration of the complete stable `v6.1.191` delta into
ophub's 6.1 BSP. A reproducible three-way integration currently fails with 84
conflicted paths. The script stops before compiling that candidate. It never
uses `-Xours`, discards board drivers, or changes only the version number.
The existing minimal-CVE branches remain separate from that integration attempt.
The 6.12 build uses the minimal audited CVE fix on the existing 6.12 BSP.

## Reproduce on a disposable native ARM64 Linux builder

Use Ubuntu 26.04 ARM64 with Docker, Git, Python 3, curl, xz, and
`binutils-aarch64-linux-gnu`. Use the exact builder commit pinned by
`xrzlddl/kernel`'s `rk35xx-security-build.yml`; do not use a moving script.

```bash
export RK35XX_CONFIG_DIR=/absolute/path/to/kernel/kernel-config/release/rk35xx
bash rk35xx-security-build.sh kernel 6.1.191 \
  xrzlddl/linux-6.1.y-rockchip \
  20a9ee43e69cc36603a221efc70bcc2b875bda84 \
  20a9ee43e69cc36603a221efc70bcc2b875bda84

# Independent 6.12 BSP build:
bash rk35xx-security-build.sh kernel 6.12.69 \
  xrzlddl/linux-6.12.y-rockchip \
  7c974e1a46f3628af77438c6082fbda27fa10990 \
  4ddb84e17d155e653c7a0503cb120582a456da82

# Only after package validation passes, in that same build directory:
bash rk35xx-security-build.sh images 6.12.69 \
  xrzlddl/linux-6.12.y-rockchip \
  7c974e1a46f3628af77438c6082fbda27fa10990 \
  4ddb84e17d155e653c7a0503cb120582a456da82
```

These commands operate on the disposable builder and container. They must not
be run on the user's production R66S/OECT devices. The original `recompile`
wrapper updates its kernel script from a moving upstream URL; this wrapper
instead calls the pinned fork's existing compiler script directly.

## Evidence and limits

`security-evidence/` records source SHA, source diff, source files, configuration,
container digest, fixed GCC 14.3 archive checksum, compile log, and checksums.
Successful package validation requires the two exact `kfree_rcu(..., rcu)` calls,
both compiled destructor objects calling `kvfree_call_rcu`, the packaged kernel
Image matching the compiled Image, both board DTBs, and an R8125 module.
Image verification mounts only newly generated local images read-only and checks
the kernel Image, module directory and board boot configuration.

The image root filesystem is a checksum-pinned ophub Bookworm base image; this
is repackaging using ophub's existing `rebuild`, not a fresh Debian rootfs build.
U-Boot and firmware downloads still follow ophub's existing dependency behavior.
For bit-for-bit rebuilds, additionally retain their resolved dependency snapshots
and all package mirrors. A successful build is not a physical boot/network/SATA
test, and this fix is not a claim that every other kernel CVE is fixed.
