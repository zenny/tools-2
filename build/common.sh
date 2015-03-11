#!/bin/sh

# Copyright (c) 2014-2015 Franco Fichtner <franco@opnsense.org>
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
#
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
#
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
# OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
# HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
# LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
# OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
# SUCH DAMAGE.

set -e

# important build settings
export PRODUCT_NAME="OPNsense"
export PRODUCT_VERSION=${PRODUCT_VERSION:-"`date '+%Y%m%d%H%M'`"}

# build directories
export STAGEDIR="/usr/local/stage"
export PACKAGESDIR="/tmp/packages"
export IMAGESDIR="/tmp/images"
export SETSDIR="/tmp/sets"

# code reositories
export TOOLSDIR="/usr/tools"
export PORTSDIR="/usr/ports"
export COREDIR="/usr/core"
export SRCDIR="/usr/src"

# misc. foo
export CPUS=`sysctl kern.smp.cpus | awk '{ print $2 }'`
export ARCH=${ARCH:-"`uname -m`"}
export TARGET_ARCH=${ARCH}
export TARGETARCH=${ARCH}
export LABEL="OPNsense_Install"

# target files
export CDROM="${IMAGESDIR}/${PRODUCT_NAME}-${PRODUCT_VERSION}-cdrom-${ARCH}.iso"
export SERIALIMG="${IMAGESDIR}/${PRODUCT_NAME}-${PRODUCT_VERSION}-serial-${ARCH}.img"
export VGAIMG="${IMAGESDIR}/${PRODUCT_NAME}-${PRODUCT_VERSION}-vga-${ARCH}.img"

# print environment to showcase all of our variables
env

git_clear()
{
	# Reset the git repository into a known state by
	# enforcing a hard-reset to HEAD (so you keep your
	# selected commit, but no manual changes) and all
	# unknown files are cleared (so it looks like a
	# freshly cloned repository).

	echo -n ">>> Resetting ${1}... "

	git -C ${1} reset --hard HEAD
	git -C ${1} clean -xdqf .
}

git_describe()
{
	VERSION=$(git -C ${1} describe --abbrev=0)
	REVISION=$(git -C ${1} rev-list ${VERSION}.. --count)
	COMMENT=$(git -C ${1} rev-list HEAD --max-count=1 | cut -c1-9)
	if [ "${REVISION}" != "0" ]; then
		# must construct full version string manually
		VERSION=${VERSION}_${REVISION}
	fi

	export REPO_VERSION=${VERSION}
	export REPO_COMMENT=${COMMENT}
}

setup_clone()
{
	echo ">>> Setting up ${2} in ${1}"

	# repositories may be huge so avoid the copy :)
	mkdir -p ${1}${2} && mount_unionfs -o below ${2} ${1}${2}
}

setup_chroot()
{
	echo ">>> Setting up chroot in ${1}"

	cp /etc/resolv.conf ${1}/etc
	mount -t devfs devfs ${1}/dev
	chroot ${1} /etc/rc.d/ldconfig start
}

setup_base()
{
	echo ">>> Setting up world in ${1}"

	# /home is needed for LiveCD images, and since it
	# belongs to the base system, we create it from here.
	mkdir -p ${1}/home

	(cd ${1} && tar -Jxpf ${SETSDIR}/base-*-${ARCH}.txz)
}

setup_kernel()
{
	echo ">>> Setting up kernel in ${1}"

	(cd ${1} && tar -Jxpf ${SETSDIR}/kernel-*-${ARCH}.txz)
}

setup_packages()
{
	echo ">>> Setting up packages in ${1}..."

	BASEDIR=${1}
	shift
	PKGLIST=${@}

	mkdir -p ${PACKAGESDIR}/${ARCH} ${BASEDIR}${PACKAGESDIR}/${ARCH}
	cp ${PACKAGESDIR}/${ARCH}/* ${BASEDIR}${PACKAGESDIR}/${ARCH} || true

	if [ -z "${PKGLIST}" ]; then
		# forcefully add all available packages
		pkg -c ${BASEDIR} add -f ${PACKAGESDIR}/${ARCH}/*.txz || true
	else
		# always bootstrap pkg
		PKGLIST="pkg ${PKGLIST}"

		for PKG in ${PKGLIST}; do
			# must fail if packages aren't there
			pkg -c ${BASEDIR} add ${PACKAGESDIR}/${ARCH}/${PKG}-*.txz
		done

		# collect all installed packages
		PKGLIST="$(pkg -c ${BASEDIR} query %n)"

		for PKG in ${PKGLIST}; do
			# add, unlike install, is not aware of repositories :(
			pkg -c ${BASEDIR} annotate -qyA ${PKG} repository OPNsense
		done
	fi

	# keep the directory!
	rm -rf ${BASEDIR}${PACKAGESDIR}/${ARCH}/*
}

setup_platform()
{
	echo ">>> Setting up platform in ${1}..."

	# XXX clean this up further maybe?
	mkdir -p ${1}/conf
	touch ${1}/conf/trigger_initial_wizard

	# Let opnsense-update(8) know it's up to date
	local MARKER="/usr/local/opnsense/version/os-update"
	mkdir -p ${1}$(dirname ${MARKER})
	echo ${PRODUCT_VERSION}-${ARCH} > ${1}${MARKER}

	echo cdrom > ${1}/usr/local/etc/platform
}

setup_mtree()
{
	echo ">>> Creating mtree summary of files present..."

	cat > ${1}/tmp/installed_filesystem.mtree.exclude <<EOF
./dev
./tmp
EOF
	chroot ${1} /bin/sh -s <<EOF
/usr/sbin/mtree -c -k uid,gid,mode,size,sha256digest -p / -X /tmp/installed_filesystem.mtree.exclude > /tmp/installed_filesystem.mtree
/bin/chmod 600 /tmp/installed_filesystem.mtree
/bin/mv /tmp/installed_filesystem.mtree /etc/
/bin/rm /tmp/installed_filesystem.mtree.exclude
EOF
}

setup_stage()
{
	echo ">>> Setting up stage in ${1}"

	local MOUNTDIRS="/dev /usr/src /usr/ports /usr/core"

	# might have been a chroot
	for DIR in ${MOUNTDIRS}; do
		if [ -d ${1}${DIR} ]; then
			umount ${1}${DIR} 2> /dev/null || true
		fi
	done

	# remove base system files
	rm -rf ${1} 2> /dev/null ||
	    (chflags -R noschg ${1}; rm -rf ${1} 2> /dev/null)

	# revive directory for next run
	mkdir -p ${1}
}
