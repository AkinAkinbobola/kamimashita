$root = $PSScriptRoot

# Build kami-dl
Push-Location "$root\kami-dl"
go build -o "$root\kami-dl\kami-dl.exe" .
Pop-Location

# Build Flutter
Push-Location $root
flutter build windows --release

# Copy kami-dl into release
Copy-Item "$root\kami-dl\kami-dl.exe" "$root\build\windows\x64\runner\Release\kami-dl.exe"

# Build installer
$env:APP_VERSION = "2.0.0"
iscc installer.iss

Write-Host "Build complete - installer at build\installer\"