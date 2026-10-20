// jdtls run with java itself. Mason links the package's `bin/jdtls`, a
// Python script (eclipse.jdt.ls' jdtls.py) that finds the launcher jar and
// the platform's configuration and starts java: without python3 (`python`
// on Windows, often the Store's stub there), the server never starts and
// Java has no definitions nor diagnostics. These do what it does, in the
// shell and cmd instead, and say plainly when java is missing or too old.

/// The Java jdtls needs: the release it is built for.
const jdtlsJavaVersion = 21;

/// The wrapper starting jdtls from its package folder (the wrapper's
/// parent's parent, as mason's other wrappers find it): `cmd` on Windows,
/// `sh` elsewhere.
String jdtlsLauncher({required bool windows}) => windows ? _windows : _posix;

// jdtls.py's arguments: its shared configuration read only, its workspace
// data in the temporary folder by the project (its folder here, by name
// there), Lombok's agent with mason's lombok.jar.
const _jvmArguments =
    '-Declipse.application=org.eclipse.jdt.ls.core.id1 '
    '-Dosgi.bundles.defaultStartLevel=4 '
    '-Declipse.product=org.eclipse.jdt.ls.core.product '
    '-Dosgi.checkConfiguration=true '
    '-Dosgi.sharedConfiguration.area.readOnly=true '
    '-Dosgi.configuration.cascaded=true '
    '-Xms1G --add-modules=ALL-SYSTEM '
    '--add-opens java.base/java.util=ALL-UNNAMED '
    '--add-opens java.base/java.lang=ALL-UNNAMED';

const _posix =
    '''#!/bin/sh
dir="\$(cd "\$(dirname "\$0")/.." && pwd)"
if [ -n "\$JAVA_HOME" ]; then
  java="\$JAVA_HOME/bin/java"
elif [ -x /usr/libexec/java_home ] && home="\$(/usr/libexec/java_home -v $jdtlsJavaVersion+ 2>/dev/null)"; then
  java="\$home/bin/java"
else
  java=java
fi
version="\$("\$java" -version 2>&1 | sed -n 's/.*version "\\([0-9]*\\).*/\\1/p' | head -n 1)"
if [ -z "\$version" ] || [ "\$version" -lt $jdtlsJavaVersion ]; then
  echo "jdtls needs Java $jdtlsJavaVersion or newer (a JDK $jdtlsJavaVersion+)\${version:+, not Java \$version}: install one, and set JAVA_HOME to it." >&2
  exit 1
fi
case "\$(uname -s)" in
  Darwin) config=config_mac ;;
  *) config=config_linux ;;
esac
case "\$(uname -m)" in
  arm64 | aarch64) [ -d "\$dir/\${config}_arm" ] && config="\${config}_arm" ;;
esac
launcher="\$(ls "\$dir"/plugins/org.eclipse.equinox.launcher_*.jar 2>/dev/null | head -n 1)"
if [ -z "\$launcher" ]; then
  echo "jdtls is not installed whole: no launcher in \$dir/plugins. Install it again." >&2
  exit 1
fi
data="\${TMPDIR:-/tmp}/jdtls-\$(pwd | cksum | cut -d ' ' -f 1)"
if [ -f "\$dir/lombok.jar" ]; then
  exec "\$java" $_jvmArguments -Dosgi.sharedConfiguration.area="\$dir/\$config" -javaagent:"\$dir/lombok.jar" -jar "\$launcher" -data "\$data" "\$@"
fi
exec "\$java" $_jvmArguments -Dosgi.sharedConfiguration.area="\$dir/\$config" -jar "\$launcher" -data "\$data" "\$@"
''';

const _windows =
    '@echo off\r\n'
    'setlocal\r\n'
    'set "dir=%~dp0.."\r\n'
    'set "java=java"\r\n'
    // With its `.exe`, cmd keeps a quoted path with spaces quoted.
    'if defined JAVA_HOME set "java=%JAVA_HOME%\\bin\\java.exe"\r\n'
    'set "version="\r\n'
    'for /f "tokens=3" %%v in (\'"%java%" -version 2^>^&1 ^| findstr /i version\') do if not defined version set "version=%%~v"\r\n'
    'for /f "delims=." %%m in ("%version%") do set "major=%%m"\r\n'
    'if not defined major set "major=0"\r\n'
    'if %major% LSS $jdtlsJavaVersion (\r\n'
    '  echo jdtls needs Java $jdtlsJavaVersion or newer ^(a JDK $jdtlsJavaVersion+^), not "%version%": install one, and set JAVA_HOME to it. 1>&2\r\n'
    '  exit /b 1\r\n'
    ')\r\n'
    'set "launcher="\r\n'
    'for %%f in ("%dir%\\plugins\\org.eclipse.equinox.launcher_*.jar") do set "launcher=%%~ff"\r\n'
    'if not defined launcher (\r\n'
    '  echo jdtls is not installed whole: no launcher in %dir%\\plugins. Install it again. 1>&2\r\n'
    '  exit /b 1\r\n'
    ')\r\n'
    'for %%i in ("%CD%") do set "name=%%~nxi"\r\n'
    'set "lombok="\r\n'
    'if exist "%dir%\\lombok.jar" set lombok="-javaagent:%dir%\\lombok.jar"\r\n'
    '"%java%" $_jvmArguments -Dosgi.sharedConfiguration.area="%dir%\\config_win" %lombok% -jar "%launcher%" -data "%TEMP%\\jdtls-%name%" %*\r\n';
