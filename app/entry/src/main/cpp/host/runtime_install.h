/* Runtime installation service: one install per process, state guarded by
   the module mutex.  */
#ifndef OHOS_HOST_RUNTIME_INSTALL_H
#define OHOS_HOST_RUNTIME_INSTALL_H

#include <pthread.h>

#include <mutex>
#include <string>

struct RuntimeInstaller
{
  bool running = false;
  bool done = false;
  std::string error;
  long long files = 0;
  long long bytes = 0;
  long long total = 0;
  pthread_t tid{};
  bool started = false;
  int fd = -1;
  long long offset = 0;
  long long length = 0;
  std::string tar;
  std::string dir;
  std::mutex lock;
};

RuntimeInstaller &HostRuntime ();

int RuntimeBeginInstall (int fd, long long offset, long long length,
                         const std::string &tar, const std::string &dir);
std::string RuntimeStateJson ();
int RuntimePathReady (const std::string &path);
std::string RuntimeBuildId ();
std::string RuntimeReadFile (const std::string &path);
int RuntimeWriteFile (const std::string &path, const std::string &text);
int RuntimeRemoveFile (const std::string &path);
std::string RuntimeLibemacsVersion ();

#endif
