#!/usr/bin/env bash
# Reproduce the fork-only RK35xx security build. No releases, tags, or device access.
set -euo pipefail
mode=${1:?kernel or images}
version=${2:?exact version}
source_repo=${3:?source owner/repository}
source_sha=${4:?immutable source SHA}
source_base=${5:?ophub BSP baseline SHA}
[[ $source_repo == xrzlddl/linux-*.y-rockchip && $source_sha =~ ^[0-9a-f]{40}$ && $source_base =~ ^[0-9a-f]{40}$ ]]
root=$PWD
evidence=$root/security-evidence
mkdir -p "$evidence" compile-kernel/kernel compile-kernel/tools/config
line=${version%.*}
repo_name=${source_repo#*/}
src=$root/compile-kernel/kernel/${repo_name}-main
release=${version}-rk35xx-cve98432

if [[ $mode == kernel ]]; then
  git init "$src"
  git -C "$src" remote add origin "https://github.com/$source_repo.git"
  git -C "$src" fetch --depth=1 origin "$source_sha" "$source_base"
  git -C "$src" checkout --detach "$source_sha"
  git -C "$src" diff "$source_base" "$source_sha" > "$evidence/source.diff"
  git -C "$src" log -1 --format=fuller > "$evidence/source-commit.txt"
  if [[ $version == 6.1.191 ]]; then
    # BSP history is not assumed to be vanilla stable history. Explicitly use
    # the matching stable version as the three-way delta base. Never use -Xours.
    git -C "$src" remote add stable https://github.com/gregkh/linux.git
    git -C "$src" fetch --depth=1 stable tag v6.1.174 tag v6.1.191
    set +e
    git -C "$src" merge-tree --write-tree --merge-base=v6.1.174 "$source_sha" v6.1.191 > "$evidence/merge-6.1.191.txt"
    status=$?
    set -e
    if (( status != 0 )); then
      echo 'Stable integration has unresolved conflicts. Compilation is intentionally blocked.' | tee "$evidence/BUILD-BLOCKED.txt"
      exit 2
    fi
    tree=$(head -n1 "$evidence/merge-6.1.191.txt")
    git -C "$src" config user.name 'RK35xx security build'
    git -C "$src" config user.email '88777204+xrzlddl@users.noreply.github.com'
    merged=$(printf '%s\n' 'Merge Linux stable v6.1.191 into Rockchip BSP' | git -C "$src" commit-tree "$tree" -p "$source_sha" -p v6.1.191)
    git -C "$src" checkout --detach "$merged"
    git -C "$src" update-ref refs/heads/security/linux-6.1.191 "$merged"
    git -C "$src" bundle create "$evidence/merged-source.bundle" security/linux-6.1.191
  fi
  export SRC="$src" EVIDENCE="$evidence" EXPECTED_VERSION="$version" SOURCE_REPO="$source_repo"
  python3 - <<'PY'
import os,pathlib,hashlib,json,subprocess,re
s=pathlib.Path(os.environ['SRC']); e=pathlib.Path(os.environ['EVIDENCE'])
expected={'net/ipv4/af_inet.c':'kfree_rcu(rcu_dereference_protected(inet->inet_opt, 1), rcu);','net/ipv4/tcp_ipv4.c':'kfree_rcu(rcu_dereference_protected(inet_rsk(req)->ireq_opt, 1), rcu);'}
make=(s/'Makefile').read_text(); version='.'.join(re.search(r'^'+k+r' = (\d+)$',make,re.M)[1] for k in ['VERSION','PATCHLEVEL','SUBLEVEL'])
assert version==os.environ['EXPECTED_VERSION'],(version,os.environ['EXPECTED_VERSION'])
files={}
for p,needle in expected.items():
    b=(s/p).read_bytes();assert b.decode().count(needle)==1,p
    target=e/'source'/p;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(b)
    files[p]=hashlib.sha256(b).hexdigest()
h=(s/'include/net/inet_sock.h').read_text();assert 'struct rcu_head rcu;' in h
for p in ['net/ipv4/tcp_ipv4.c','net/ipv4/inet_connection_sock.c']:
    t=(s/p).read_text();assert 'rcu_read_lock();' in t and 'rcu_read_unlock();' in t
for p in ['arch/arm64/boot/dts/rockchip/rk3568-fastrhino-r66s.dts','arch/arm64/boot/dts/rockchip/rk3566-wxy-oec-turbo-4g.dts','drivers/net/ethernet/realtek/r8125_vendor/Makefile']:
    assert (s/p).is_file(),p
    files[p]=hashlib.sha256((s/p).read_bytes()).hexdigest()
sha=subprocess.check_output(['git','-C',str(s),'rev-parse','HEAD'],text=True).strip()
(e/'source-manifest.json').write_text(json.dumps({'source_repo':os.environ['SOURCE_REPO'],'source_commit':sha,'version':version,'upstream_fix':'e3f33b0a1d89d738e2b913dab519226eaf76e15b','source_sha256':files,'hardware_boot_tested':False},indent=2)+'\n')
PY
  cp "$RK35XX_CONFIG_DIR/config-$line" compile-kernel/tools/config/config-"$line"
  sha256sum compile-kernel/tools/config/config-"$line" > "$evidence/config-template.sha256"
  toolchain=arm-gnu-toolchain-14.3.rel1-aarch64-aarch64-none-linux-gnu
  mkdir -p .toolchain
  curl -fL --retry 3 "https://github.com/ophub/kernel/releases/download/toolchain/$toolchain.tar.xz" -o ".toolchain/$toolchain.tar.xz"
  echo "7f4ca1d3b773c41b031019d1249b2c58e6beb470eeabacfa0a0813c5e8bb7e5b  .toolchain/$toolchain.tar.xz" | sha256sum -c - | tee "$evidence/toolchain-check.txt"
  tar -xJf ".toolchain/$toolchain.tar.xz" -C .toolchain
  image=${RK35XX_DOCKER_IMAGE:-ophub/armbian-bookworm:arm64}
  docker pull "$image"
  digest=$(docker image inspect "$image" --format '{{index .RepoDigests 0}}')
  printf '%s\n' "$digest" > "$evidence/container-digest.txt"
  # Use the pinned fork script directly; recompile's update step would fetch
  # a moving upstream script and is intentionally not used here.
  docker run --rm --privileged -v "$root:/opt/kernel" -v "$root/.toolchain:/usr/local/toolchain" -w /opt/kernel --entrypoint /bin/bash "$digest" -c \
    'bash compile-kernel/tools/script/armbian_compile_kernel.sh -r "$1" -k "$2" -a false -m all -p false -d false -n -rk35xx-cve98432 -t gcc-14.3' _ "$source_repo@main" "$version" \
    2>&1 | tee "$evidence/compile.log"
  # Prove the compiled objects use deferred RCU frees, then bind the packages
  # to the Image produced by this exact checked source.
  for pair in 'af_inet inet_sock_destruct' 'tcp_ipv4 tcp_v4_reqsk_destructor'; do
    read -r object function <<< "$pair"
    aarch64-linux-gnu-objdump -dr --disassemble="$function" "$src/net/ipv4/$object.o" > "$evidence/$function.disassembly.txt"
    grep -q kvfree_call_rcu "$evidence/$function.disassembly.txt"
  done
  cp "$src/.config" "$evidence/built.config"
  cp "$src/include/config/kernel.release" "$evidence/kernel.release"
  [[ $(cat "$evidence/kernel.release") == "$release" ]]
  export KERNEL_RELEASE="$release"
  python3 - <<'PY'
import os,pathlib,hashlib,tarfile,json,subprocess,tempfile
s=pathlib.Path(os.environ['SRC']);e=pathlib.Path(os.environ['EVIDENCE']);root=e.parent
m=json.loads((e/'source-manifest.json').read_text());r=os.environ['KERNEL_RELEASE'];v=m['version'];out=root/'compile-kernel/output'
for p,digest in m['source_sha256'].items():assert hashlib.sha256((s/p).read_bytes()).hexdigest()==digest,p
image_hash=hashlib.sha256((s/'arch/arm64/boot/Image').read_bytes()).hexdigest()
with tarfile.open(out/f'{v}.tar.gz') as t, tempfile.TemporaryDirectory() as tmp:
    t.extractall(tmp,filter='data');folder=pathlib.Path(tmp)/v
    for row in (folder/'sha256sums').read_text().splitlines():
        digest,name=row.split();assert hashlib.sha256((folder/name).read_bytes()).hexdigest()==digest,name
    with tarfile.open(next(folder.glob('boot-*.tar.gz'))) as b:
        assert hashlib.sha256(b.extractfile(f'vmlinuz-{r}').read()).hexdigest()==image_hash
        assert b.getmember(f'initrd.img-{r}').size>0
        assert b.getmember(f'uInitrd-{r}').size>0
    with tarfile.open(next(folder.glob('dtb-rockchip-*.tar.gz'))) as d:
        for name in ['rk3568-fastrhino-r66s.dtb','rk3566-wxy-oec-turbo-4g.dtb']:
            assert d.getmember(name).size>0,name
    with tarfile.open(next(folder.glob('modules-*.tar.gz'))) as modules:
        assert any(n.endswith('/r8125.ko') for n in modules.getnames()),'R8125 module absent'
with tarfile.open(out/f'deb-{v}.tar.gz') as t,tempfile.TemporaryDirectory() as tmp:
    t.extractall(tmp,filter='data');debs=list(pathlib.Path(tmp).rglob('*.deb'));assert len(debs)>=4
    package=next(p for p in debs if p.name.startswith('linux-image_'))
    dest=pathlib.Path(tmp)/'image';subprocess.run(['dpkg-deb','-x',str(package),str(dest)],check=True)
    assert hashlib.sha256((dest/f'boot/vmlinuz-{r}').read_bytes()).hexdigest()==image_hash
m.update(kernel_release=r,image_sha256=image_hash,package_checks='passed',hardware_boot_tested=False)
(e/'validation.json').write_text(json.dumps(m,indent=2)+'\n')
PY
  (cd compile-kernel/output && sha256sum *.tar.gz) > "$evidence/packages.sha256"
elif [[ $mode == images ]]; then
  [[ -s "$evidence/validation.json" ]]
  sudo apt-get update
  sudo apt-get install -y $(cat compile-kernel/tools/script/ubuntu2604-build-armbian-depends)
  mkdir -p build/output/images build-armbian/kernel/rk35xx
  tar -xzf "compile-kernel/output/$version.tar.gz" -C build-armbian/kernel/rk35xx
  base=Armbian_26.11.0-trunk_bookworm_arm64_6.18.60.img.gz
  curl -fL --retry 3 "https://github.com/ophub/amlogic-s9xxx-armbian/releases/download/Armbian_bookworm_arm64_server_2026.11/$base" -o "build/output/images/$base"
  echo "3f605ba9194b5775b8a8ff2837a5f538ecc5851c662e4b4c3ff927304160dcc7  build/output/images/$base" | sha256sum -c -
  gunzip "build/output/images/$base"
  # -a false + the staged local package prevents downloading an unpatched kernel.
  sudo bash ./rebuild -b r66s_wxy-oect -k "$version" -a false -r xrzlddl/kernel -t ext4 -n xrzlddl
  for board in r66s wxy-oect; do
    image_file=$(find build/output/images -maxdepth 1 -name "Armbian_*_rockchip_${board}_bookworm_${version}_*.img.gz" -print -quit)
    [[ -s $image_file ]]
    verify_dir=$(mktemp -d)
    mkdir -p "$verify_dir/boot" "$verify_dir/root"
    gzip -dc "$image_file" > "$verify_dir/image.img"
    loop=$(sudo losetup --find --show --partscan "$verify_dir/image.img")
    cleanup_image() {
      sudo umount "$verify_dir/boot" 2>/dev/null || true
      sudo umount "$verify_dir/root" 2>/dev/null || true
      sudo losetup -d "$loop" 2>/dev/null || true
      rm -rf "$verify_dir"
    }
    trap cleanup_image EXIT
    sudo mount -o ro "${loop}p1" "$verify_dir/boot"
    sudo mount -o ro "${loop}p2" "$verify_dir/root"
    wanted=$(python3 -c 'import json;print(json.load(open("security-evidence/validation.json"))["image_sha256"])')
    actual=$(sudo sha256sum "$verify_dir/boot/vmlinuz-$release" | cut -d' ' -f1)
    [[ $wanted == "$actual" ]]
    sudo test -d "$verify_dir/root/usr/lib/modules/$release"
    if [[ $board == r66s ]]; then
      sudo grep -q rk3568-fastrhino-r66s.dtb "$verify_dir/boot/armbianEnv.txt"
    else
      sudo grep -q rk3566-wxy-oec-turbo-4g.dtb "$verify_dir/boot/extlinux/extlinux.conf"
    fi
    printf '%s Image SHA256 %s; modules and board boot configuration verified\n' "$board" "$actual" >> "$evidence/image-validation.txt"
    cleanup_image
    trap - EXIT
  done
  (cd build/output/images && sha256sum Armbian_*_rockchip_*.img.gz) > "$evidence/images.sha256"
  echo 'Hardware boot/network/storage testing has not been performed.' >> "$evidence/image-validation.txt"
else
  echo 'Unknown mode' >&2; exit 1
fi
