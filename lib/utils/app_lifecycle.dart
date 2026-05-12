import 'dart:io';

void closeApp() {
  Process.run('taskkill', ['/F', '/IM', 'kami-dl.exe']);
  exit(0);
}
