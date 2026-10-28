#include "host_api.h"

#include "runtime_install.h"
#include "host_context.h"

#include <cstdio>
#include <cstring>
#include <ctime>
#include <string>
#include <vector>

#include <dirent.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <link.h>
#include <pthread.h>
#include <sys/stat.h>
#include <unistd.h>
#include <zlib.h>

#define OHOS_LOG_TAG "emacs-hmos"
#include "gui_log.h"

namespace
{

/* Runtime installation service.  One instance lives for the process; the
   fields are guarded by g_lock below.  */
RuntimeInstaller &g_install = HostContext::Get ().runtime;

RuntimeInstaller &
HostRuntime ()
{
  return g_install;
}

std::string
TrimField (const char *p, size_t n)
{
  size_t len = 0;
  while (len < n && p[len])
    len++;
  return std::string (p, len);
}

long long
ParseOctal (const char *p, size_t n)
{
  if (n && (p[0] & 0x80))
    {
      long long v = p[0] & 0x7f;
      for (size_t i = 1; i < n; i++)
        v = (v << 8) | (unsigned char) p[i];
      return v;
    }
  long long v = 0;
  for (size_t i = 0; i < n; i++)
    {
      if (p[i] < '0' || p[i] > '7')
        continue;
      v = v * 8 + (p[i] - '0');
    }
  return v;
}

std::string
JoinPath (const std::string &a, const std::string &b)
{
  if (a.empty ())
    return b;
  if (a.back () == '/')
    return a + b;
  return a + "/" + b;
}

bool
MakeDirs (const std::string &path)
{
  std::string cur;
  size_t i = 0;
  if (!path.empty () && path[0] == '/')
    {
      cur = "/";
      i = 1;
    }
  while (i <= path.size ())
    {
      size_t slash = path.find ('/', i);
      if (slash == std::string::npos)
        slash = path.size ();
      if (slash > i)
        {
          cur = JoinPath (cur, path.substr (i, slash - i));
          if (mkdir (cur.c_str (), 0755) < 0 && errno != EEXIST)
            return false;
        }
      i = slash + 1;
      if (i > path.size ())
        break;
    }
  return true;
}

std::string
ParentDir (const std::string &path)
{
  size_t slash = path.rfind ('/');
  if (slash == std::string::npos)
    return "";
  return path.substr (0, slash);
}

bool
SafeName (const std::string &name)
{
  if (name.empty () || name[0] == '/')
    return false;
  if (name.find ("..") != std::string::npos)
    return false;
  return true;
}

/* Read exactly N bytes from a gzFile, unless at end.  */
ssize_t
ReadAll (gzFile gz, char *buf, ssize_t want)
{
  ssize_t got = 0;
  while (got < want)
    {
      int n = gzread (gz, buf + got, (unsigned) (want - got));
      if (n <= 0)
        break;
      got += n;
    }
  return got;
}

/* Remove PATH recursively (best effort).

   The runtime tarball is the whole truth for lisp/leim/etc/terminfo, but
   extraction only overwrites: a file that the tarball no longer ships (for
   example lisp/frame.elc after we started overlaying lisp/frame.el) would
   stay behind and `load' would keep preferring the stale byte-code.  */
void
RemoveTree (const std::string &path)
{
  struct stat st;
  if (lstat (path.c_str (), &st) != 0)
    return;
  if (!S_ISDIR (st.st_mode))
    {
      unlink (path.c_str ());
      return;
    }
  DIR *d = opendir (path.c_str ());
  if (d)
    {
      struct dirent *entry;
      while ((entry = readdir (d)) != nullptr)
        {
          std::string name = entry->d_name;
          if (name == "." || name == "..")
            continue;
          RemoveTree (path + "/" + name);
        }
      closedir (d);
    }
  rmdir (path.c_str ());
}

int
ExtractTarGz (const std::string &src, const std::string &dest, std::string &err)
{
  gzFile gz = gzopen (src.c_str (), "rb");
  if (!gz)
    {
      err = std::string ("gzopen: ") + strerror (errno);
      return -1;
    }

  char header[512];
  std::string longname;
  std::string paxpath;
  char buf[65536];
  int rc = 0;

  while (true)
    {
      ssize_t n = ReadAll (gz, header, 512);
      if (n != 512)
        break;
      bool zero = true;
      for (int i = 0; i < 512; i++)
        if (header[i])
          {
            zero = false;
            break;
          }
      if (zero)
        break;

      std::string name = TrimField (header, 100);
      std::string prefix = TrimField (header + 345, 155);
      if (!prefix.empty ())
        name = prefix + "/" + name;
      long long size = ParseOctal (header + 124, 12);
      char type = header[156];
      std::string linkname = TrimField (header + 157, 100);

      long long padded = (size + 511) & ~511LL;

      if (type == 'L')
        {
          longname.resize (size);
          ReadAll (gz, &longname[0], size);
          gzseek (gz, padded - size, SEEK_CUR);
          continue;
        }
      if (type == 'x')
        {
          std::string data;
          data.resize (size);
          ReadAll (gz, &data[0], size);
          gzseek (gz, padded - size, SEEK_CUR);
          size_t pos = 0;
          while (pos < data.size ())
            {
              size_t sp = data.find (' ', pos);
              if (sp == std::string::npos)
                break;
              long long reclen = atoll (data.c_str () + pos);
              if (reclen <= 0 || pos + reclen > data.size ())
                break;
              std::string rec = data.substr (sp + 1, pos + reclen - sp - 2);
              if (rec.compare (0, 5, "path=") == 0)
                paxpath = rec.substr (5);
              pos += reclen;
            }
          continue;
        }

      if (!longname.empty ())
        {
          name = longname;
          longname.clear ();
        }
      if (!paxpath.empty ())
        {
          name = paxpath;
          paxpath.clear ();
        }

      if (!SafeName (name))
        {
          gzseek (gz, padded, SEEK_CUR);
          continue;
        }

      std::string outpath = JoinPath (dest, name);

      if (type == '5')
        {
          MakeDirs (outpath);
          gzseek (gz, padded, SEEK_CUR);
          continue;
        }
      if (type == '2')
        {
          if (!ParentDir (outpath).empty ())
            MakeDirs (ParentDir (outpath));
          symlink (linkname.c_str (), outpath.c_str ());
          gzseek (gz, padded, SEEK_CUR);
          continue;
        }
      if (type != '0' && type != 0)
        {
          gzseek (gz, padded, SEEK_CUR);
          continue;
        }

      if (!ParentDir (outpath).empty () && !MakeDirs (ParentDir (outpath)))
        {
          err = std::string ("mkdir: ") + strerror (errno);
          rc = -1;
          break;
        }

      long long mode = ParseOctal (header + 100, 8) & 0777;
      int fd = open (outpath.c_str (), O_WRONLY | O_CREAT | O_TRUNC,
                     mode ? mode : 0644);
      if (fd < 0)
        {
          err = std::string ("open ") + outpath + ": " + strerror (errno);
          rc = -1;
          break;
        }

      long long left = size;
      while (left > 0)
        {
          int want
              = (int) (left < (long long) sizeof buf ? left
                                                     : (long long) sizeof buf);
          int got = gzread (gz, buf, want);
          if (got <= 0)
            break;
          if (write (fd, buf, got) != got)
            {
              err = std::string ("write ") + outpath + ": " + strerror (errno);
              close (fd);
              rc = -1;
              break;
            }
          left -= got;
          g_install.bytes += got;
        }
      close (fd);
      if (rc != 0)
        break;
      if (left > 0)
        {
          err = std::string ("truncated ") + outpath;
          rc = -1;
          break;
        }
      long long pad = padded - size;
      while (pad > 0)
        {
          int want
              = (int) (pad < (long long) sizeof buf ? pad
                                                    : (long long) sizeof buf);
          int got = gzread (gz, buf, want);
          if (got <= 0)
            break;
          pad -= got;
        }
      g_install.files++;
    }

  gzclose (gz);
  return rc;
}

void
TouchElc (const std::string &dir)
{
  DIR *d = opendir (dir.c_str ());
  if (!d)
    return;
  struct dirent *e;
  while ((e = readdir (d)) != nullptr)
    {
      if (!strcmp (e->d_name, ".") || !strcmp (e->d_name, ".."))
        continue;
      std::string p = dir + "/" + e->d_name;
      struct stat st;
      if (lstat (p.c_str (), &st) != 0)
        continue;
      if (S_ISDIR (st.st_mode))
        TouchElc (p);
      else if (S_ISREG (st.st_mode) && p.size () > 4
               && p.compare (p.size () - 4, 4, ".elc") == 0)
        {
          struct timespec times[2];
          times[0].tv_sec = 0;
          times[0].tv_nsec = UTIME_NOW;
          times[1].tv_sec = 0;
          times[1].tv_nsec = UTIME_NOW;
          utimensat (AT_FDCWD, p.c_str (), times, 0);
        }
    }
  closedir (d);
}

void *
InstallThread (void *)
{
  std::string err;

  /* Copy the archive out of the HAP raw file descriptor.  */
  int out = open (g_install.tar.c_str (), O_WRONLY | O_CREAT | O_TRUNC, 0644);
  if (out < 0)
    {
      g_install.lock.lock ();
      g_install.error = std::string ("open tar: ") + strerror (errno);
      g_install.running = false;
      g_install.done = true;
      g_install.lock.unlock ();
      return nullptr;
    }

  long long done = 0;
  char buf[65536];
  while (done < g_install.length)
    {
      long long left = g_install.length - done;
      int want = (int) (left < (long long) sizeof buf ? left
                                                      : (long long) sizeof buf);
      ssize_t n = pread (g_install.fd, buf, want, g_install.offset + done);
      if (n <= 0)
        break;
      if (write (out, buf, n) != n)
        break;
      done += n;
      g_install.lock.lock ();
      g_install.bytes = done;
      g_install.lock.unlock ();
    }
  close (out);
  if (g_install.fd >= 0)
    close (g_install.fd);
  g_install.fd = -1;

  g_install.lock.lock ();
  g_install.bytes = 0;
  g_install.total = g_install.length;
  g_install.lock.unlock ();

  if (done != g_install.length)
    err = "short read from raw file";
  else
    {
      /* The tarball owns these trees: start from a clean copy so a file it
         no longer ships cannot linger (B-16).  `home' is kept.  */
      const char *owned[] = { "/lisp", "/leim", "/etc", "/terminfo" };
      for (const char *sub : owned)
        RemoveTree (g_install.dir + sub);
      ExtractTarGz (g_install.tar, g_install.dir, err);
      if (err.empty ())
        {
          MakeDirs (g_install.dir + "/home/.emacs.d");
          MakeDirs (g_install.dir + "/tmp");
          TouchElc (g_install.dir + "/lisp");
        }
    }

  g_install.lock.lock ();
  g_install.error = err;
  g_install.running = false;
  g_install.done = true;
  g_install.lock.unlock ();
  return nullptr;
}

} // namespace

int
RuntimeBeginInstall (int fd, long long offset, long long length,
                     const std::string &tar, const std::string &dir)
{
  g_install.lock.lock ();
  if (g_install.started && g_install.running)
    {
      g_install.lock.unlock ();
      return -2;
    }
  g_install.started = true;
  g_install.running = true;
  g_install.done = false;
  g_install.error.clear ();
  g_install.files = 0;
  g_install.bytes = 0;
  g_install.total = 0;
  g_install.fd = dup (fd);
  g_install.offset = offset;
  g_install.length = length;
  g_install.tar = tar;
  g_install.dir = dir;
  g_install.lock.unlock ();

  MakeDirs (dir);
  pthread_create (&g_install.tid, nullptr, InstallThread, nullptr);
  pthread_detach (g_install.tid);
  return 0;
}

std::string
RuntimeStateJson ()
{
  g_install.lock.lock ();
  std::string json = "{\"running\":";
  json += g_install.running ? "true" : "false";
  json += ",\"done\":";
  json += g_install.done ? "true" : "false";
  json += ",\"files\":" + std::to_string (g_install.files);
  json += ",\"bytes\":" + std::to_string (g_install.bytes);
  json += ",\"error\":\"" + g_install.error + "\"}";
  g_install.lock.unlock ();
  return json;
}

int
RuntimePathReady (const std::string &path)
{
  return access (path.c_str (), R_OK) == 0 ? 1 : 0;
}

std::string
RuntimeBuildId ()
{
  return __DATE__ " " __TIME__;
}

std::string
RuntimeReadFile (const std::string &path)
{
  int fd = open (path.c_str (), O_RDONLY);
  if (fd < 0)
    return std::string ();
  std::string data;
  char buf[4096];
  ssize_t n;
  while ((n = read (fd, buf, sizeof buf)) > 0)
    data.append (buf, n);
  close (fd);
  return data;
}

int
RuntimeWriteFile (const std::string &path, const std::string &text)
{
  int fd = open (path.c_str (), O_WRONLY | O_CREAT | O_TRUNC, 0644);
  if (fd < 0)
    return -1;
  ssize_t w = write (fd, text.data (), text.size ());
  close (fd);
  return w == (ssize_t) text.size () ? 0 : -1;
}

int
RuntimeRemoveFile (const std::string &path)
{
  return unlink (path.c_str ()) == 0 ? 0 : -1;
}

std::string
RuntimeLibemacsVersion ()
{
  std::string version;
  Dl_info dl;
  if (dladdr ((void *) RuntimeLibemacsVersion, &dl) && dl.dli_fname)
    {
      std::string dir = dl.dli_fname;
      size_t slash = dir.rfind ('/');
      if (slash != std::string::npos)
        dir = dir.substr (0, slash);
      std::string lib = dir + "/libemacs_gui.so";
      struct stat st;
      if (stat (lib.c_str (), &st) == 0)
        {
          uint64_t hash = 1469598103934665603ULL;
          FILE *f = fopen (lib.c_str (), "rb");
          if (f)
            {
              unsigned char buf[65536];
              size_t n;
              while ((n = fread (buf, 1, sizeof buf, f)) > 0)
                for (size_t i = 0; i < n; i++)
                  {
                    hash ^= buf[i];
                    hash *= 1099511628211ULL;
                  }
              fclose (f);
            }
          char hex[32];
          snprintf (hex, sizeof hex, "%016llx", (unsigned long long) hash);
          version = std::to_string ((long long) st.st_size) + "-" + hex;
        }
    }
  return version;
}
