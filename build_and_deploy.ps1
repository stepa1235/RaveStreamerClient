cd C:\RaveStreamer\client
flutter build windows
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

cd C:\RaveStreamer\client_android
flutter build apk --release
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

cd C:\RaveStreamer
Compress-Archive -Path "C:\RaveStreamer\client\build\windows\x64\runner\Release\*" -DestinationPath "C:\RaveStreamer\RaveStreamer-Windows.zip" -Force
Copy-Item -Path "C:\RaveStreamer\client_android\build\app\outputs\flutter-apk\app-release.apk" -Destination "C:\RaveStreamer\RaveStreamer.apk" -Force

node "C:\RaveStreamer\deploy.js"
