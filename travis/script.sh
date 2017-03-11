#!/bin/bash
#
# $Id$
#
# Copyright 2016-2017 Quantcast Corporation. All rights reserved.
#
# This file is part of Quantcast File System.
#
# Licensed under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License. You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
# implied. See the License for the specific language governing
# permissions and limitations under the License.

################################################################################
# The following is executed on .travis.yml's script section
################################################################################

set -ex

DEPS_UBUNTU='g++ cmake git libboost-regex-dev libkrb5-dev libssl-dev python-dev'
DEPS_UBUNTU=$DEPS_UBUNTU' libfuse-dev default-jdk unzip maven sudo passwd'
DEPS_UBUNTU=$DEPS_UBUNTU' curl openssl'

DEPS_CENTOS='gcc-c++ make git boost-devel krb5-devel'
DEPS_CENTOS=$DEPS_CENTOS' python-devel fuse-devel java-openjdk java-devel'
DEPS_CENTOS=$DEPS_CENTOS' libuuid-devel curl unzip sudo which openssl'

DEPS_CENTOS5=$DEPS_CENTOS' cmake28 openssl101e openssl101e-devel'
DEPS_CENTOS=$DEPS_CENTOS' openssl-devel cmake'

MYMVN_URL='https://www.apache.org/dist/maven/binaries/apache-maven-3.0.5-bin.tar.gz'

MYTMPDIR='.tmp'
MYCODECOV="$MYTMPDIR/codecov.sh"
MYCENTOSEPEL_RPM="$MYTMPDIR/epel-release-latest.rpm"
MYMVNTAR="$MYTMPDIR/$(basename "$MYMVN_URL")"

MYCMAKE='cmake'

MYCMAKE_OPTIONS=''
MYCMAKE_OPTIONS=$MYCMAKE_OPTIONS' -D QFS_EXTRA_CXX_OPTIONS=-Werror'
MYCMAKE_OPTIONS=$MYCMAKE_OPTIONS' -D QFS_EXTRA_C_OPTIONS=-Werror'

MYCMAKE_CENTOS5='cmake28'
MYCMAKE_OPTIONS_CENTOS5=$MYCMAKE_OPTIONS' -D _OPENSSL_INCLUDEDIR=/usr/include/openssl101e'
MYCMAKE_OPTIONS_CENTOS5=$MYCMAKE_OPTIONS_CENTOS5' -D _OPENSSL_LIBDIR=/usr/lib64/openssl101e'

MYBUILD_TYPE='release'

set_sudo()
{
    if [ x"$(id -u)" = x'0' ]; then
        MYSUDO=
        MYUSER=
        if [ $# -gt 0 ]; then
            if [ x"$1" = x'root' ]; then
                true
            else
                MYUSER=$1
            fi
        fi
        if [ x"$MYUSER" = x ]; then
            MYSU=
        else
            MYSU="sudo -H -u $MYUSER"
        fi
    else
        MYSUDO='sudo'
        MYSU=
        MYUSER=
    fi
}

tail_logs_and_exit()
{
    MYQFSTEST_DIR="build/$MYBUILD_TYPE/qfstest"
    if [ -d "$MYQFSTEST_DIR" ]; then
        find "$MYQFSTEST_DIR" -type f -name '*.log' -print0 \
        | xargs -0  tail -n 100
    fi
    exit 1
}

do_build()
{
    if [ x"$MYBUILD_TYPE" = x'debug' ]; then
        MYCMAKE_OPTIONS=$MYCMAKE_OPTIONS' -D CMAKE_BUILD_TYPE=Debug'
    else
        MYCMAKE_OPTIONS=$MYCMAKE_OPTIONS' -D CMAKE_BUILD_TYPE=RelWithDebInfo'
    fi
    sync || true
    $MYSU make ${1+"$@"} \
        BUILD_TYPE="$MYBUILD_TYPE" \
        CMAKE="$MYCMAKE" \
        CMAKE_OPTIONS="$MYCMAKE_OPTIONS" \
        JAVA_BUILD_OPTIONS='-r 2' \
        test tarball \
    || tail_logs_and_exit
}

do_build_linux()
{
    MYMAKEOPT='-j 2'
    if [ -r /proc/cpuinfo ]; then
        cat /proc/cpuinfo
        MYCCNT=`grep -c -w processor /proc/cpuinfo`
        if [ $MYCCNT -gt 2 ]; then
            MYMAKEOPT="-j $MYCCNT"
        fi
    fi
    if [ -r "$MYCODECOV" ]; then
        MYCMAKE_OPTIONS="$MYCMAKE_OPTIONS -D ENABLE_COVERAGE=ON"
    fi
    MYMAKEOPT="$MYMAKEOPT --no-print-directory"
    df -h || true
    do_build ${1+"$@"} $MYMAKEOPT
    if [ -r "$MYCODECOV" ]; then
        /bin/bash "$MYCODECOV"
    fi
}

init_codecov()
{
    # Run code coverage in docker
    # Pass travis env vars to code coverage.
    mkdir -p  "$MYTMPDIR"
    {
        env | grep -E '^(TRAVIS|CI)' | sed \
            -e "s/'/'\\\''/g"  \
            -e "s/=/=\'/" \
            -e 's/$/'"'/" \
            -e 's/^/export /'
        echo 'curl -s https://codecov.io/bash | /bin/bash'
    } > "$MYCODECOV"
}

build_ubuntu()
{
    $MYSUDO apt-get update
    $MYSUDO apt-get install -y $DEPS_UBUNTU
    do_build_linux
}

build_ubuntu32()
{
    build_ubuntu
}

build_centos()
{
    if [ -f "$MYCENTOSEPEL_RPM" ]; then
        $MYSUDO rpm -Uvh "$MYCENTOSEPEL_RPM"
    fi
    eval MYDEPS='${DEPS_CENTOS'"$1"'-$DEPS_CENTOS}'
    $MYSUDO yum install -y $MYDEPS
    MYPATH=$PATH
    # CentOS doesn't package maven directly so we have to install it manually
    if [ -f "$MYMVNTAR" ]; then
        $MYSUDO tar -xf "$MYMVNTAR" -C '/usr/local'
        # Set up PATH and links
        (
            cd '/usr/local'
            $MYSUDO ln -snf "$(basename "$MYMVNTAR" '-bin.tar.gz')" maven
        )
        M2_HOME='/usr/local/maven'
        MYPATH="${M2_HOME}/bin:${MYPATH}"
    fi
    if [ x"$1" = x'5' ]; then
        # Force build and test to use openssl101e.
        # Add Kerberos binaries dir to path to make krb5-config available.
        if [ x"$MYUSER" = x ]; then
            MYBINDIR="$HOME/local/openssl101e/bin"
        else
            MYBINDIR='/usr/local/openssl101e/bin'
        fi
        mkdir -p "$MYBINDIR"
        ln -snf "`which openssl101e`" "$MYBINDIR/openssl"
        MYPATH="$MYBINDIR:$MYPATH:/usr/kerberos/bin"
        MYCMAKE_OPTIONS=$MYCMAKE_OPTIONS_CENTOS5
        MYCMAKE=$MYCMAKE_CENTOS5
    fi
    if [ x"$1" = x'7' ]; then
        # CentOS7 has the distro information in /etc/redhat-release
        $MYSUDO /bin/bash -c \
            "cut /etc/redhat-release -d' ' --fields=1,3,4 > /etc/issue"
    fi
    do_build_linux PATH="$MYPATH" ${M2_HOME+M2_HOME="$M2_HOME"}
}

set_build_type()
{
    if [ x"$1" = x ]; then
        true
    else
        MYBUILD_TYPE=$1
    fi
}

if [ $# -eq 5 -a x"$1" = x'build' ]; then
    set_build_type "$4"
    set_sudo "$5"
    if [ x"$MYUSER" = x ]; then
        true
    else
        # Create regular user to run the build and test under it.
        id -u "$MYUSER" >/dev/null 2>&1 || useradd -m "$MYUSER"
        chown -R "$MYUSER" .
    fi
    "$1_$(basename "$2")" "$3"
    exit
fi

if [ x"$TRAVIS_OS_NAME" = x'linux' ]; then
    if [ -e "$MYTMPDIR" ]; then
        rm -r "$MYTMPDIR"
    fi
    make rat clean
    if [ x"$CODECOV" = x'yes' ]; then
        init_codecov
    fi
    if [ x"$DISTRO" = x'centos' ]; then
        mkdir -p  "$MYTMPDIR"
        curl --retry 3 -S -o "$MYMVNTAR" "$MYMVN_URL"
        if [ x"$VER" = x'5' ]; then
            # Download here as curl/openssl and root certs are dated on centos5,
            # and https downloads don't work.
            curl --retry 3 -S -o "$MYCENTOSEPEL_RPM" \
                'https://dl.fedoraproject.org/pub/epel/epel-release-latest-5.noarch.rpm'
        fi
    fi
    MYSRCD="$(pwd)"
    docker run --rm --dns=8.8.8.8 -t -v "$MYSRCD:$MYSRCD" -w "$MYSRCD" "$DISTRO:$VER" \
        /bin/bash ./travis/script.sh build "$DISTRO" "$VER" "$BTYPE" "$BUSER"
elif [ x"$TRAVIS_OS_NAME" = x'osx' ]; then
    set_build_type "$BTYPE"
    MYSSLD='/usr/local/Cellar/openssl/'
    if [ -d "$MYSSLD" ]; then
        MYSSLD="${MYSSLD}$(LANG=C ls -1 "$MYSSLD" | tail -n 1)"
        MYCMAKE_OPTIONS="$MYCMAKE_OPTIONS -D OPENSSL_ROOT_DIR=${MYSSLD}"
        MYSSLBIND="$MYSSLD/bin"
        if [ -f "$MYSSLBIND/openssl" ] && \
                PATH="$MYSSLBIND:$PATH" \
                openssl version > /dev/null 2>&1; then
            PATH="$MYSSLBIND:$PATH"
            export PATH
        fi
    fi
    make rat clean
    sysctl machdep.cpu || true
    df -h || true
    do_build -j 2
else
    echo "OS: $TRAVIS_OS_NAME not yet supported"
    exit 1
fi
