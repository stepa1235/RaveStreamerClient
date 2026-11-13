import 'dart:io';

String globalAppVersion = '1.1.1';

Future<void> installWindowsUpdate(File archive) async {
  final directory = archive.parent;
  final executable = File(Platform.resolvedExecutable);
  final script = File('${directory.path}\\install.ps1');
  await script.writeAsString(_installScript, flush: true);
  final systemRoot = Platform.environment['SystemRoot'] ?? r'C:\Windows';
  await Process.start(
    '$systemRoot\\System32\\WindowsPowerShell\\v1.0\\powershell.exe',
    [
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-WindowStyle',
      'Hidden',
      '-File',
      script.path,
      '-Archive',
      archive.path,
      '-Executable',
      executable.path,
      '-AppProcessId',
      '$pid',
    ],
    mode: ProcessStartMode.detached,
  );
  exit(0);
}

const _installScript = r'''
param([string]$Archive, [string]$Executable, [int]$AppProcessId)
$ErrorActionPreference = 'Stop'
$work = Split-Path -Parent $Archive
$destination = Split-Path -Parent $Executable
$staging = Join-Path $work 'staging'
$backup = Join-Path $work 'backup'
$replaced = [System.Collections.Generic.List[string]]::new()
$added = [System.Collections.Generic.List[string]]::new()
$installed = $false

try {
    Expand-Archive -LiteralPath $Archive -DestinationPath $staging
    $exeName = Split-Path -Leaf $Executable
    if (!(Test-Path -LiteralPath (Join-Path $staging $exeName) -PathType Leaf) -or
        !(Test-Path -LiteralPath (Join-Path $staging 'flutter_windows.dll') -PathType Leaf) -or
        !(Test-Path -LiteralPath (Join-Path $staging 'data') -PathType Container)) {
        throw 'Unexpected Luna archive layout'
    }
    if (Get-Process -Id $AppProcessId -ErrorAction SilentlyContinue) {
        Wait-Process -Id $AppProcessId -Timeout 30 -ErrorAction Stop
    }
    foreach ($file in (Get-ChildItem -LiteralPath $staging -File -Recurse)) {
        $relative = $file.FullName.Substring($staging.Length + 1)
        $target = Join-Path $destination $relative
        if (Test-Path -LiteralPath $target -PathType Container) {
            throw "Update file conflicts with an existing directory: $relative"
        }
        if (Test-Path -LiteralPath $target -PathType Leaf) {
            $saved = Join-Path $backup $relative
            [IO.Directory]::CreateDirectory((Split-Path -Parent $saved)) | Out-Null
            Copy-Item -LiteralPath $target -Destination $saved -Force
            $replaced.Add($relative)
        } else {
            $added.Add($relative)
        }
        [IO.Directory]::CreateDirectory((Split-Path -Parent $target)) | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $target -Force
    }
    Start-Process -FilePath $Executable -WorkingDirectory $destination
    $installed = $true
} catch {
    $errorText = $_ | Out-String
    foreach ($relative in $replaced) {
        try {
            Copy-Item -LiteralPath (Join-Path $backup $relative) -Destination (Join-Path $destination $relative) -Force
        } catch {
            $errorText += $_ | Out-String
        }
    }
    foreach ($relative in $added) {
        $target = Join-Path $destination $relative
        if (Test-Path -LiteralPath $target -PathType Leaf) {
            Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
        }
    }
    $log = Join-Path $work 'update-error.log'
    $errorText | Set-Content -LiteralPath $log -Encoding UTF8
    if (!(Get-Process -Id $AppProcessId -ErrorAction SilentlyContinue)) {
        Start-Process -FilePath $Executable -WorkingDirectory $destination -ErrorAction SilentlyContinue
    }
    Add-Type -AssemblyName PresentationFramework
    [System.Windows.MessageBox]::Show("Luna update failed. Details: $log", 'Luna') | Out-Null
}
if ($installed) {
    Remove-Item -LiteralPath $Archive -Force -ErrorAction SilentlyContinue
    foreach ($folder in @($staging, $backup)) {
        if ((Split-Path -Parent $folder) -eq $work -and (Test-Path -LiteralPath $folder)) {
            Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
''';
