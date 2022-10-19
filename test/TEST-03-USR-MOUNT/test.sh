#!/bin/bash

# shellcheck disable=SC2034
TEST_DESCRIPTION="root filesystem on a btrfs filesystem with /usr subvolume"

KVERSION=${KVERSION-$(uname -r)}

# Uncomment this to debug failures
#DEBUGFAIL="rd.shell rd.break"

client_run() {
    local test_name="$1"
    shift
    local client_opts="$*"

    echo "CLIENT TEST START: $test_name"

    dd if=/dev/zero of="$TESTDIR"/marker.img bs=1MiB count=1
    declare -a disk_args=()
    # shellcheck disable=SC2034
    declare -i disk_index=0
    qemu_add_drive_args disk_index disk_args "$TESTDIR"/marker.img marker
    qemu_add_drive_args disk_index disk_args "$TESTDIR"/root.btrfs root
    qemu_add_drive_args disk_index disk_args "$TESTDIR"/usr.btrfs usr

    "$testdir"/run-qemu \
        "${disk_args[@]}" \
        -watchdog i6300esb -watchdog-action poweroff \
        -append "panic=1 oops=panic softlockup_panic=1 systemd.crash_reboot root=LABEL=dracut $client_opts loglevel=7 rd.retry=3 rd.info console=ttyS0,115200n81 selinux=0 rd.debug rd.shell=0 $DEBUGFAIL" \
        -initrd "$TESTDIR"/initramfs.testing || return 1

    if ! grep -U --binary-files=binary -F -m 1 -q dracut-root-block-success "$TESTDIR"/marker.img; then
        echo "CLIENT TEST END: $test_name [FAILED]"
        return 1
    fi
    echo "CLIENT TEST END: $test_name [OK]"

}

test_run() {
    client_run "no option specified" || return 1
    client_run "readonly root" "ro" || return 1
    client_run "writeable root" "rw" || return 1
    return 0
}

test_setup() {
    # Create what will eventually be our root filesystem onto an overlay
    (
        # shellcheck disable=SC2030
        export initdir=$TESTDIR/overlay/source
        mkdir -p -- "$initdir" "$TESTDIR"/overlay/tmp
        # shellcheck disable=SC1090
        . "$basedir"/dracut-init.sh

        "$basedir"/dracut.sh -l --keep --tmpdir "$TESTDIR"/overlay/tmp \
            -m "test-root" \
            -i ./test-init.sh /sbin/init \
            -i "${basedir}/modules.d/99base/dracut-lib.sh" "/lib/dracut-lib.sh" \
            -i "${basedir}/modules.d/99base/dracut-dev-lib.sh" "/lib/dracut-dev-lib.sh" \
            --no-hostonly --no-hostonly-cmdline --nomdadmconf --nohardlink \
            -f "$TESTDIR"/initramfs.root "$KVERSION" || return 1

        mv "$TESTDIR"/overlay/tmp/dracut.*/initramfs/* "$initdir" && rm -rf "$TESTDIR"/overlay/tmp

        inst_multiple sh dmesg umount strace setsid sync

        inst_simple ./fstab /etc/fstab
        find_binary plymouth > /dev/null && inst_multiple plymouth
    )

    # second, install the files needed to make the root filesystem
    (
        # shellcheck disable=SC2031
        # shellcheck disable=SC2030
        export initdir=$TESTDIR/overlay
        # shellcheck disable=SC1090
        . "$basedir"/dracut-init.sh
        inst_multiple sfdisk mkfs.btrfs btrfs
        inst_hook initqueue 01 ./create-root.sh
    )

    # create an initramfs that will create the target root filesystem.
    # We do it this way so that we do not risk trashing the host mdraid
    # devices, volume groups, encrypted partitions, etc.
    "$basedir"/dracut.sh -l -i "$TESTDIR"/overlay / \
        -m "test-makeroot dash btrfs rootfs-block kernel-modules" \
        -d "piix ide-gd_mod ata_piix btrfs sd_mod" \
        --nomdadmconf \
        --nohardlink \
        --no-hostonly-cmdline -N \
        -f "$TESTDIR"/initramfs.makeroot "$KVERSION" || return 1
    rm -rf -- "$TESTDIR"/overlay

    # Create the blank file to use as a root filesystem
    dd if=/dev/zero of="$TESTDIR"/root.btrfs bs=1MiB count=160
    dd if=/dev/zero of="$TESTDIR"/usr.btrfs bs=1MiB count=160
    dd if=/dev/zero of="$TESTDIR"/marker.img bs=1MiB count=1
    declare -a disk_args=()
    # shellcheck disable=SC2034
    declare -i disk_index=0
    qemu_add_drive_args disk_index disk_args "$TESTDIR"/marker.img marker
    qemu_add_drive_args disk_index disk_args "$TESTDIR"/root.btrfs root
    qemu_add_drive_args disk_index disk_args "$TESTDIR"/usr.btrfs usr

    # Invoke KVM and/or QEMU to actually create the target filesystem.
    "$testdir"/run-qemu \
        "${disk_args[@]}" \
        -append "root=/dev/dracut/root rw rootfstype=btrfs quiet console=ttyS0,115200n81 selinux=0" \
        -initrd "$TESTDIR"/initramfs.makeroot || return 1

    if ! grep -U --binary-files=binary -F -m 1 -q dracut-root-block-created "$TESTDIR"/marker.img; then
        echo "Could not create root filesystem"
        return 1
    fi

    (
        # shellcheck disable=SC2031
        export initdir=$TESTDIR/overlay
        # shellcheck disable=SC1090
        . "$basedir"/dracut-init.sh
        inst_multiple dd
    )
    "$basedir"/dracut.sh -l -i "$TESTDIR"/overlay / \
        -a "test watchdog" \
        -o "network kernel-network-modules" \
        -d "piix ide-gd_mod ata_piix btrfs sd_mod i6300esb ib700wdt" \
        --no-hostonly-cmdline -N \
        -f "$TESTDIR"/initramfs.testing "$KVERSION" || return 1

    rm -rf -- "$TESTDIR"/overlay
}

test_cleanup() {
    return 0
}

# shellcheck disable=SC1090
. "$testdir"/test-functions
