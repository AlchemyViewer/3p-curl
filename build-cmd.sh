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

if [ "$OSTYPE" = "cygwin" ] ; then
    autobuild="$(cygpath -u $AUTOBUILD)"
else
    autobuild="$AUTOBUILD"
fi

CURL_SOURCE_DIR="curl"
CURL_BUILD_DIR="build"

top="$(pwd)"
stage="$(pwd)/stage"

# load autobuild provided shell functions and variables
source_environment_tempfile="$stage/source_environment.sh"
"$autobuild" source_environment > "$source_environment_tempfile"
. "$source_environment_tempfile"

ZLIB_INCLUDE="${stage}"/packages/include/zlib
OPENSSL_INCLUDE="${stage}"/packages/include/openssl

LIBCURL_VERSION_HEADER_DIR="${CURL_SOURCE_DIR}"/include/curl
version=$(perl -ne 's/#define LIBCURL_VERSION "([^"]+)"/$1/ && print' "${LIBCURL_VERSION_HEADER_DIR}/curlver.h" | tr -d '\r' )
echo "${version}" > "${stage}/VERSION.txt"

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
    # On Windows, change '\r\n' to plain '\n': the '\r' is NOT removed by
    # bash, so it becomes part of the string contents, which confuses both
    # scripted comparisons and human readers.
    python3 -c "from ast import literal_eval
print('.'.join(literal_eval(r'''$pydata''')['version'].split('.')[:${2:-}]))" \
    | tr -d '\r'
    set -x
}

# Given an (e.g. version) string possibly containing periods, escape those
# periods with backslashes.
escape_dots ()
{
    echo "${1//./\\.}"
}

pushd "$CURL_SOURCE_DIR"
    case "$AUTOBUILD_PLATFORM" in
        windows*)
            load_vsvars

            packages="$(cygpath -m "$stage/packages")"

            if [ "$AUTOBUILD_ADDRSIZE" = 32 ]
            then
                targetarch=x86
            else
                targetarch=x64
            fi

            pushd winbuild
                # Debug target.  static for SSL, libcurl, nghttp2, and zlib
                nmake /f Makefile.vc mode=static VC=14 WITH_DEVEL="$packages" WITH_NGHTTP2=static WITH_SSL=static WITH_ZLIB=static ENABLE_IPV6=yes ENABLE_IDN=yes GEN_PDB=no MACHINE=$targetarch DEBUG=yes

                # Release target.  static for SSL, libcurl, nghttp2, and zlib
                nmake /f Makefile.vc mode=static VC=14 WITH_DEVEL="$packages" WITH_NGHTTP2=static WITH_SSL=static WITH_ZLIB=static ENABLE_IPV6=yes ENABLE_IDN=yes GEN_PDB=no MACHINE=$targetarch
            popd

            # conditionally run unit tests
            if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                pushd tests
                # Nothin' to do yet

                popd
            fi

            # Stage archives
            mkdir -p "${stage}"/lib/{debug,release}
            cp -a builds/libcurl-vc14-$targetarch-debug-static-ssl-static-zlib-static-ipv6-sspi-nghttp2-static/lib/libcurl_a_debug.lib "${stage}"/lib/debug/libcurld.lib
            cp -a builds/libcurl-vc14-$targetarch-release-static-ssl-static-zlib-static-ipv6-sspi-nghttp2-static/lib/libcurl_a.lib "${stage}"/lib/release/libcurl.lib

            # Stage curl.exe
            mkdir -p "${stage}"/bin
            cp -a builds/libcurl-vc14-$targetarch-release-static-ssl-static-zlib-static-ipv6-sspi-nghttp2-static/bin/curl.exe "${stage}"/bin/

            # Stage headers
            mkdir -p "${stage}"/include
            cp -a builds/libcurl-vc14-$targetarch-release-static-ssl-static-zlib-static-ipv6-sspi-nghttp2-static/include/curl/ "${stage}"/include/

            # # Run 'curl' as a sanity check. Capture just the first line, which
            # # should have versions of stuff.
            # curlout="$("${stage}"/bin/curl.exe --version | tr -d '\r' | head -n 1)"
            # # With -e in effect, any nonzero rc blows up the script --
            # # so plain 'expr str : pattern' asserts that str contains pattern.
            # # curl version - should be start of line
            # expr "$curlout" : "curl $(escape_dots "$version")" #> /dev/null
            # # libcurl/version
            # expr "$curlout" : ".* libcurl/$(escape_dots "$version")" > /dev/null
            # # OpenSSL/version
            # expr "$curlout" : ".* OpenSSL/$(escape_dots "$(get_installable_version openssl 3)")" > /dev/null
            # # zlib/version
            # expr "$curlout" : ".* zlib/1.3.1.zlib-ng" > /dev/null
            # # nghttp2/version
            # expr "$curlout" : ".* nghttp2/$(escape_dots "$(get_installable_version nghttp2 3)")" > /dev/null

            # Clean
            rm -r builds
        ;;
    
        darwin*)
            # Force libz and openssl static linkage by moving .dylibs out of the way
            trap restore_dylibs EXIT
            for dylib in "$stage"/packages/lib/release/lib{z,crypto,ssl}*.dylib; do
                if [ -f "$dylib" ]; then
                    mv "$dylib" "$dylib".disable
                fi
            done

            # Setup build flags
            C_OPTS_X86="-arch x86_64 $LL_BUILD_RELEASE_CFLAGS -DNGHTTP2_STATICLIB"
            C_OPTS_ARM64="-arch arm64 $LL_BUILD_RELEASE_CFLAGS -DNGHTTP2_STATICLIB"
            CXX_OPTS_X86="-arch x86_64 $LL_BUILD_RELEASE_CXXFLAGS -DNGHTTP2_STATICLIB"
            CXX_OPTS_ARM64="-arch arm64 $LL_BUILD_RELEASE_CXXFLAGS -DNGHTTP2_STATICLIB"
            LINK_OPTS_X86="-arch x86_64 $LL_BUILD_RELEASE_LINKER"
            LINK_OPTS_ARM64="-arch arm64 $LL_BUILD_RELEASE_LINKER"

            # deploy target
            export MACOSX_DEPLOYMENT_TARGET=${LL_BUILD_DARWIN_BASE_DEPLOY_TARGET}

            mkdir -p "build_release_x86"
            pushd "build_release_x86"
                CFLAGS="$C_OPTS_X86" \
                CXXFLAGS="$CXX_OPTS_X86" \
                LDFLAGS="$LINK_OPTS_X86" \
                cmake .. -GNinja -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS:BOOL=OFF \
                    -DCMAKE_C_FLAGS="$C_OPTS_X86" \
                    -DCMAKE_CXX_FLAGS="$CXX_OPTS_X86" \
                    -DCMAKE_OSX_ARCHITECTURES:STRING=x86_64 \
                    -DCMAKE_OSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET} \
                    -DCMAKE_MACOSX_RPATH=YES \
                    -DCMAKE_INSTALL_PREFIX="$stage/release_x86" \
                    -DENABLE_THREADED_RESOLVER:BOOL=ON \
                    -DENABLE_ARES:BOOL=OFF \
                    -DCMAKE_USE_OPENSSL:BOOL=TRUE \
                    -DZLIB_LIBRARIES="${stage}/packages/lib/release/libz.a" \
                    -DZLIB_INCLUDE_DIRS="${stage}/packages/include/zlib" \
                    -DNGHTTP2_LIBRARIES="${stage}/packages/lib/release/libnghttp2.a" \
                    -DNGHTTP2_INCLUDE_DIRS="${stage}/packages/include/nghttp2" \
                    -DOPENSSL_LIBRARIES="${stage}/packages/lib/release/libcrypto.a;${stage}/packages/lib/release/libssl.a" \
                    -DOPENSSL_INCLUDE_DIR="${stage}/packages/include/"

                cmake --build . --config Release
                cmake --install . --config Release

                # conditionally run unit tests
                if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                    ctest -C Release
                fi

                # Run 'curl' as a sanity check. Capture just the first line, which
                # should have versions of stuff.
                curlout="$("${stage}"/release_x86/bin/curl --version | tr -d '\r' | head -n 1)"
                # With -e in effect, any nonzero rc blows up the script --
                # so plain 'expr str : pattern' asserts that str contains pattern.
                # curl version - should be start of line
                expr "$curlout" : "curl $(escape_dots "$version")" > /dev/null
                # libcurl/version
                expr "$curlout" : ".* libcurl/$(escape_dots "$version")" > /dev/null
                # OpenSSL/version
                expr "$curlout" : ".* OpenSSL/$(escape_dots "$(get_installable_version openssl 3)")" > /dev/null
                # zlib/version
                expr "$curlout" : ".* zlib/1.3.1.zlib-ng" > /dev/null
                # nghttp2/versionx
                expr "$curlout" : ".* nghttp2/$(escape_dots "$(get_installable_version nghttp2 3)")" > /dev/null
            popd

            mkdir -p "build_release_arm64"
            pushd "build_release_arm64"
                CFLAGS="$C_OPTS_ARM64" \
                CXXFLAGS="$CXX_OPTS_ARM64" \
                LDFLAGS="$LINK_OPTS_ARM64" \
                cmake .. -GNinja -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS:BOOL=OFF \
                    -DCMAKE_C_FLAGS="$C_OPTS_ARM64" \
                    -DCMAKE_CXX_FLAGS="$CXX_OPTS_ARM64" \
                    -DCMAKE_OSX_ARCHITECTURES:STRING=arm64 \
                    -DCMAKE_OSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET} \
                    -DCMAKE_MACOSX_RPATH=YES \
                    -DCMAKE_INSTALL_PREFIX="$stage/release_arm64" \
                    -DENABLE_THREADED_RESOLVER:BOOL=ON \
                    -DENABLE_ARES:BOOL=OFF \
                    -DCMAKE_USE_OPENSSL:BOOL=ON \
                    -DZLIB_LIBRARIES="${stage}/packages/lib/release/libz.a" \
                    -DZLIB_INCLUDE_DIRS="${stage}/packages/include/zlib" \
                    -DNGHTTP2_LIBRARIES="${stage}/packages/lib/release/libnghttp2.a" \
                    -DNGHTTP2_INCLUDE_DIRS="${stage}/packages/include/nghttp2" \
                    -DOPENSSL_LIBRARIES="${stage}/packages/lib/release/libcrypto.a;${stage}/packages/lib/release/libssl.a" \
                    -DOPENSSL_INCLUDE_DIR="${stage}/packages/include/"

                cmake --build . --config Release
                cmake --install . --config Release

                # conditionally run unit tests
                if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                    ctest -C Release
                fi

                # Run 'curl' as a sanity check. Capture just the first line, which
                # should have versions of stuff.
                curlout="$("${stage}"/release_arm64/bin/curl --version | tr -d '\r' | head -n 1)"
                # With -e in effect, any nonzero rc blows up the script --
                # so plain 'expr str : pattern' asserts that str contains pattern.
                # curl version - should be start of line
                expr "$curlout" : "curl $(escape_dots "$version")" > /dev/null || true
                # libcurl/version
                expr "$curlout" : ".* libcurl/$(escape_dots "$version")" > /dev/null || true
                # OpenSSL/version
                expr "$curlout" : ".* OpenSSL/$(escape_dots "$(get_installable_version openssl 3)")" > /dev/null || true
                # zlib/version
                expr "$curlout" : ".* zlib/1.3.1.zlib-ng" > /dev/null || true
                # nghttp2/versionx
                expr "$curlout" : ".* nghttp2/$(escape_dots "$(get_installable_version nghttp2 3)")" > /dev/null || true
            popd

            # setup staging dirs
            mkdir -p "$stage/include/curl"
            mkdir -p "$stage/lib/release"

            # create fat libraries
            lipo -create ${stage}/release_x86/lib/libcurl.a ${stage}/release_arm64/lib/libcurl.a -output ${stage}/lib/release/libcurl.a

            # copy headers
            mv $stage/release_x86/include/curl/* $stage/include/curl
        ;;
    
        linux*)
            # Linux build environment at Linden comes pre-polluted with stuff that can
            # seriously damage 3rd-party builds.  Environmental garbage you can expect
            # includes:
            #
            #    DISTCC_POTENTIAL_HOSTS     arch           root        CXXFLAGS
            #    DISTCC_LOCATION            top            branch      CC
            #    DISTCC_HOSTS               build_name     suffix      CXX
            #    LSDISTCC_ARGS              repo           prefix      CFLAGS
            #    cxx_version                AUTOBUILD      SIGN        CPPFLAGS
            #
            # So, clear out bits that shouldn't affect our configure-directed build
            # but which do nonetheless.
            #
            unset DISTCC_HOSTS CFLAGS CPPFLAGS CXXFLAGS

            # Default target per --address-size
            opts_c="${TARGET_OPTS:--m$AUTOBUILD_ADDRSIZE $LL_BUILD_RELEASE_CFLAGS -DNGHTTP2_STATICLIB}"
            opts_cxx="${TARGET_OPTS:--m$AUTOBUILD_ADDRSIZE $LL_BUILD_RELEASE_CXXFLAGS -DNGHTTP2_STATICLIB}"
            
            # Handle any deliberate platform targeting
            if [ -z "${TARGET_CPPFLAGS:-}" ]; then
                # Remove sysroot contamination from build environment
                unset CPPFLAGS
            else
                # Incorporate special pre-processing flags
                export CPPFLAGS="$TARGET_CPPFLAGS"
            fi

            mkdir -p "build_release"
            pushd "build_release"
                CFLAGS="$opts_c" \
                CXXFLAGS="$opts_cxx" \
                 cmake .. -GNinja -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS:BOOL=OFF -DBUILD_TESTING=ON \
                    -DCMAKE_C_FLAGS="$opts_c" \
                    -DCMAKE_CXX_FLAGS="$opts_cxx" \
                    -DCMAKE_INSTALL_PREFIX="$stage" \
                    -DENABLE_THREADED_RESOLVER:BOOL=ON \
                    -DENABLE_ARES:BOOL=OFF \
                    -DCMAKE_USE_OPENSSL:BOOL=TRUE \
                    -DZLIB_LIBRARIES="${stage}/packages/lib/libz.a" \
                    -DZLIB_INCLUDE_DIRS="${stage}/packages/include/zlib" \
                    -DNGHTTP2_LIBRARIES="${stage}/packages/lib/libnghttp2.a" \
                    -DNGHTTP2_INCLUDE_DIRS="${stage}/packages/include/nghttp2" \
                    -DOPENSSL_LIBRARIES="${stage}/packages/lib/libcrypto.a;${stage}/packages/lib/libssl.a;dl" \
                    -DOPENSSL_INCLUDE_DIR="${stage}/packages/include/"

                cmake --build . --config Release
                cmake --install . --config Release

                # conditionally run unit tests
                # if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                #     ctest -C Release
                # fi

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
                expr "$curlout" : ".* OpenSSL/$(escape_dots "$(get_installable_version openssl 3)")" > /dev/null
                # zlib/version
                expr "$curlout" : ".* zlib/1.3.1.zlib-ng" > /dev/null
                # nghttp2/versionx
                expr "$curlout" : ".* nghttp2/$(escape_dots "$(get_installable_version nghttp2 3)")" > /dev/null
            popd
        ;;
    esac

    mkdir -p "$stage/LICENSES"
    cp COPYING "$stage/LICENSES/curl.txt"
popd
