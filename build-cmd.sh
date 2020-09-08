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

[ -f "$ZLIB_INCLUDE"/zlib.h ] || fail "You haven't installed the zlib package yet."
[ -f "$OPENSSL_INCLUDE"/ssl.h ] || fail "You haven't installed the openssl package yet."

LIBCURL_VERSION_HEADER_DIR="${CURL_SOURCE_DIR}"/include/curl
version=$(perl -ne 's/#define LIBCURL_VERSION "([^"]+)"/$1/ && print' "${LIBCURL_VERSION_HEADER_DIR}/curlver.h" | tr -d '\r' )
build=${AUTOBUILD_BUILD_ID:=0}
echo "${version}.${build}" > "${stage}/VERSION.txt"

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
    # On Windows, change '\r\n' to plain '\n': the '\r' is NOT removed by
    # bash, so it becomes part of the string contents, which confuses both
    # scripted comparisons and human readers.
    python -c "from ast import literal_eval
print '.'.join(literal_eval(r'''$pydata''')['version'].split('.')[:${2:-}])" \
    | tr -d '\r'
    set -x
}

# Given an (e.g. version) string possibly containing periods, escape those
# periods with backslashes.
escape_dots ()
{
    echo "${1//./\\.}"
}

mkdir -p "$CURL_BUILD_DIR"

case "$AUTOBUILD_PLATFORM" in
    windows*)
        pushd "${CURL_SOURCE_DIR}"
            load_vsvars

            check_damage "$AUTOBUILD_PLATFORM"
            packages="$(cygpath -m "$stage/packages")"

            if [ "$AUTOBUILD_ADDRSIZE" = 32 ]
            then
                debugtargetname=debug-VC-WIN32
                releasetargetname=VC-WIN32
                batname=do_nasm
            else
                debugtargetname=debug-VC-WIN64A
                releasetargetname=VC-WIN64A
                batname=do_win64a
            fi

            pushd winbuild

                # Debug target.  DLL for SSL, static archives
                # for libcurl and zlib.  (Config created by Linden Lab)
                nmake /f Makefile.vc mode=dll VC=14 WITH_DEVEL="$packages" WITH_NGHTTP2=dll WITH_SSL=dll WITH_ZLIB=dll ENABLE_IPV6=yes ENABLE_IDN=yes GEN_PDB=yes MACHINE=x64 DEBUG=yes

                # Release target.  DLL for SSL, static archives
                # for libcurl and zlib.  (Config created by Linden Lab)
                nmake /f Makefile.vc mode=dll VC=14 WITH_DEVEL="$packages" WITH_NGHTTP2=dll WITH_SSL=dll WITH_ZLIB=dll ENABLE_IPV6=yes ENABLE_IDN=yes GEN_PDB=yes MACHINE=x64 
            popd

            # conditionally run unit tests
            if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                pushd tests
                # Nothin' to do yet

                popd
            fi

            # Stage archives
            mkdir -p "${stage}"/lib/{debug,release}
            cp -a builds/libcurl-vc14-x64-debug-dll-ssl-dll-zlib-dll-ipv6-sspi-nghttp2-dll/bin/*.dll "${stage}"/lib/debug/
            cp -a builds/libcurl-vc14-x64-debug-dll-ssl-dll-zlib-dll-ipv6-sspi-nghttp2-dll/lib/*.{lib,exp,pdb} "${stage}"/lib/debug/
            cp -a builds/libcurl-vc14-x64-release-dll-ssl-dll-zlib-dll-ipv6-sspi-nghttp2-dll/bin/*.dll "${stage}"/lib/release/
            cp -a builds/libcurl-vc14-x64-release-dll-ssl-dll-zlib-dll-ipv6-sspi-nghttp2-dll/lib/*.{lib,exp,pdb} "${stage}"/lib/release/

            # Stage curl.exe and provide .dll's it needs
            mkdir -p "${stage}"/bin
            cp -af "${stage}"/packages/lib/release/*.{dll,pdb} "${stage}"/bin/
            cp -af "${stage}"/lib/release/*.dll "${stage}"/bin/
            chmod +x-w "${stage}"/bin/*.dll   # correct package permissions
            cp -a builds/libcurl-vc14-x64-release-dll-ssl-dll-zlib-dll-ipv6-sspi-nghttp2-dll/bin/curl.exe "${stage}"/bin/

            # Stage headers
            mkdir -p "${stage}"/include
            cp -a builds/libcurl-vc14-x64-release-dll-ssl-dll-zlib-dll-ipv6-sspi-nghttp2-dll/include/curl/ "${stage}"/include/

            # Run 'curl' as a sanity check. Capture just the first line, which
            # should have versions of stuff.
            curlout="$("${stage}"/bin/curl.exe --version | tr -d '\r' | head -n 1)"
            # With -e in effect, any nonzero rc blows up the script --
            # so plain 'expr str : pattern' asserts that str contains pattern.
            # curl version - should be start of line
            expr "$curlout" : "curl $(escape_dots "$version")" #> /dev/null
            # libcurl/version
            expr "$curlout" : ".* libcurl/$(escape_dots "$version")" > /dev/null
            # OpenSSL/version
            expr "$curlout" : ".* OpenSSL/$(escape_dots "$(get_installable_version openssl 3)")" > /dev/null
            # zlib/version
            expr "$curlout" : ".* zlib/$(escape_dots "$(get_installable_version zlib 3)")" > /dev/null
            # nghttp2/version
            expr "$curlout" : ".* nghttp2/$(escape_dots "$(get_installable_version nghttp2 3)")" > /dev/null

            # Clean
            rm -r builds
            popd
    ;;
    
    darwin*)
        pushd "$CURL_BUILD_DIR"
        opts="${TARGET_OPTS:--arch $AUTOBUILD_CONFIGURE_ARCH $LL_BUILD_RELEASE}"
        
        mkdir -p "$stage/lib/release"
        rm -rf Resources/ ../Resources tests/Resources/
        
        # Force libz and openssl static linkage by moving .dylibs out of the way
        trap restore_dylibs EXIT
        for dylib in "$stage"/packages/lib/release/lib{z,crypto,ssl}*.dylib; do
            if [ -f "$dylib" ]; then
                mv "$dylib" "$dylib".disable
            fi
        done
        
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
        
        cmake ../${CURL_SOURCE_DIR} -GXcode -DCMAKE_C_FLAGS:STRING="$opts" \
        -DCMAKE_CXX_FLAGS:STRING="$opts" -D'BUILD_SHARED_LIBS:bool=off' \
        -DENABLE_THREADED_RESOLVER:BOOL=ON \
        -DCMAKE_USE_OPENSSL:BOOL=TRUE \
        -DUSE_NGHTTP2:BOOL=TRUE \
        -DNGHTTP2_INCLUDE_DIR:FILEPATH="$stage/packages/include" \
        -DNGHTTP2_LIBRARY:FILEPATH="$stage/packages/lib/release/libnghttp2.dylib" \
        -D'BUILD_CODEC:bool=off' -DCMAKE_INSTALL_PREFIX=$stage
        
        check_damage "$AUTOBUILD_PLATFORM"
        
        xcodebuild -configuration Release -target libcurl -project CURL.xcodeproj
        xcodebuild -configuration Release -target install -project CURL.xcodeproj
        mkdir -p "$stage/lib/release"
        mv "$stage/lib/libcurl.a" "$stage/lib/release/libcurl.a"
        
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
        
        #            make distclean
        # Again, for dylib dependencies
        # rm -rf Resources/ ../Resources tests/Resources/
        
        rm -rf "$CURL_BUILD_DIR"
        
        popd
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
        unset DISTCC_HOSTS CC CXX CFLAGS CPPFLAGS CXXFLAGS
        
        pushd "$CURL_SOURCE_DIR"
        
        # Default target per --address-size
        opts="${TARGET_OPTS:--m$AUTOBUILD_ADDRSIZE}"
        DEBUG_COMMON_FLAGS="$opts -Og -g -fPIC"
        RELEASE_COMMON_FLAGS="$opts -O3 -g -fPIC -fstack-protector-strong"
        DEBUG_CFLAGS="$DEBUG_COMMON_FLAGS"
        RELEASE_CFLAGS="$RELEASE_COMMON_FLAGS"
        DEBUG_CXXFLAGS="$DEBUG_COMMON_FLAGS -std=c++17"
        RELEASE_CXXFLAGS="$RELEASE_COMMON_FLAGS -std=c++17"
        DEBUG_CPPFLAGS="-DPIC -DNGHTTP2_STATICLIB"
        RELEASE_CPPFLAGS="-DPIC -D_FORTIFY_SOURCE=2 -DNGHTTP2_STATICLIB"
        
        JOBS=`cat /proc/cpuinfo | grep processor | wc -l`
        
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
        for solib in "${stage}"/packages/lib/{release}/lib{z,ssl,crypto}.so*; do
            if [ -f "$solib" ]; then
                mv -f "$solib" "$solib".disable
            fi
        done
        
        mkdir -p "$stage/lib/release"
        mkdir -p "$stage/lib/debug"
        
        # Fix up path for pkgconfig
        if [ -d "$stage/packages/lib/release/pkgconfig" ]; then
            fix_pkgconfig_prefix "$stage/packages"
        fi
        
        OLD_PKG_CONFIG_PATH="${PKG_CONFIG_PATH:-}"
        
        # force regenerate autoconf
        autoreconf -fvi
        
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
        
        # Debug configure and build
        export PKG_CONFIG_PATH="${stage}/packages/lib/debug/pkgconfig:${OLD_PKG_CONFIG_PATH}"
        export LD_LIBRARY_PATH="${stage}"/packages/lib/debug:"$saved_path"
        
        # -g/-O options controled by --enable-debug/-optimize.  Unfortunately,
        # --enable-debug also defines DEBUGBUILD which changes behaviors.
        CFLAGS="$DEBUG_CFLAGS" \
        CXXFLAGS="$DEBUG_CXXFLAGS" \
        CPPFLAGS="$DEBUG_CPPFLAGS -I$stage/packages/include -I$stage/packages/include/zlib" \
        LDFLAGS="-L$stage/packages/lib/debug/" \
        LIBS="-ldl -lpthread" \
        ./configure --disable-debug --disable-curldebug --disable-optimize --enable-shared=no --enable-threaded-resolver \
        --enable-cookies --disable-ldap --disable-ldaps  --without-libssh2 \
        --prefix="\${AUTOBUILD_PACKAGES_DIR}" --libdir="\${prefix}/lib/debug" \
        --with-ssl="$stage"/packages --with-zlib="$stage"/packages --with-nghttp2="$stage"/packages/
        
        check_damage "$AUTOBUILD_PLATFORM"
        make -j$JOBS
        make install DESTDIR="$stage"
        
        # conditionally run unit tests
        if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
            pushd tests
            # We hijack the 'quiet-test' target and redefine it as
            # a no-valgrind test.  Also exclude test 320.  It fails in the
            # 7.41 distribution with our configuration options.
            #
            # Expect problems with the unit tests, they're very sensitive
            # to environment.
            make quiet-test TEST_Q='-n !46 !320'
            popd
        fi
        
        # Run 'curl' as a sanity check. Capture just the first line, which
        # should have versions of stuff.
        curlout="$("${stage}"/bin/curl --version | tr -d '\r' | head -n 1)"
        # With -e in effect, any nonzero rc blows up the script --
        # so plain 'expr str : pattern' asserts that str contains pattern.
        # curl version - should be start of line
        expr "$curlout" : "curl $(escape_dots "$version")" #> /dev/null
        # libcurl/version
        expr "$curlout" : ".* libcurl/$(escape_dots "$version")" > /dev/null
        # OpenSSL/version
        expr "$curlout" : ".* OpenSSL/$(escape_dots "$(get_installable_version openssl 3)")" > /dev/null
        # zlib/version
        expr "$curlout" : ".* zlib/$(escape_dots "$(get_installable_version zlib 3)")" > /dev/null
        # nghttp2/versionx
        expr "$curlout" : ".* nghttp2/$(escape_dots "$(get_installable_version nghttp2 3)")" > /dev/null
        
        make clean || true
        
        # Release configure and build
        export PKG_CONFIG_PATH="$stage/packages/lib/release/pkgconfig:${OLD_PKG_CONFIG_PATH}"
        export LD_LIBRARY_PATH="${stage}"/packages/lib/release:"$saved_path"
        
        CFLAGS="$RELEASE_CFLAGS" \
        CXXFLAGS="$RELEASE_CXXFLAGS" \
        CPPFLAGS="$RELEASE_CPPFLAGS -I$stage/packages/include -I$stage/packages/include/zlib" \
        LDFLAGS="-L$stage/packages/lib/release/" \
        LIBS="-ldl -lpthread" \
        ./configure --disable-curldebug --disable-debug  --enable-optimize --enable-shared=no --enable-threaded-resolver \
        --enable-cookies --disable-ldap --disable-ldaps --without-libssh2 \
        --prefix="\${AUTOBUILD_PACKAGES_DIR}" --libdir="\${prefix}/lib/release" \
        --with-ssl="$stage"/packages --with-zlib="$stage"/packages --with-nghttp2="$stage"/packages/

        check_damage "$AUTOBUILD_PLATFORM"
        make -j$JOBS
        make install DESTDIR="$stage"
        
        # conditionally run unit tests
        if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
            pushd tests
            make quiet-test TEST_Q='-n !46 !320'
            popd
        fi
        
        # Run 'curl' as a sanity check. Capture just the first line, which
        # should have versions of stuff.
        curlout="$("${stage}"/bin/curl --version | tr -d '\r' | head -n 1)"
        # With -e in effect, any nonzero rc blows up the script --
        # so plain 'expr str : pattern' asserts that str contains pattern.
        # curl version - should be start of line
        expr "$curlout" : "curl $(escape_dots "$version")" #> /dev/null
        # libcurl/version
        expr "$curlout" : ".* libcurl/$(escape_dots "$version")" > /dev/null
        # OpenSSL/version
        expr "$curlout" : ".* OpenSSL/$(escape_dots "$(get_installable_version openssl 3)")" > /dev/null
        # zlib/version
        expr "$curlout" : ".* zlib/$(escape_dots "$(get_installable_version zlib 3)")" > /dev/null
        # nghttp2/version
        expr "$curlout" : ".* nghttp2/$(escape_dots "$(get_installable_version nghttp2 3)")" > /dev/null
        
        make clean || true
        
        export LD_LIBRARY_PATH="$saved_path"
        popd
        
    ;;
esac

mkdir -p "$stage/LICENSES"
cp "${CURL_SOURCE_DIR}"/COPYING "$stage/LICENSES/curl.txt"

mkdir -p "$stage"/docs/curl/
cp -a "$top"/README.Linden "$stage"/docs/curl/
