#!/usr/bin/env bash

cd "$(dirname "$0")"

# turn on verbose debugging output for parabuild logs.
exec 4>&1; export BASH_XTRACEFD=4; set -x
# make errors fatal
set -e
# complain about unset env variables
set -u

if [ -z "$AUTOBUILD" ] ; then
    exit 1
fi

if [[ "$OSTYPE" == "cygwin" || "$OSTYPE" == "msys" ]] ; then
    # need igncr so cygwin bash will trim both '\r\n' from $(command)
    set -o igncr
    autobuild="$(cygpath -u $AUTOBUILD)"
else
    autobuild="$AUTOBUILD"
    # dummy to avoid tedious conditionals everywhere
    function cygpath {
        # pathname comes last after switches
        local last
        eval last=\$$#
        echo "$last"
    }
fi

top="$(pwd)"
stage="$top/stage"
CURL_SOURCE_DIR="$top/curl"
CURL_BUILD_DIR="$top/build"

# load autobuild provided shell functions and variables
source_environment_tempfile="$stage/source_environment.sh"
"$autobuild" source_environment > "$source_environment_tempfile"
. "$source_environment_tempfile"

# remove_cxxstd
source "$(dirname "$AUTOBUILD_VARIABLES_FILE")/functions"

# Use msbuild.exe instead of devenv.com
build_sln() {
    local solution=$1
    local config=$2
    local proj="${3:-}"
    local toolset="${AUTOBUILD_WIN_VSTOOLSET:-v143}"

    # e.g. config = "Release|$AUTOBUILD_WIN_VSPLATFORM" per devenv.com convention
    local -a confparts
    IFS="|" read -ra confparts <<< "$config"

    msbuild.exe \
        "$(cygpath -w "$solution")" \
        ${proj:+-t:"$proj"} \
        -p:Configuration="${confparts[0]}" \
        -p:Platform="${confparts[1]}" \
        -p:PlatformToolset=$toolset
}

ZLIB_INCLUDE="${stage}"/packages/include/zlib-ng
OPENSSL_INCLUDE="${stage}"/packages/include/openssl

[ -f "$ZLIB_INCLUDE"/zlib.h ] || fail "You haven't installed the zlib package yet."
[ -f "$OPENSSL_INCLUDE"/ssl.h ] || fail "You haven't installed the openssl package yet."

LIBCURL_HEADER_DIR="${CURL_SOURCE_DIR}"/include
LIBCURL_VERSION_HEADER_DIR="$LIBCURL_HEADER_DIR/curl"
version="$(sed -nE 's/#define LIBCURL_VERSION "([^"]+)".*$/\1/p' \
           "$(cygpath -m "${LIBCURL_VERSION_HEADER_DIR}/curlver.h")")"
build=${AUTOBUILD_BUILD_ID:=0}
echo "${version}-${build}" > "${stage}/VERSION.txt"

# Restore all .sos
restore_sos ()
{
    for solib in "${stage}"/packages/lib/release/lib*.so*.disable; do
        if [ -f "$solib" ]; then
            mv -f "$solib" "${solib%.disable}"
        fi
    done
}


# Restore all .dylibs
restore_dylibs ()
{
    for dylib in "$stage/packages/lib"/release/*.dylib.disable; do
        if [ -f "$dylib" ]; then
            mv "$dylib" "${dylib%.disable}"
        fi
    done
}

# See if there's anything wrong with the checked out or
# generated files.  Main test is to confirm that c-ares
# is defeated and we're using a threaded resolver.
check_damage ()
{
    case "$1" in
        windows*)
            #echo "Verifying Ares is disabled"
            #grep 'USE_ARES\s*1' lib/curl_config.h | grep '^/\*'
        ;;

        darwin*|linux*)
            echo "Verifying Ares is disabled"
            egrep 'USE_THREADS_POSIX[[:space:]]+1' lib/curl_config.h
        ;;
    esac
}

# Read the version of a particular installable package from autobuild.xml.
# Optional $2 specifies number of version-number parts to report.
get_installable_version ()
{
    set +x
    # This command dumps the autobuild.xml data for the specified installable
    # in Python literal syntax.
    pydata="$("$autobuild" installables print "$1")"
    # Now harvest the version key.
    # It's important to use ''' syntax because of newlines in output. Specify
    # raw literal syntax too in case of backslashes.
    # Use ast.literal_eval(), safer than plain builtin eval.
    # Once we have the Python dict, extract "version" key.
    # Split version number on '.'.
    # Keep up to $2 version-number parts.
    # Rejoin them on '.' again and print.
    # On Windows, use sys.stdout.buffer.write() to avoid appending '\r\n': the
    # '\r' is NOT removed by bash, so it becomes part of the string contents,
    # which confuses both scripted comparisons and human readers.
    python -c "from ast import literal_eval
import sys
sys.stdout.buffer.write('.'.join(literal_eval(r'''$pydata''')['version'].split('.')[:${2:-}]).encode('utf-8'))"
    set -x
}

# Given an (e.g. version) string possibly containing periods, escape those
# periods with backslashes.
escape_dots ()
{
    echo "${1//./\\.}"
}

mkdir -p "$CURL_BUILD_DIR"

pushd "$CURL_BUILD_DIR"
    case "$AUTOBUILD_PLATFORM" in
        windows*)
            packages="$(cygpath -m "$stage/packages")"
            load_vsvars

            mkdir -p "build_debug"
            pushd "build_debug"
                opts="$(replace_switch /Zi /Z7 $LL_BUILD_DEBUG) -DNGHTTP2_STATICLIB=1"
                plainopts="$(remove_switch /GR $(remove_cxxstd $opts))"

                cmake "$(cygpath -m "${CURL_SOURCE_DIR}")" \
                    -G"$AUTOBUILD_WIN_CMAKE_GEN" -A"$AUTOBUILD_WIN_VSPLATFORM" \
                    -DCMAKE_CONFIGURATION_TYPES="Debug" \
                    -DCMAKE_C_FLAGS:STRING="$plainopts" \
                    -DCMAKE_CXX_FLAGS:STRING="$opts" \
                    -DCMAKE_MSVC_DEBUG_INFORMATION_FORMAT="Embedded" \
                    -DCMAKE_INSTALL_PREFIX="$(cygpath -m "$stage")" \
                    -DENABLE_THREADED_RESOLVER:BOOL=ON \
                    -DCMAKE_USE_OPENSSL:BOOL=TRUE \
                    -DUSE_NGHTTP2:BOOL=TRUE \
                    -DZLIB_LIBRARIES="$(cygpath -m ${stage}/packages/lib/debug/zlibd.lib)" \
                    -DZLIB_INCLUDE_DIRS="$(cygpath -m ${stage}/packages/include/zlib-ng)" \
                    -DNGHTTP2_LIBRARIES="$(cygpath -m ${stage}/packages/lib/debug/nghttp2.lib)" \
                    -DNGHTTP2_INCLUDE_DIRS="$(cygpath -m ${stage}/packages/include/nghttp2)" \
                    -DOPENSSL_LIBRARIES="$(cygpath -m ${stage}/packages/lib/debug/libcrypto.lib);$(cygpath -m ${stage}/packages/lib/debug/libssl.lib)" \
                    -DOPENSSL_INCLUDE_DIR="$(cygpath -m ${stage}/packages/include/)"

                check_damage "$AUTOBUILD_PLATFORM"

                cmake --build . --config Debug -j$AUTOBUILD_CPU_COUNT
                cmake --install . --config Debug

                # conditionally run unit tests
                if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                    pushd tests
                    # Nothin' to do yet
                    popd
                fi

                # Stage archives
                mkdir -p "${stage}/lib/debug"
                mv "${stage}/lib/libcurld.lib" "${stage}"/lib/debug/
            popd

            mkdir -p "build_release"
            pushd "build_release"
                opts="$(replace_switch /Zi /Z7 $LL_BUILD_RELEASE) -DNGHTTP2_STATICLIB=1"
                plainopts="$(remove_switch /GR $(remove_cxxstd $opts))"

                cmake "$(cygpath -m "${CURL_SOURCE_DIR}")" \
                    -G"$AUTOBUILD_WIN_CMAKE_GEN" -A"$AUTOBUILD_WIN_VSPLATFORM" \
                    -DCMAKE_CONFIGURATION_TYPES="Release" \
                    -DCMAKE_C_FLAGS:STRING="$plainopts" \
                    -DCMAKE_CXX_FLAGS:STRING="$opts" \
                    -DCMAKE_MSVC_DEBUG_INFORMATION_FORMAT="Embedded" \
                    -DCMAKE_INSTALL_PREFIX="$(cygpath -m "$stage")" \
                    -DENABLE_THREADED_RESOLVER:BOOL=ON \
                    -DCMAKE_USE_OPENSSL:BOOL=TRUE \
                    -DUSE_NGHTTP2:BOOL=TRUE \
                    -DZLIB_LIBRARIES="$(cygpath -m ${stage}/packages/lib/release/zlib.lib)" \
                    -DZLIB_INCLUDE_DIRS="$(cygpath -m ${stage}/packages/include/zlib-ng)" \
                    -DNGHTTP2_LIBRARIES="$(cygpath -m ${stage}/packages/lib/release/nghttp2.lib)" \
                    -DNGHTTP2_INCLUDE_DIRS="$(cygpath -m ${stage}/packages/include/nghttp2)" \
                    -DOPENSSL_LIBRARIES="$(cygpath -m ${stage}/packages/lib/release/libcrypto.lib);$(cygpath -m ${stage}/packages/lib/release/libssl.lib)" \
                    -DOPENSSL_INCLUDE_DIR="$(cygpath -m ${stage}/packages/include/)"

                check_damage "$AUTOBUILD_PLATFORM"

                cmake --build . --config Release -j$AUTOBUILD_CPU_COUNT
                cmake --install . --config Release

                # conditionally run unit tests
                if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                    pushd tests
                    # Nothin' to do yet
                    popd
                fi

                # Stage archives
                mkdir -p "${stage}/lib/release"
                mv "${stage}/lib/libcurl.lib" "${stage}"/lib/release/
            popd

            # Run 'curl' as a sanity check. Capture just the first line, which
            # should have versions of stuff.
            curlout="$("${stage}/bin/curl.exe" --version | head -n 1)"
            # With -e in effect, any nonzero rc blows up the script --
            # so plain 'expr str : pattern' asserts that str contains pattern.
            # curl version - should be start of line
            expr "$curlout" : "curl $(escape_dots "$version")" #> /dev/null
            # libcurl/version
            expr "$curlout" : ".* libcurl/$(escape_dots "$version")" > /dev/null
            # OpenSSL/version
            #expr "$curlout" : ".* OpenSSL/$(escape_dots "$(get_installable_version openssl 3)")" > /dev/null
            # zlib/version
            expr "$curlout" : ".* zlib/" > /dev/null
        ;;

        darwin*)
            export MACOSX_DEPLOYMENT_TARGET="$LL_BUILD_DARWIN_DEPLOY_TARGET"

            # Force libz and openssl static linkage by moving .dylibs out of the way
            # trap restore_dylibs EXIT
            # for dylib in "$stage"/packages/lib/release/lib{z,crypto,ssl}*.dylib; do
            #     if [ -f "$dylib" ]; then
            #         mv "$dylib" "$dylib".disable
            #     fi
            # done

            # Release configure and build

            # Make .dylib's usable during configure as well as unit tests
            # (Used when building with dylib libz or OpenSSL.)
            # mkdir -p Resources/
            # ln -sf "${stage}"/packages/lib/release/*.dylib Resources/
            # mkdir -p ../Resources/
            # ln -sf "${stage}"/packages/lib/release/*.dylib ../Resources/
            # mkdir -p tests/Resources/
            # ln -sf "${stage}"/packages/lib/release/*.dylib tests/Resources/
            # LDFLAGS="-L../Resources/ -L\"$stage\"/packages/lib/release" \

            # -T buildsystem=1 is to work around an error in the upstream
            # CMakeLists.txt that doesn't work with the Xcode "new build
            # system." Possibly a newer version of curl will fix.
            # https://stackoverflow.com/a/65474688
            for arch in x86_64 arm64 ; do
                ARCH_ARGS="-arch $arch"
                cxx_opts="${TARGET_OPTS:-$ARCH_ARGS $LL_BUILD_RELEASE}"
                cc_opts="$(remove_cxxstd $cxx_opts)"
                cc_opts="$(remove_switch -stdlib=libc++ $cc_opts)"
                ld_opts="$ARCH_ARGS"

                mkdir -p "build_$arch"
                pushd "build_$arch"
                    CFLAGS="$cc_opts" \
                    CXXFLAGS="$cxx_opts" \
                    LDFLAGS="$ld_opts" \
                    cmake "${CURL_SOURCE_DIR}" -G Ninja -DCMAKE_BUILD_TYPE=Release \
                        -DCMAKE_C_FLAGS:STRING="$cc_opts" \
                        -DCMAKE_CXX_FLAGS:STRING="$cxx_opts" \
                        -DBUILD_SHARED_LIBS:BOOL=OFF \
                        -DENABLE_THREADED_RESOLVER:BOOL=ON \
                        -DCMAKE_USE_OPENSSL:BOOL=TRUE \
                        -DUSE_NGHTTP2:BOOL=TRUE \
                        -DCMAKE_INSTALL_PREFIX="$stage" \
                        -DCMAKE_INSTALL_LIBDIR="$stage/lib/release/$arch" \
                        -DCMAKE_OSX_ARCHITECTURES="$arch" \
                        -DCMAKE_OSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET} \
                        -DZLIB_LIBRARIES="${stage}/packages/lib/release/libz.a" \
                        -DZLIB_INCLUDE_DIRS="${stage}/packages/include/zlib-ng" \
                        -DNGHTTP2_LIBRARIES="${stage}/packages/lib/release/libnghttp2.a" \
                        -DNGHTTP2_INCLUDE_DIRS="${stage}/packages/include/nghttp2" \
                        -DOPENSSL_LIBRARIES="${stage}/packages/lib/release/libcrypto.a;${stage}/packages/lib/release/libssl.a" \
                        -DOPENSSL_INCLUDE_DIR="${stage}/packages/include/"

                    check_damage "$AUTOBUILD_PLATFORM"

                    cmake --build . --config Release -j$AUTOBUILD_CPU_COUNT
                    cmake --install . --config Release
                popd
            done

            # create fat libraries
            lipo -create -output ${stage}/lib/release/libcurl.a ${stage}/lib/release/x86_64/libcurl.a ${stage}/lib/release/arm64/libcurl.a

            # conditionally run unit tests
            # Disabled here and below by default on Mac because they
            # trigger the Mac firewall dialog and that may make
            # automated builds unreliable.  During development,
            # explicitly inhibit the disable and run the tests.  They
            # matter.
#            if [ "${DISABLE_UNIT_TESTS:-1}" = "0" ]; then
#                pushd tests
#                    # We hijack the 'quiet-test' target and redefine it as
#                    # a no-valgrind test.  Also exclude test 906.  It fails in the
#                    # 7.33 distribution with our configuration options.  530 fails
#                    # in TeamCity.  (Expect problems with the unit tests, they're
#                    # very sensitive to environment.)
#                    make quiet-test TEST_Q='-n !906 !530 !564 !584 !706 !1316'
#                popd
#            fi

            # Run 'curl' as a sanity check. Capture just the first line, which
            # should have versions of stuff.
            curlout="$("${stage}"/bin/curl --version | tr -d '\r' | head -n 1)"
            # With -e in effect, any nonzero rc blows up the script --
            # so plain 'expr str : pattern' asserts that str contains pattern.
            # curl version - should be start of line
            expr "$curlout" : "curl $(escape_dots "$version")" > /dev/null
            # libcurl/version
            expr "$curlout" : ".* libcurl/$(escape_dots "$version")" > /dev/null
            # OpenSSL/version
            #expr "$curlout" : ".* OpenSSL/$(escape_dots "$(get_installable_version openssl 3)")" > /dev/null
            # zlib/version
            expr "$curlout" : ".* zlib/" > /dev/null
            # nghttp2/versionx
            #expr "$curlout" : ".* nghttp2/$(escape_dots "$(get_installable_version nghttp2 3)")" > /dev/null
        ;;

        linux*)
            # Default target per --address-size
            opts="${TARGET_OPTS:--m$AUTOBUILD_ADDRSIZE $LL_BUILD_RELEASE}"
            plainopts="$(remove_cxxstd $opts)"

            # Handle any deliberate platform targeting
            if [ -z "${TARGET_CPPFLAGS:-}" ]; then
                # Remove sysroot contamination from build environment
                unset CPPFLAGS
            else
                # Incorporate special pre-processing flags
                export CPPFLAGS="$TARGET_CPPFLAGS"
            fi

            # Force static linkage to libz and openssl by moving .sos out of the way
            trap restore_sos EXIT
            for solib in "${stage}"/packages/lib/release/lib{z,ssl,crypto}.so*; do
                if [ -f "$solib" ]; then
                    mv -f "$solib" "$solib".disable
                fi
            done

            mkdir -p "$stage/lib/release"

            # Autoconf's configure will do some odd things to flags.  '-I' options
            # will get transferred to '-isystem' and there's a problem with quoting.
            # Linking and running also require LD_LIBRARY_PATH to locate the OpenSSL
            # .so's.  The '--with-ssl' option could do this if we had a more normal
            # package layout.
            #
            # configure-time compilation looks like:
            # ac_compile='$CC -c $CFLAGS $CPPFLAGS conftest.$ac_ext >&5'
            # ac_link='$CC -o conftest$ac_exeext $CFLAGS $CPPFLAGS $LDFLAGS conftest.$ac_ext $LIBS >&5'
            saved_path="${LD_LIBRARY_PATH:-}"

            # Release configure and build
            export LD_LIBRARY_PATH="${stage}"/packages/lib/release:"$saved_path"

            cmake "${CURL_SOURCE_DIR}" -G"Ninja" -DCMAKE_BUILD_TYPE=Release \
                -DCMAKE_C_FLAGS:STRING="$plainopts" \
                -DCMAKE_CXX_FLAGS:STRING="$opts" \
                -DENABLE_THREADED_RESOLVER:BOOL=ON \
                -DCMAKE_USE_OPENSSL:BOOL=TRUE \
                -DUSE_NGHTTP2:BOOL=TRUE \
                -DBUILD_SHARED_LIBS:BOOL=FALSE \
                -DCMAKE_INSTALL_PREFIX=$stage \
                -DZLIB_LIBRARIES="${stage}/packages/lib/release/libz.a" \
                -DZLIB_INCLUDE_DIRS="${stage}/packages/include/zlib-ng" \
                -DNGHTTP2_LIBRARIES="${stage}/packages/lib/release/libnghttp2.a" \
                -DNGHTTP2_INCLUDE_DIRS="${stage}/packages/include/nghttp2" \
                -DOPENSSL_LIBRARIES="${stage}/packages/lib/release/libcrypto.a;${stage}/packages/lib/release/libssl.a;dl" \
                -DOPENSSL_INCLUDE_DIR="${stage}/packages/include/"

            check_damage "$AUTOBUILD_PLATFORM"

            cmake --build . --config Release -j$AUTOBUILD_CPU_COUNT
            cmake --install . --config Release

            mkdir -p "$stage/lib/release"
            mv "$stage/lib/libcurl.a" "$stage/lib/release/libcurl.a"

#           # conditionally run unit tests
#           if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
#                pushd tests
#                    # We hijack the 'quiet-test' target and redefine it as
#                    # a no-valgrind test.  Also exclude test 906.  It fails in the
#                    # 7.33 distribution with our configuration options.  530 fails
#                    # in TeamCity.  815 hangs in 7.36.0 fixed in 7.37.0.
#                    #
#                    # Expect problems with the unit tests, they're very sensitive
#                    # to environment.
#                    make quiet-test TEST_Q='-n !906 !530 !564 !584 !1026'
#                popd
#            fi

            # Run 'curl' as a sanity check. Capture just the first line, which
            # should have versions of stuff.
            curlout="$("${stage}"/bin/curl --version | tr -d '\r' | head -n 1)"
            # With -e in effect, any nonzero rc blows up the script --
            # so plain 'expr str : pattern' asserts that str contains pattern.
            # curl version - should be start of line
            expr "$curlout" : "curl $(escape_dots "$version")" > /dev/null
            # libcurl/version
            expr "$curlout" : ".* libcurl/$(escape_dots "$version")" > /dev/null
            # OpenSSL/version
            #expr "$curlout" : ".* OpenSSL/$(escape_dots "$(get_installable_version openssl 3)")" > /dev/null
            # zlib/version
            expr "$curlout" : ".* zlib/" > /dev/null
            # nghttp2/versionx
            #expr "$curlout" : ".* nghttp2/$(escape_dots "$(get_installable_version nghttp2 3)")" > /dev/null

            export LD_LIBRARY_PATH="$saved_path"
        ;;
    esac
    mkdir -p "$stage/LICENSES"
    cp "${CURL_SOURCE_DIR}"/COPYING "$stage/LICENSES/curl.txt"
popd
rm -rf "$CURL_BUILD_DIR"

mkdir -p "$stage"/docs/curl/
cp -a "$top"/README.Linden "$stage"/docs/curl/
